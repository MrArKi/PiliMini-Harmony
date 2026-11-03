/**
 * 下载服务（spec-09；2026-10-11 第二批改造：文件夹 / 批量删除 / 进度修复）
 *  - 官方 request.agent 后台任务驱动（header 带 UA/Referer 防盗链）
 *  - 状态机：queued → downloading → done / paused / failed
 *  - 持久化：任务元数据 + 文件夹存 preferences（不含 url，重启后重新取流）
 *  - 文件：沙箱 filesDir/download/<bvid>_<cid>.mp4
 */
import request from '@ohos.request';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { prefsGet, prefsPut } from '../infra/storage/prefs';
import { VideoService, DownloadUrl, DashDownloadUrl } from './video_service';
import { UA_PC, BILI_REFERER } from '../config/constants';

import { DownloadTask, DlFolder, DownloadMetadata } from '../model/download';
import { blockedByWifiOnly } from '../infra/network/net_state';
import { DownloadFolderService } from './download_folder_service';
export { DownloadTask, DlFolder };
const KEY_TASKS: string = 'dl_tasks';

export function formatSize(n: number): string {
  if (n <= 0) {
    return '0B';
  }
  const units: string[] = ['B', 'K', 'M', 'G', 'T'];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v = v / 1024;
    i++;
  }
  return (i === 0 ? v.toString() : v.toFixed(1)) + units[i];
}

/** 清晰度角标（Nara 列表行封面右上角 480P/720P/1080P） */
export function qualityLabel(qn: number): string {
  if (qn >= 120) {
    return '4K';
  }
  if (qn >= 116) {
    return '1080P60';
  }
  if (qn >= 80) {
    return '1080P';
  }
  if (qn >= 64) {
    return '720P';
  }
  if (qn >= 32) {
    return '480P';
  }
  if (qn >= 16) {
    return '360P';
  }
  return qn.toString() + 'P';
}

export class DownloadService {
  private static tasks: DownloadTask[] = [];
  private static loaded: boolean = false;
  private static loading: Promise<void> | undefined = undefined;
  private static writes: Promise<void> = Promise.resolve();

  private static frozen: boolean = false;
  private static versions: Map<string, number> = new Map<string, number>();
  private static inFlight: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  /**
   * 阶段收尾钩子：native 任务被删除/判失败时显式解挂，避免 Promise 悬挂。
   * （迁 request.agent 后仍保留，用于 remove 这类必须立刻收尾的路径。）
   */
  private static stageAbort: Map<string, () => void> = new Map<string, () => void>();
  /** 文件轮询仅确认当前阶段完整，不直接跳过尚未下载的另一轨。 */
  private static stageComplete: Map<string, () => void> = new Map<string, () => void>();
  private static cancelling: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  /** 只串行同一任务的原生控制命令，不占住完整下载协程。 */
  private static controls: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  /**
   * 官方 request.agent 任务（`Mode.BACKGROUND`：切后台不受影响，顺带解决后台下载）。
   * 取代原 `request.downloadFile` —— 后者暂停后不再回调 complete/fail，导致 stage Promise 永挂、
   * 队列被 launching 卡死、暂停的条目也删不掉。
   */
  private static agentTasks: Map<string, request.agent.Task> = new Map<string, request.agent.Task>();
  private static pollTimers: Map<string, number> = new Map<string, number>();
  private static ctx: common.Context | undefined = undefined;
  private static listeners: Array<() => void> = [];
  private static revision: number = 0;
  /** 停滞检测：每任务连续无字节增长的秒数 */
  private static stallCounts: Map<string, number> = new Map<string, number>();

  static init(ctx: common.Context): void {
    DownloadService.ctx = ctx;
  }

  static onChange(cb: () => void): void {
    if (DownloadService.listeners.indexOf(cb) < 0) {
      DownloadService.listeners.push(cb);
    }
  }

  static offChange(cb: () => void): void {
    const i = DownloadService.listeners.indexOf(cb);
    if (i >= 0) {
      DownloadService.listeners.splice(i, 1);
    }
  }

  static structureRevision(): number { return DownloadService.revision; }

  private static notify(structural: boolean = true): void {
    if (structural) { DownloadService.revision++; }
    for (let i = 0; i < DownloadService.listeners.length; i++) {
      DownloadService.listeners[i]();
    }
  }

  static list(): DownloadTask[] {
    return DownloadService.tasks;
  }

  static folderList(): DlFolder[] { return DownloadFolderService.list(); }
  static async addFolder(title: string): Promise<void> {
    await DownloadService.load(); await DownloadFolderService.add(title); DownloadService.notify();
  }
  static async renameFolder(id: string, title: string): Promise<void> {
    await DownloadService.load(); await DownloadFolderService.rename(id, title); DownloadService.notify();
  }
  static async removeFolder(id: string): Promise<void> {
    await DownloadService.load(); await DownloadFolderService.remove(id); DownloadService.notify();
  }
  static async addToFolder(id: string, refs: string[]): Promise<void> {
    await DownloadService.load(); await DownloadFolderService.addMembers(id, refs); DownloadService.notify();
  }
  static async removeFromFolder(id: string, refs: string[]): Promise<void> {
    await DownloadService.load(); await DownloadFolderService.removeMembers(id, refs); DownloadService.notify();
  }
  static async moveMember(id: string, ref: string, delta: number): Promise<void> {
    await DownloadService.load(); await DownloadFolderService.move(id, ref, delta); DownloadService.notify();
  }

  private static dir(): string {
    const c = DownloadService.ctx;
    return c !== undefined ? c.filesDir + '/download/' : '';
  }

  static async load(): Promise<void> {
    if (DownloadService.loaded) { return; }
    if (DownloadService.loading === undefined) {
      DownloadService.loading = DownloadService.restore().then((): void => {
        DownloadService.loaded = true;
      }).finally((): void => { DownloadService.loading = undefined; });
    }
    await DownloadService.loading;
  }

