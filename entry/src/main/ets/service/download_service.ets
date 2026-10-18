/**
 * 下载服务（spec-09；2026-10-11 第二批改造：文件夹 / 批量删除 / 进度修复）
 *  - @ohos.request.downloadFile 驱动（header 带 UA/Referer 防盗链）
 *  - 状态机：queued → downloading → done / paused / failed
 *  - 持久化：任务元数据 + 文件夹存 preferences（不含 url，重启后重新取流）
 *  - 文件：沙箱 filesDir/download/<bvid>_<cid>.mp4
 */
import request from '@ohos.request';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { prefsGet, prefsPut } from '../infra/storage/prefs';
import { VideoService, DownloadUrl } from './video_service';
import { UA_PC, BILI_REFERER } from '../config/constants';

import { DownloadTask, DlFolder, DownloadMetadata } from '../model/download';
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
  private static launching: boolean = false;
  private static frozen: boolean = false;
  private static versions: Map<string, number> = new Map<string, number>();
  private static inFlight: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  private static cancelling: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  private static reqTasks: Map<string, request.DownloadTask> = new Map<string, request.DownloadTask>();
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
          (t.seasonId !== undefined && typeof t.seasonId !== 'string') ||
          (t.seasonTitle !== undefined && typeof t.seasonTitle !== 'string') ||
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
        task.page = t.page || Number(/^P(\d+)/i.exec(task.part)?.[1] || '0');
        task.seasonId = t.seasonId || ''; task.seasonTitle = t.seasonTitle || ''; task.seasonOrder = t.seasonOrder || 0;
        task.filePath = DownloadService.dir() + task.bvid + '_' + task.cid.toString() + '.mp4';
        task.folderId = t.folderId !== undefined ? t.folderId : '';
        if (t.status === 'done') {
          // 校验文件是否还在
          let exists = false;
          try {
            exists = fs.accessSync(task.filePath);
          } catch (e) {
            exists = false;
          }
          task.status = exists && DownloadService.fileBytes(task) > 0 ? 'done' : 'failed';
          task.errMsg = task.status === 'failed' ? '本地文件缺失，请重试下载' : '';
          task.progress = exists ? 100 : 0;
          if (exists) {
            const sz: number = DownloadService.fileBytes(task);
            if (sz > 0) {
              task.totalSize = sz;
              task.receivedSize = sz;
            }
          }
        } else if (t.status === 'downloading' || t.status === 'paused' || t.status === 'queued' || t.status === 'failed') {
          task.receivedSize = DownloadService.fileBytes(task); task.totalSize = t.totalSize || 0;
          task.progress = task.totalSize > 0 ? Math.min(99, Math.round(task.receivedSize * 100 / task.totalSize)) : 0;
          // request 会话无法跨进程恢复；失败原因仍保留，不伪装成暂停。
          task.status = t.status === 'failed' ? 'failed' : 'paused';
          task.errMsg = t.errMsg || '';
        } else {
          task.status = t.status;
        }
        out.push(task);
      }
      DownloadService.tasks = out;
    } catch (e) {
      throw new Error('下载资料恢复失败，原数据已保留：' + (e as Error).message);
    }
    await DownloadFolderService.load(DownloadService.tasks);
    DownloadService.notify();
  }

  private static async persist(): Promise<void> {
    try {
      const arr: DownloadTask[] = [];
      for (let i = 0; i < DownloadService.tasks.length; i++) {
        const t = DownloadService.tasks[i];
        arr.push(t);
      }
      await prefsPut(KEY_TASKS, JSON.stringify(arr));
    } catch (e) {
      // 忽略
    }
  }

  static async add(bvid: string, cid: number, title: string, cover: string, qn: number,
    part: string = '', duration: number = 0, upName: string = '', metadata?: DownloadMetadata): Promise<void> {
    await DownloadService.load();
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

  private static async startNext(): Promise<void> {
    if (DownloadService.frozen || DownloadService.launching ||
      DownloadService.tasks.some((t: DownloadTask): boolean => t.status === 'downloading')) { return; }
    const next: DownloadTask | undefined = DownloadService.tasks.find((t: DownloadTask): boolean => t.status === 'queued');
    if (next === undefined) { return; }
    const key: string = DownloadService.key(next);
    const generation: number = (DownloadService.versions.get(key) || 0) + (DownloadService.reqTasks.has(key) ? 0 : 1);
    DownloadService.versions.set(key, generation);
    DownloadService.launching = true;
    next.status = 'downloading';
    next.errMsg = '';
    DownloadService.notify();
    const work: Promise<void> = DownloadService.launch(next, generation);
    DownloadService.inFlight.set(key, work);
    try { await work; } finally {
      DownloadService.inFlight.delete(key);
      DownloadService.launching = false;
      DownloadService.startNext();
    }
  }

  private static async launch(next: DownloadTask, generation: number): Promise<void> {
    const key: string = DownloadService.key(next);
    try {
      await DownloadService.persist();
      if (!DownloadService.valid(next, generation) || next.status !== 'downloading') { return; }
      const rt: request.DownloadTask | undefined = DownloadService.reqTasks.get(key);
      if (rt !== undefined) {
        await rt.resume();
        if (DownloadService.valid(next, generation) && next.status === 'downloading') {
          // 原事件处理保持同一代际；原生任务 resume 不重建文件。
          DownloadService.startPoll(next, key, generation);
        } else { await rt.pause(); }
        return;
      }
      DownloadService.deleteFile(next);
      next.receivedSize = 0;
      next.progress = 0;
      const u: DownloadUrl = await VideoService.durlForDownload(next.bvid, next.cid, next.quality);
      if (!DownloadService.valid(next, generation) || next.status !== 'downloading') { return; }
      next.quality = u.quality;
      if (u.durationMs > 0) { next.duration = u.durationMs / 1000; }
      await DownloadService.doDownload(next, u, generation);
    } catch (e) {
      if (!DownloadService.valid(next, generation)) { return; }
      await DownloadService.failTask(next, key, generation, (e as Error).message || '取流/启动失败');
    }
  }

  private static async doDownload(task: DownloadTask, u: DownloadUrl, generation: number): Promise<void> {
    const ctx = DownloadService.ctx;
    if (ctx === undefined) {
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
    const config: request.DownloadConfig = {
      url: u.url,
      header: {
        'User-Agent': UA_PC,
        'Referer': BILI_REFERER
      },
      filePath: task.filePath,
      enableMetered: true,
      enableRoaming: true,
      title: task.title
    };
    const rtask = await request.downloadFile(ctx, config);
    const key: string = DownloadService.key(task);
    if (!DownloadService.valid(task, generation)) {
      await rtask.delete();
      DownloadService.deleteFile(task);
      return;
    }
    DownloadService.reqTasks.set(key, rtask);
    rtask.on('progress', (received: number, total: number): void => {
      if (!DownloadService.valid(task, generation) || task.status !== 'downloading') { return; }
      if (received > task.receivedSize) { DownloadService.stallCounts.set(key, 0); }
      task.receivedSize = received;
      if (total > 0) {
        task.totalSize = total;
        task.progress = Math.round(received * 100 / total);
      }
      DownloadService.notify(false);
    });
    rtask.on('complete', (): void => {
      if (DownloadService.valid(task, generation) && task.status === 'downloading') { DownloadService.finish(task, key); }
    });
    rtask.on('fail', (err: number): void => {
      if (!DownloadService.valid(task, generation) || task.status !== 'downloading') { return; }
      if (task.totalSize > 0 && DownloadService.fileBytes(task) >= task.totalSize) {
        DownloadService.finish(task, key);
      } else { DownloadService.failTask(task, key, generation, '下载失败(' + err.toString() + ')'); }
    });
    const statusAfterCreate: string = DownloadService.currentStatus(task);
    if (statusAfterCreate === 'paused') { await rtask.pause(); }
    else if (statusAfterCreate === 'downloading') { DownloadService.startPoll(task, key, generation); }
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
          task.progress = Math.min(100, Math.round(fb * 100 / task.totalSize));
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
      if (task.totalSize > 0 && fb >= task.totalSize) {
        DownloadService.finish(task, key);
      }
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

  private static finish(task: DownloadTask, key: string): void {
    if (task.status === 'done') {
      return;
    }
    const sz: number = DownloadService.fileBytes(task);
    if (sz <= 0 || (task.totalSize > 0 && sz < task.totalSize)) {
      DownloadService.failTask(task, key, DownloadService.versions.get(key) || 0, '下载文件不完整，请重试');
      return;
    }
    task.status = 'done';
    task.progress = 100;
    if (task.totalSize <= 0 && sz > 0) {
      // 完成时用文件实际大小补齐（此前大小未知导致"已完成 0B"）
      task.totalSize = sz;
    }
    task.receivedSize = task.totalSize > 0 ? task.totalSize : sz;
    DownloadService.detachRequest(key);
    DownloadService.stopPoll(key);
    DownloadService.notify();
    DownloadService.persist();
    DownloadService.startNext();
  }

  private static detachRequest(key: string): void {
    const rt = DownloadService.reqTasks.get(key);
    if (rt) {
      try { rt.off('progress'); } catch (_) {}
      try { rt.off('complete'); } catch (_) {}
      try { rt.off('fail'); } catch (_) {}
      DownloadService.reqTasks.delete(key);
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
    DownloadService.stopPoll(key);
    const rt: request.DownloadTask | undefined = DownloadService.reqTasks.get(key);
    if (rt !== undefined) {
      DownloadService.detachRequest(key);
      const closing: Promise<void> = rt.delete().then((): void => {}, (): void => { console.warn('[PiliMini-dl] 取消失败'); });
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
  }

  static async pause(cid: number): Promise<void> {
    await DownloadService.load();
    const t: DownloadTask | undefined = DownloadService.tasks.find((x: DownloadTask): boolean => x.cid === cid && x.status === 'downloading');
    if (t === undefined) { return; }
    t.status = 'paused';
    const key: string = DownloadService.key(t);
    DownloadService.stopPoll(key);
    DownloadService.notify();
    const rt: request.DownloadTask | undefined = DownloadService.reqTasks.get(key);
    if (rt !== undefined) {
      try { await rt.pause(); } catch (e) {
        if (t.totalSize > 0 && DownloadService.fileBytes(t) >= t.totalSize) {
          DownloadService.finish(t, key);
        } else {
          await DownloadService.failTask(t, key, DownloadService.versions.get(key) || 0, '暂停失败，已取消传输，请重试');
        }
        return;
      }
    }
    await DownloadService.persist();
    DownloadService.startNext();
  }

  static async resume(cid: number): Promise<void> {
    await DownloadService.load();
    const t: DownloadTask | undefined = DownloadService.tasks.find((x: DownloadTask): boolean =>
      x.cid === cid && (x.status === 'paused' || x.status === 'failed'));
    if (t === undefined) { return; }
    const pending: Promise<void> | undefined = DownloadService.inFlight.get(DownloadService.key(t));
    if (pending !== undefined) { await pending; }
    const closing: Promise<void> | undefined = DownloadService.cancelling.get(DownloadService.key(t));
    if (closing !== undefined) { await closing; }
    if (DownloadService.tasks.indexOf(t) < 0) { return; }
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
    const key: string = DownloadService.key(t);
    DownloadService.versions.set(key, (DownloadService.versions.get(key) || 0) + 1);
    t.status = 'paused';
    DownloadService.stopPoll(key);
    const pending: Promise<void> | undefined = DownloadService.inFlight.get(key);
    if (pending !== undefined) { await pending; }
    const closing: Promise<void> | undefined = DownloadService.cancelling.get(key);
    if (closing !== undefined) { await closing; }
    const rt: request.DownloadTask | undefined = DownloadService.reqTasks.get(key);
    if (rt !== undefined) { DownloadService.detachRequest(key); await rt.delete(); }
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
          if (/^BV[0-9A-Za-z]+_[0-9]+\.mp4$/.test(files[i])) { fs.unlinkSync(dir + files[i]); }
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
    try {
      if (task.filePath.length > 0) {
        const st = fs.statSync(task.filePath);
        return st.size;
      }
    } catch (e) {
      // 文件尚未创建
    }
    return 0;
  }
}