  /** 所有写入入口共享一次恢复，避免先 add 后 load 覆盖旧元数据。 */
  private static async restore(): Promise<void> {
    try {
      const raw: string = await prefsGet(KEY_TASKS, '');
      const arr = JSON.parse(raw || '[]') as DownloadTask[];
      if (!Array.isArray(arr)) { throw new Error('下载任务数据损坏，原数据已保留'); }
      const out: DownloadTask[] = [];
      for (let i = 0; i < arr.length; i++) {
        const t = arr[i];
        if (!t || typeof t.bvid !== 'string' || !/^BV[0-9A-Za-z]+$/.test(t.bvid) ||
          !Number.isSafeInteger(t.cid) || t.cid <= 0 || typeof t.title !== 'string' || typeof t.cover !== 'string' ||
          !Number.isSafeInteger(t.quality) || t.quality <= 0 ||
          (t.duration !== undefined && (!Number.isFinite(t.duration) || t.duration < 0)) ||
          (t.totalSize !== undefined && (!Number.isSafeInteger(t.totalSize) || t.totalSize < 0)) ||
          (t.page !== undefined && (!Number.isSafeInteger(t.page) || t.page < 0)) ||
          (t.seasonOrder !== undefined && (!Number.isSafeInteger(t.seasonOrder) || t.seasonOrder < 0)) ||
          (t.part !== undefined && typeof t.part !== 'string') ||
          (t.upName !== undefined && typeof t.upName !== 'string') ||
          (t.upMid !== undefined && (!Number.isSafeInteger(t.upMid) || t.upMid < 0)) ||
          (t.seasonId !== undefined && typeof t.seasonId !== 'string') ||
          (t.seasonTitle !== undefined && typeof t.seasonTitle !== 'string') ||
          (t.agentTid !== undefined && typeof t.agentTid !== 'string') ||
          (t.agentStage !== undefined && !['', 'single', 'video', 'audio'].includes(t.agentStage)) ||
          !['done', 'downloading', 'paused', 'queued', 'failed'].includes(t.status)) {
          throw new Error('下载任务数据损坏，原数据已保留');
        }
        const task = new DownloadTask();
        task.bvid = t.bvid;
        task.cid = t.cid;
        task.title = t.title;
        task.part = t.part !== undefined ? t.part : '';
        task.cover = t.cover;
        task.quality = t.quality;
        task.duration = t.duration !== undefined ? t.duration : 0;
        task.upName = t.upName !== undefined ? t.upName : '';
        task.upMid = t.upMid !== undefined ? t.upMid : 0;
        task.page = t.page || Number(/^P(\d+)/i.exec(task.part)?.[1] || '0');
        task.seasonId = t.seasonId || ''; task.seasonTitle = t.seasonTitle || ''; task.seasonOrder = t.seasonOrder || 0;
        // DASH 任务（有 audioPath）用 .video.m4s / .audio.m4s；旧任务仍是单文件 .mp4。
        const dashTask: boolean = t.audioPath !== undefined && typeof t.audioPath === 'string' && t.audioPath.length > 0;
        const base: string = DownloadService.dir() + task.bvid + '_' + task.cid.toString();
        task.filePath = dashTask ? base + '.video.m4s' : base + '.mp4';
        task.audioPath = dashTask ? base + '.audio.m4s' : '';
        task.videoDone = t.videoDone === true;
        task.videoSize = t.videoSize !== undefined && Number.isSafeInteger(t.videoSize) && t.videoSize > 0 ? t.videoSize : 0;
        task.audioSize = t.audioSize !== undefined && Number.isSafeInteger(t.audioSize) && t.audioSize > 0 ? t.audioSize : 0;
        task.agentTid = t.agentTid || '';
        task.agentStage = t.agentStage || '';
        task.folderId = t.folderId !== undefined ? t.folderId : '';
        if (t.status === 'done') {
          // 校验文件是否还在
          let exists = false;
          try {
            exists = fs.accessSync(task.filePath);
          } catch (e) {
            exists = false;
          }
          task.totalSize = t.totalSize || 0;
          task.status = exists && DownloadService.filesComplete(task) ? 'done' : 'failed';
          task.errMsg = task.status === 'failed' ? '本地文件缺失，请重试下载' : '';
          task.progress = task.status === 'done' ? 100 : 0;
          if (task.status === 'done') {
            const sz: number = DownloadService.fileBytes(task);
            if (sz > 0) {
              task.totalSize = sz;
              task.receivedSize = sz;
            }
          }
        } else if (t.status === 'downloading' || t.status === 'paused' || t.status === 'queued' || t.status === 'failed') {
          task.receivedSize = DownloadService.fileBytes(task); task.totalSize = t.totalSize || 0;
          task.progress = task.totalSize > 0 ? Math.min(99, Math.round(task.receivedSize * 100 / task.totalSize)) : 0;
          // 跨进程先关闭旧系统写入者，未完成阶段重新取流；失败原因保留。
          task.status = t.status === 'failed' ? 'failed' : 'paused';
          task.errMsg = t.errMsg || '';
        } else {
          task.status = t.status;
        }
        out.push(task);
      }
      await DownloadService.recoverNativeTasks(out);
      DownloadService.tasks = out;
      await DownloadService.persistStrict();
    } catch (e) {
      throw new Error('下载资料恢复失败，原数据已保留：' + (e as Error).message);
    }
    await DownloadFolderService.load(DownloadService.tasks);
    DownloadService.notify();
  }

  /** 每次调用时取快照并按顺序落盘，旧状态不能晚写覆盖新的系统tid。 */
  private static persistStrict(): Promise<void> {
    const raw: string = JSON.stringify(DownloadService.tasks);
    const write: Promise<void> = DownloadService.writes.catch((): void => {}).then((): Promise<void> => prefsPut(KEY_TASKS, raw));
    DownloadService.writes = write;
    return write;
  }

  private static async persist(): Promise<void> {
    try { await DownloadService.persistStrict(); } catch (_) { console.warn('[PiliMini-dl] 下载状态保存失败'); }
  }

  private static notFound(error: Object): boolean { return (error as BusinessError).code === 21900006; }

  /** remove成功才允许覆盖/删文件；仅官方“已不存在”错误可视为已关闭。 */
  private static async removeNative(tid: string): Promise<void> {
    try { await request.agent.remove(tid); } catch (e) {
      if (!DownloadService.notFound(e)) { throw new Error('系统下载任务未能停止，请稍后重试'); }
    }
  }

  private static async closeNative(task: DownloadTask, key: string): Promise<void> {
    const agent: request.agent.Task | undefined = DownloadService.agentTasks.get(key);
    const tid: string = agent !== undefined ? agent.tid : task.agentTid;
    if (tid.length === 0) { return; }
    await DownloadService.removeNative(tid);
    if (DownloadService.agentTasks.get(key) === agent) { DownloadService.detachAgent(key); }
    if (task.agentTid === tid) { task.agentTid = ''; task.agentStage = ''; }
    await DownloadService.persistStrict();
  }

  /** 进程重启后系统后台任务仍可能写文件；关闭后再允许重新取流。 */
  private static async recoverNativeTasks(tasks: DownloadTask[]): Promise<void> {
    const ctx = DownloadService.ctx;
    const dir: string = DownloadService.dir();
    if (ctx === undefined || dir.length === 0) { throw new Error('下载目录未初始化'); }
    const ids: string[] = await request.agent.search({ after: 0, before: Date.now(),
      action: request.agent.Action.DOWNLOAD, mode: request.agent.Mode.BACKGROUND });
    for (const task of tasks) {
      if (task.agentTid.length > 0 && ids.indexOf(task.agentTid) < 0) { ids.push(task.agentTid); }
    }
    for (const tid of ids) {
      let native: request.agent.Task;
      try { native = await request.agent.getTask(ctx, tid); } catch (e) {
        if (DownloadService.notFound(e)) { continue; }
        throw new Error('无法核对系统下载任务，请稍后重试');
      }
      const config: request.agent.Config = native.config;
      const path: string = config.saveas || '';
      const owned: boolean = config.action === request.agent.Action.DOWNLOAD && config.mode === request.agent.Mode.BACKGROUND &&
        path.startsWith(dir) && /^BV[0-9A-Za-z]+_[0-9]+\.(mp4|video\.m4s|audio\.m4s)$/.test(path.substring(dir.length));
      const recorded: DownloadTask | undefined = tasks.find((t: DownloadTask): boolean => t.agentTid === tid);
      const stagePath: string = recorded !== undefined && recorded.agentStage === 'audio' ? recorded.audioPath :
        recorded !== undefined ? recorded.filePath : '';
      if (!owned || (recorded !== undefined && (path !== recorded.filePath && path !== recorded.audioPath ||
        recorded.agentStage.length > 0 && path !== stagePath))) {
        if (recorded !== undefined) { throw new Error('系统下载路径与资料不一致，已保留文件'); }
        continue;
      }
      let completed: boolean = false;
      try { completed = (await request.agent.show(tid)).progress.state === request.agent.State.COMPLETED; } catch (e) {
        if (!DownloadService.notFound(e)) { throw new Error('无法核对系统下载状态，请稍后重试'); }
      }
      await DownloadService.removeNative(tid);
      const task: DownloadTask | undefined = tasks.find((t: DownloadTask): boolean => {
        const base: string = dir + DownloadService.key(t);
        return path === t.filePath || path === t.audioPath || t.status !== 'done' &&
          (path === base + '.video.m4s' || path === base + '.audio.m4s');
      });
      // 旧版在创建DASH后才保存路径，可能只留下mp4元数据；按精确BV/cid找回阶段。
      if (task !== undefined && task.audioPath.length === 0 && !path.endsWith('.mp4')) {
        const base: string = dir + DownloadService.key(task);
        task.filePath = base + '.video.m4s'; task.audioPath = base + '.audio.m4s';
        task.totalSize = 0; task.videoSize = 0; task.audioSize = 0; task.videoDone = false;
      }
      if (task !== undefined && completed) {
        let size: number = 0;
        try { size = fs.statSync(path).size; } catch (_) {}
        if (size > 0) {
          if (path === task.filePath && task.audioPath.length > 0 && (task.videoSize <= 0 || size >= task.videoSize)) {
            task.videoDone = true; if (task.videoSize <= 0) { task.videoSize = size; }
          }
          if (path === task.audioPath && task.audioSize <= 0) { task.audioSize = size; }
          if ((task.audioPath.length === 0 || path === task.audioPath && task.videoDone) && DownloadService.filesComplete(task)) {
            task.status = 'done'; task.progress = 100; task.errMsg = '';
            task.receivedSize = DownloadService.fileBytes(task); task.totalSize = task.receivedSize;
          }
        }
      }
    }
    for (const task of tasks) {
      task.agentTid = ''; task.agentStage = '';
      if (task.audioPath.length > 0 && task.videoSize > 0) {
        try { if (fs.statSync(task.filePath).size >= task.videoSize) { task.videoDone = true; } } catch (_) {}
      }
      const knownComplete: boolean = task.audioPath.length > 0 ? task.videoDone && task.videoSize > 0 && task.audioSize > 0 : task.totalSize > 0;
      if (knownComplete && DownloadService.filesComplete(task)) {
        task.status = 'done'; task.progress = 100; task.errMsg = '';
        task.receivedSize = DownloadService.fileBytes(task); task.totalSize = task.receivedSize;
      }
    }
  }

  static async add(bvid: string, cid: number, title: string, cover: string, qn: number,
    part: string = '', duration: number = 0, upName: string = '', metadata?: DownloadMetadata): Promise<void> {
    await DownloadService.load();
    // 仅 Wi-Fi 保护（P2-1）：移动网络下不入队，避免后台悄悄吃流量。所有下载入口都经过这里。
    if (await blockedByWifiOnly()) {
      throw new Error('当前为移动网络，已按「仅 Wi-Fi 下载」阻止；可在设置里关闭该开关');
    }
    const dir = DownloadService.dir();
    if (dir.length === 0) {
      throw new Error('下载目录未初始化');
    }
    // 去重
    for (let i = 0; i < DownloadService.tasks.length; i++) {
      const t = DownloadService.tasks[i];
      if (t.bvid === bvid && t.cid === cid) {
        throw new Error('已在下载列表');
      }
    }
    const task = new DownloadTask();
    task.bvid = bvid;
    task.cid = cid;
    task.title = title;
    task.part = part;
    task.cover = cover;
    task.quality = qn;
    task.duration = duration;
    task.upName = upName;
    if (metadata) {
      task.page = metadata.page; task.seasonId = metadata.seasonId;
      task.seasonTitle = metadata.seasonTitle; task.seasonOrder = metadata.seasonOrder;
      task.upMid = metadata.upMid !== undefined ? metadata.upMid : 0;
    }
    task.status = 'queued';
    task.filePath = dir + bvid + '_' + cid.toString() + '.mp4';
    DownloadService.tasks.unshift(task);
    DownloadService.notify();
    await DownloadService.persist();
    DownloadService.startNext();
  }

  private static key(t: DownloadTask): string { return t.bvid + '_' + t.cid.toString(); }

  private static valid(t: DownloadTask, generation: number): boolean {
    return DownloadService.tasks.indexOf(t) >= 0 &&
      DownloadService.versions.get(DownloadService.key(t)) === generation;
  }

  private static control(key: string, action: () => Promise<void>): Promise<void> {
    const previous: Promise<void> | undefined = DownloadService.controls.get(key);
    const work: Promise<void> = (previous || Promise.resolve()).catch((): void => {}).then(action);
    DownloadService.controls.set(key, work);
    return work.finally((): void => {
      if (DownloadService.controls.get(key) === work) { DownloadService.controls.delete(key); }
    });
  }

  private static async startNext(): Promise<void> {
    // 串行只靠"是否已有 downloading"判定：状态在同一个同步块里置位，不会被并发重入挑中。
    // （原 launching 布尔门是全局的，任务一暂停就永久为 true，把整条队列焊死。）
    if (DownloadService.frozen ||
      DownloadService.tasks.some((t: DownloadTask): boolean => t.status === 'downloading')) { return; }
    const next: DownloadTask | undefined = DownloadService.tasks.find((t: DownloadTask): boolean => t.status === 'queued');
    if (next === undefined) { return; }
    const key: string = DownloadService.key(next);
    const owner: Promise<void> | undefined = DownloadService.inFlight.get(key);
    if (owner !== undefined) {
      // 阶段交界/取流尚未退出时，交给原owner的finally重新排队，禁止第二次launch。
      if (!DownloadService.agentTasks.has(key) || !DownloadService.stageAbort.has(key)) { return; }
      const generation: number = DownloadService.versions.get(key) || 0;
      next.status = 'downloading'; next.errMsg = ''; DownloadService.notify();
      DownloadService.control(key, async (): Promise<void> => {
        const agent: request.agent.Task | undefined = DownloadService.agentTasks.get(key);
        if (agent === undefined || !DownloadService.valid(next, generation) || next.status !== 'downloading') { return; }
        try {
          await agent.resume();
          if (DownloadService.valid(next, generation) && next.status === 'downloading' &&
            DownloadService.agentTasks.get(key) === agent) { DownloadService.startPoll(next, key, generation); }
        } catch (_) {
          if (DownloadService.agentTasks.get(key) === agent) {
            await DownloadService.failTask(next, key, generation, '恢复失败，请重试');
          }
        }
      }).catch((): void => {});
      return;
    }
    const generation: number = (DownloadService.versions.get(key) || 0) + (DownloadService.agentTasks.has(key) ? 0 : 1);
    DownloadService.versions.set(key, generation);
    next.status = 'downloading';
    next.errMsg = '';
    DownloadService.notify();
    const work: Promise<void> = DownloadService.launch(next, generation);
    DownloadService.inFlight.set(key, work);
    try { await work; } finally {
      if (DownloadService.inFlight.get(key) === work) { DownloadService.inFlight.delete(key); }
      DownloadService.startNext();
    }
  }

  private static async launch(next: DownloadTask, generation: number): Promise<void> {
    const key: string = DownloadService.key(next);
    try {
      // 失败取消曾报错时，保留的tid必须先关闭，才可删除残片/覆盖同一路径。
      if (next.agentTid.length > 0) { await DownloadService.closeNative(next, key); }
      await DownloadService.persistStrict();
      if (!DownloadService.valid(next, generation) || next.status !== 'downloading') { return; }
      // 优先 DASH（固定最高画质，spec-17 2026-10-27）；没有可用 DASH 时降级 durl 单文件。
      const dash: DashDownloadUrl | undefined = await VideoService.dashForDownload(next.bvid, next.cid);
      if (!DownloadService.valid(next, generation) || next.status !== 'downloading') { return; }
      if (dash !== undefined && dash.audioUrl.length > 0) {
        let reuseVideo: boolean = false;
        if (next.audioPath.length > 0 && next.videoDone && next.quality === dash.quality && next.videoSize > 0) {
          try { reuseVideo = fs.statSync(next.filePath).size >= next.videoSize; } catch (_) {}
        }
        if (reuseVideo) {
          // 音频可能只下载了一部分，不能让旧残片参与新阶段的完成判定。
          if (next.audioPath.startsWith(DownloadService.dir())) {
            try { if (fs.accessSync(next.audioPath)) { fs.unlinkSync(next.audioPath); } } catch (_) {}
          }
        } else { DownloadService.deleteFile(next); }
        const dir: string = DownloadService.dir();
        next.filePath = dir + next.bvid + '_' + next.cid.toString() + '.video.m4s';
        next.audioPath = dir + next.bvid + '_' + next.cid.toString() + '.audio.m4s';
        next.videoDone = reuseVideo;
        if (!reuseVideo) { next.videoSize = 0; }
        // 重新取流后音轨可能已换档，旧音轨长度不能用于新文件完成判定。
        next.audioSize = 0;
        next.receivedSize = reuseVideo ? next.videoSize : 0;
        next.progress = 0;
        next.quality = dash.quality;
        if (dash.durationMs > 0) { next.duration = dash.durationMs / 1000; }
        await DownloadService.runDash(next, dash, generation);
        return;
      }
      const u: DownloadUrl = await VideoService.durlForDownload(next.bvid, next.cid, next.quality);
      if (!DownloadService.valid(next, generation) || next.status !== 'downloading') { return; }
      DownloadService.deleteFile(next);
      next.filePath = DownloadService.dir() + key + '.mp4'; next.audioPath = '';
      next.videoDone = false; next.videoSize = 0; next.audioSize = 0;
      next.receivedSize = 0; next.totalSize = 0; next.progress = 0;
      next.quality = u.quality;
      if (u.durationMs > 0) { next.duration = u.durationMs / 1000; }
      await DownloadService.doDownload(next, u, generation);
    } catch (e) {
      if (!DownloadService.valid(next, generation)) { return; }
      await DownloadService.failTask(next, key, generation, (e as Error).message || '取流/启动失败');
    }
  }

  private static async doDownload(task: DownloadTask, u: DownloadUrl, generation: number): Promise<void> {
    if (DownloadService.ctx === undefined) {
      throw new Error('context 未初始化');
    }
    if (u.size > 0) {
      task.totalSize = u.size;
    } else if (task.totalSize <= 0) {
      // 取流响应缺 size（部分线路）→ HEAD 请求兜底拿 Content-Length（进度条依赖它）
      const len: number = await DownloadService.fetchContentLength(u.url);
      if (len > 0) {
        task.totalSize = len;
      }
    }
    if (!DownloadService.valid(task, generation) || task.status !== 'downloading') { return; }
    try {
      fs.mkdirSync(DownloadService.dir(), true);
    } catch (e) {
      // 目录已存在
    }
    const ok: boolean = await DownloadService.downloadStage(task, u.url, task.filePath, true, generation);
    if (!ok || !DownloadService.valid(task, generation)) { return; }
    DownloadService.finish(task, DownloadService.key(task));
  }

  /** DASH 串行下载（spec-17 2026-10-27）：先视频后音频，两份都到齐才 finish。 */
  private static async runDash(task: DownloadTask, dash: DashDownloadUrl, generation: number): Promise<void> {
    const key: string = DownloadService.key(task);
    // 预取两份总字节：进度从一开始就是合并口径（HEAD 失败则退化为各阶段独立）
    if (task.videoSize <= 0) { task.videoSize = await DownloadService.fetchContentLength(dash.videoUrl); }
    if (task.audioSize <= 0) { task.audioSize = await DownloadService.fetchContentLength(dash.audioUrl); }
    // 任一轨未知时不能把另一轨长度当成双轨总长。
    task.totalSize = task.videoSize > 0 && task.audioSize > 0 ? task.videoSize + task.audioSize : 0;
    if (!DownloadService.valid(task, generation) || task.status !== 'downloading') { return; }

    if (!task.videoDone) {
      const videoOk: boolean = await DownloadService.downloadStage(task, dash.videoUrl, task.filePath, true, generation);
      if (!videoOk) { return; }
      if (!DownloadService.valid(task, generation)) { return; }
      task.videoDone = true;
      if (task.videoSize <= 0) {
        try { task.videoSize = fs.statSync(task.filePath).size; } catch (e) {}
      }
      await DownloadService.persist();
    }
    if (!DownloadService.valid(task, generation) || task.status !== 'downloading') { return; }
    const audioOk: boolean = await DownloadService.downloadStage(task, dash.audioUrl, task.audioPath, false, generation);
    if (!audioOk || !DownloadService.valid(task, generation)) { return; }
    DownloadService.finish(task, key);
  }

  /**
   * 单阶段下载（官方 request.agent）：完成 resolve(true)；失败 resolve(false) 并交给 failTask。
   * 暂停**不解挂**：原生任务仍在，resume 后同一个 Promise 会被 completed 事件收尾，
   * 所以 DASH 的"视频完成→自动接音频"续接在暂停前后都不会丢。
   */
  private static async downloadStage(task: DownloadTask, url: string, path: string, isVideo: boolean,
    generation: number): Promise<boolean> {
    const ctx = DownloadService.ctx;
    const key: string = DownloadService.key(task);
    if (ctx === undefined || !DownloadService.valid(task, generation) || task.status !== 'downloading') { return false; }
    // 先记录阶段路径和大小，create后即使进程退出也能按目录找回系统任务。
    task.agentStage = task.audioPath.length === 0 ? 'single' : isVideo ? 'video' : 'audio';
    await DownloadService.persistStrict();
    if (!DownloadService.valid(task, generation) || task.status !== 'downloading') { return false; }
    try { fs.mkdirSync(DownloadService.dir(), true); } catch (e) {}
    const headers: Record<string, string> = {
      'User-Agent': UA_PC,
      'Referer': BILI_REFERER
    };
    const config: request.agent.Config = {
      action: request.agent.Action.DOWNLOAD,
      url: url,
      title: task.title,
      // Background：切后台/熄屏不受影响（前台任务在后台一段时间后会失败或暂停）
      mode: request.agent.Mode.BACKGROUND,
      method: 'GET',
      headers: headers,
      saveas: path,
      overwrite: true,
      network: request.agent.Network.ANY,
      metered: true,
      roaming: true,
      // 断线重试与 30x 跟随都交给系统引擎
      retry: true,
      redirect: true,
      gauge: true
    };
    let agent: request.agent.Task;
    try {
      agent = await request.agent.create(ctx, config);
    } catch (e) {
      await DownloadService.failTask(task, key, generation, '下载启动失败');
      return false;
    }
    task.agentTid = agent.tid;
    try {
      // 不在持久化前启动：系统后台任务能活过应用进程。
      await DownloadService.persistStrict();
    } catch (_) {
      await DownloadService.failTask(task, key, generation, '下载状态保存失败，请重试');
      return false;
    }
    if (!DownloadService.valid(task, generation) || task.status !== 'downloading') {
      try { await DownloadService.closeNative(task, key); } catch (_) {
        task.status = 'failed'; task.errMsg = '系统下载任务未能停止，请稍后重试';
        DownloadService.notify(); await DownloadService.persist();
      }
      return false;
    }
    DownloadService.agentTasks.set(key, agent);
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      let settled: boolean = false;
      const settle = (ok: boolean): void => {
        if (settled) { return; }
        settled = true;
        DownloadService.stageAbort.delete(key);
        DownloadService.stageComplete.delete(key);
        // 成功的前一阶段先解绑，防止迟到事件干扰下一轨的收尾钩子。
        // 失败/删除仍由 failTask/remove 持有原生任务，等待其取消后再清理文件。
        if (ok) {
          // 完成依据与清tid同一快照保存，关闭原生后杀进程也不丢完整视频标识。
          let size: number = 0;
          try { size = fs.statSync(path).size; } catch (_) {}
          if (task.audioPath.length > 0) {
            if (isVideo && size > 0 && (task.videoSize <= 0 || size >= task.videoSize)) {
              task.videoDone = true; if (task.videoSize <= 0) { task.videoSize = size; }
            } else if (!isVideo && task.audioSize <= 0) { task.audioSize = size; }
          } else if (task.totalSize <= 0) { task.totalSize = size; }
          if (DownloadService.agentTasks.get(key) === agent) { DownloadService.detachAgent(key); }
          DownloadService.stopPoll(key);
          // 轮询可能先于completed观察到全部字节；先关闭原生写入者，再进入下一轨。
          DownloadService.closeNative(task, key).then((): void => resolve(true), async (): Promise<void> => {
            await DownloadService.failTask(task, key, generation, '系统下载任务未能停止，请稍后重试');
            resolve(false);
          });
        } else { resolve(false); }
      };
      const expectedSize = (): number => task.audioPath.length > 0 ?
        (isVideo ? task.videoSize : task.audioSize) : task.totalSize;
      // 删除/判失败这类必须立刻收尾的路径从这里解挂
      DownloadService.stageAbort.set(key, (): void => settle(false));
      DownloadService.stageComplete.set(key, (): void => {
        if (!DownloadService.valid(task, generation) || task.status !== 'downloading') { return; }
        const expect: number = expectedSize();
        if (expect <= 0) { return; }
        try { if (fs.statSync(path).size >= expect) { settle(true); } } catch (_) {}
      });
      agent.on('completed', (): void => {
        settle(DownloadService.valid(task, generation));
      });
      agent.on('failed', (): void => {
        if (settled) { return; }
        if (!DownloadService.valid(task, generation)) { settle(false); return; }
        // 引擎报错但文件已齐（部分 CDN 收尾异常）按成功处理
        let size: number = 0;
        try { size = fs.statSync(path).size; } catch (e) {}
        const expect: number = expectedSize();
        if (expect > 0 && size >= expect) { settle(true); return; }
        DownloadService.failTask(task, key, generation, '下载失败，请重试');
        settle(false);
      });
      agent.start().catch(async (): Promise<void> => {
        if (settled) { return; }
        if (DownloadService.valid(task, generation) && task.status === 'downloading') {
          await DownloadService.failTask(task, key, generation, '下载启动失败');
        }
        settle(false);
      });
      if (task.status === 'paused') {
        agent.pause().catch((): void => {});
      } else {
        DownloadService.startPoll(task, key, generation);
      }
    });
  }

  private static currentStatus(task: DownloadTask): string { return task.status; }

  private static startPoll(task: DownloadTask, key: string, generation: number): void {
    DownloadService.stopPoll(key);

    // 轮询兜底：模拟器 progress/complete 回调不可靠，用文件大小判定进度与完成
    const timer = setInterval((): void => {
      if (!DownloadService.valid(task, generation) || task.status !== 'downloading') {
        DownloadService.stopPoll(key);
        return;
      }
      const fb = DownloadService.fileBytes(task);
      if (fb > task.receivedSize) {
        task.receivedSize = fb;
        if (task.totalSize > 0) {
          task.progress = Math.min(99, Math.round(fb * 100 / task.totalSize));
        }
        DownloadService.stallCounts.set(key, 0);
        DownloadService.notify(false);
      } else {
        // 停滞检测：30s 无字节增长（request 引擎在模拟器/异常网络下会静默挂起）→ 判失败可重试
        const stalls: number = DownloadService.stallCounts.get(key) !== undefined
          ? (DownloadService.stallCounts.get(key) as number) : 0;
        const next: number = stalls + 1;
        DownloadService.stallCounts.set(key, next);
        if (next >= 30 && task.status === 'downloading') {
          DownloadService.failTask(task, key, generation, '下载停滞，请重试');

          return;
        }
      }
      const complete: (() => void) | undefined = DownloadService.stageComplete.get(key);
      if (complete !== undefined) { complete(); }
    }, 1000);
    DownloadService.pollTimers.set(key, timer);
  }

  /** HEAD 请求取 Content-Length（进度百分比依赖） */
  private static async fetchContentLength(url: string): Promise<number> {
    try {
      const req = http.createHttp();
      try {
        const res = await req.request(url, {
          method: http.RequestMethod.HEAD,
          header: {
            'User-Agent': UA_PC,
            'Referer': BILI_REFERER
          },
          connectTimeout: 15000,
          readTimeout: 15000
        });
        const rec = res.header as Record<string, Object>;
        const keys: string[] = Object.keys(rec);
        for (let i = 0; i < keys.length; i++) {
          if (keys[i].toLowerCase() === 'content-length') {
            const v: string = rec[keys[i]].toString();
            const n: number = parseInt(v, 10);
            if (!isNaN(n) && n > 0) {
              return n;
            }
          }
        }
      } finally {
        req.destroy();
      }
    } catch (e) {
      // 忽略：无 Content-Length 时进度退化为"已下载 X"
    }
    return 0;
  }

  /** 每一轨独立校验，避免某轨大小未知时拿另一轨冒充完整双轨。 */
  private static filesComplete(task: DownloadTask): boolean {
    try {
      const video: number = fs.statSync(task.filePath).size;
      if (video <= 0 || (task.videoSize > 0 && video < task.videoSize)) { return false; }
      let audio: number = 0;
      if (task.audioPath.length > 0) {
        audio = fs.statSync(task.audioPath).size;
        if (audio <= 0 || (task.audioSize > 0 && audio < task.audioSize)) { return false; }
      }
      return task.totalSize <= 0 || video + audio >= task.totalSize;
    } catch (_) { return false; }
  }

  private static finish(task: DownloadTask, key: string): void {
    if (task.status === 'done') {
      return;
    }
    const sz: number = DownloadService.fileBytes(task);
    if (!DownloadService.filesComplete(task)) {
      DownloadService.failTask(task, key, DownloadService.versions.get(key) || 0, '下载文件不完整，请重试');
      return;
    }
    task.status = 'done';
    task.progress = 100;
    // 完成后统一使用实际占用，包含任一轨 HEAD 未提供长度的情况。
    task.totalSize = sz;
    task.receivedSize = sz;
    DownloadService.abortStage(key);
    DownloadService.detachAgent(key);
    DownloadService.stopPoll(key);
    DownloadService.notify();
    DownloadService.persist();
    DownloadService.startNext();
  }

  /** 摘掉事件监听并释放引用；原生任务对象本身由调用方决定 resume/remove */
  private static detachAgent(key: string): void {
    const task = DownloadService.agentTasks.get(key);
    if (task) {
      try { task.off('completed'); } catch (_) {}
      try { task.off('failed'); } catch (_) {}
      DownloadService.agentTasks.delete(key);
    }
  }

  /** 解开在途 stage 的 Promise（失败/删除路径用），避免 launch 的 finally 拉不回来 */
  private static abortStage(key: string): void {
    const abort = DownloadService.stageAbort.get(key);
    if (abort !== undefined) {
      DownloadService.stageAbort.delete(key);
      abort();
    }
  }

  private static stopPoll(key: string): void {
    const timer = DownloadService.pollTimers.get(key);
    if (timer !== undefined) {
      clearInterval(timer);
      DownloadService.pollTimers.delete(key);
    }
    DownloadService.stallCounts.delete(key);
  }

  private static async failTask(t: DownloadTask, key: string, generation: number, message: string): Promise<void> {
    if (!DownloadService.valid(t, generation)) { return; }
    t.status = 'failed';
    t.errMsg = message;
    DownloadService.versions.set(key, generation + 1);
    // 代际已推进，旧事件不会再被处理；必须先解挂 stage，否则 Promise 永远挂着
    DownloadService.abortStage(key);
    DownloadService.stopPoll(key);
    if (t.agentTid.length > 0 || DownloadService.agentTasks.has(key)) {
      const closing: Promise<void> = DownloadService.closeNative(t, key).catch((): void => {
        // 保留tid与文件，下一次重试仍须先关闭旧写入者。
        t.errMsg = '系统下载任务未能停止，请稍后重试';
      });
      DownloadService.cancelling.set(key, closing);
      try { await closing; } finally {
        if (DownloadService.cancelling.get(key) === closing) { DownloadService.cancelling.delete(key); }
      }
    }
    if (!DownloadService.valid(t, generation + 1)) { return; }
    DownloadService.notify();
    await DownloadService.persist();
    DownloadService.startNext();
  }

  private static deleteFile(t: DownloadTask): void {
    // 只删除服务根据 bvid/cid 生成、下载目录内的文件。
    if (!t.filePath.startsWith(DownloadService.dir()) || DownloadService.dir().length === 0) { return; }
    try { if (fs.accessSync(t.filePath)) { fs.unlinkSync(t.filePath); } } catch (e) {}
    if (t.audioPath.length > 0 && t.audioPath.startsWith(DownloadService.dir())) {
      try { if (fs.accessSync(t.audioPath)) { fs.unlinkSync(t.audioPath); } } catch (e) {}
    }
  }

  static async pause(cid: number): Promise<void> {
    await DownloadService.load();
    const t: DownloadTask | undefined = DownloadService.tasks.find((x: DownloadTask): boolean => x.cid === cid && x.status === 'downloading');
    if (t === undefined) { return; }
    await DownloadService.control(DownloadService.key(t), (): Promise<void> => DownloadService.pauseTask(t));
  }

  private static async pauseTask(t: DownloadTask): Promise<void> {
    if (DownloadService.tasks.indexOf(t) < 0 || t.status !== 'downloading') { return; }
    t.status = 'paused';
    const key: string = DownloadService.key(t);
    DownloadService.stopPoll(key);
    DownloadService.notify();
    const agent: request.agent.Task | undefined = DownloadService.agentTasks.get(key);
    if (agent !== undefined) {
      try {
        await agent.pause();
      } catch (e) {
        if (DownloadService.currentStatus(t) === 'done' || DownloadService.agentTasks.get(key) !== agent) { return; }
        await DownloadService.failTask(t, key, DownloadService.versions.get(key) || 0, '暂停失败，请重试');
        return;
      }
    }
    await DownloadService.persist();
    // 暂停的任务已不是 downloading，这里让队列继续跑下一个（原实现被全局 launching 挡住）
    DownloadService.startNext();
  }

  static async resume(cid: number): Promise<void> {
    await DownloadService.load();
    const t: DownloadTask | undefined = DownloadService.tasks.find((x: DownloadTask): boolean =>
      x.cid === cid && (x.status === 'paused' || x.status === 'failed'));
    if (t === undefined) { return; }
    await DownloadService.control(DownloadService.key(t), (): Promise<void> => DownloadService.resumeTask(t));
  }

  private static async resumeTask(t: DownloadTask): Promise<void> {
    if (DownloadService.tasks.indexOf(t) < 0 || (t.status !== 'paused' && t.status !== 'failed')) { return; }
    const key: string = DownloadService.key(t);
    const closing: Promise<void> | undefined = DownloadService.cancelling.get(key);
    if (closing !== undefined) { await closing; }
    if (DownloadService.tasks.indexOf(t) < 0) { return; }
    if ((!DownloadService.inFlight.has(key) || !DownloadService.stageAbort.has(key)) && t.agentTid.length > 0) {
      try { await DownloadService.closeNative(t, key); } catch (_) {
        t.status = 'failed'; t.errMsg = '系统下载任务未能停止，请稍后重试';
        DownloadService.notify(); await DownloadService.persist(); return;
      }
    }
    t.status = 'queued';
    t.errMsg = '';
    DownloadService.notify();
    await DownloadService.persist();
    DownloadService.startNext();
  }

  static async remove(cid: number): Promise<void> {
    await DownloadService.load();
    const t: DownloadTask | undefined = DownloadService.tasks.find((x: DownloadTask): boolean => x.cid === cid);
    if (t === undefined) { return; }
    await DownloadService.control(DownloadService.key(t), (): Promise<void> => DownloadService.removeTask(t));
  }

  private static async removeTask(t: DownloadTask): Promise<void> {
    if (DownloadService.tasks.indexOf(t) < 0) { return; }
    const key: string = DownloadService.key(t);
    DownloadService.versions.set(key, (DownloadService.versions.get(key) || 0) + 1);
    DownloadService.abortStage(key);
    t.status = 'paused';
    DownloadService.stopPoll(key);
    const pending: Promise<void> | undefined = DownloadService.inFlight.get(key);
    if (pending !== undefined) { await pending; }
    const closing: Promise<void> | undefined = DownloadService.cancelling.get(key);
    if (closing !== undefined) { await closing; }
    try { await DownloadService.closeNative(t, key); } catch (e) {
      t.status = 'failed'; t.errMsg = '系统下载任务未能停止，文件已保留';
      DownloadService.notify(); await DownloadService.persist(); throw new Error('系统下载任务未能停止，文件已保留');
    }
    DownloadService.deleteFile(t);
    DownloadService.tasks = DownloadService.tasks.filter((x: DownloadTask): boolean => x !== t);
    DownloadService.versions.delete(key);
    await DownloadFolderService.prune(DownloadService.tasks);
    DownloadService.notify();
    await DownloadService.persist();
    DownloadService.startNext();
  }

  /** 批量删除（多选清除；按 cid 集合匹配） */
  static async removeMany(cids: number[]): Promise<void> {
    for (let i = 0; i < cids.length; i++) {
      await DownloadService.remove(cids[i]);
    }
  }

  static async clear(): Promise<void> {
    await DownloadService.load();
    DownloadService.frozen = true;
    try {
      const cids: number[] = DownloadService.tasks.map((t: DownloadTask): number => t.cid);
      for (let i: number = 0; i < cids.length; i++) { await DownloadService.remove(cids[i]); }
      const dir: string = DownloadService.dir();
      if (dir.length > 0 && fs.accessSync(dir)) {
        const files: string[] = fs.listFileSync(dir);
        for (let i: number = 0; i < files.length; i++) {
          if (/^BV[0-9A-Za-z]+_[0-9]+\.(mp4|video\.m4s|audio\.m4s)$/.test(files[i])) { fs.unlinkSync(dir + files[i]); }
        }
      }
      await DownloadService.persist();
    } finally { DownloadService.frozen = false; DownloadService.startNext(); }
  }

  /** 下载目录占用字节 */
  static totalBytes(): number {
    const dir = DownloadService.dir();
    if (dir.length === 0) {
      return 0;
    }
    let total = 0;
    try {
      const files = fs.listFileSync(dir);
      for (let i = 0; i < files.length; i++) {
        try {
          const st = fs.statSync(dir + files[i]);
          total += st.size;
        } catch (e) {
          // 忽略单文件
        }
      }
    } catch (e) {
      // 目录不存在
    }
    return total;
  }

  /** 任务对应文件实时大小（progress 回调在模拟器可能不触发，用文件大小兜底） */
  static fileBytes(task: DownloadTask): number {
    let bytes: number = 0;
    try {
      if (task.filePath.length > 0) {
        bytes += fs.statSync(task.filePath).size;
      }
    } catch (e) {
      // 文件尚未创建
    }
    if (task.audioPath.length > 0) {
      try {
        bytes += fs.statSync(task.audioPath).size;
      } catch (e) {
        // DASH 音频尚未创建
      }
    }
    return bytes;
  }
}
