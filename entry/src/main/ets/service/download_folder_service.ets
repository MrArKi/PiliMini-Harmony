import { DlFolder, DownloadTask, memberMatches } from '../model/download';
import { prefsGet, prefsPut } from '../infra/storage/prefs';

interface FolderStore { version: number; folders: DlFolder[]; }
const KEY: string = 'dl_folders_v2';
const BACKUP: string = 'dl_folders_v1_backup';

/** 有序成员与自动合集分离；串行写入，持久化成功才替换内存状态。 */
export class DownloadFolderService {
  private static folders: DlFolder[] = [];
  private static loaded: boolean = false;
  private static writes: Promise<void> = Promise.resolve();

  static list(): DlFolder[] { return DownloadFolderService.folders; }
  static find(id: string): DlFolder | undefined { return DownloadFolderService.folders.find((f: DlFolder): boolean => f.id === id); }

  static async load(tasks: DownloadTask[]): Promise<void> {
    if (DownloadFolderService.loaded) { return; }
    const raw: string = await prefsGet(KEY, '');
    if (raw.length > 0) {
      const store = JSON.parse(raw) as FolderStore;
      if (store.version !== 2 || !Array.isArray(store.folders)) { throw new Error('文件夹数据格式不兼容，原数据已保留'); }
      DownloadFolderService.folders = DownloadFolderService.validate(store.folders);
    } else {
      const legacy: string = await prefsGet('dl_folders', '[]');
      const folders = JSON.parse(legacy) as DlFolder[];
      if (!Array.isArray(folders)) { throw new Error('旧文件夹数据损坏，原数据已保留'); }
      const migrated: DlFolder[] = [];
      for (const old of folders) {
        if (!old || typeof old.id !== 'string' || typeof old.title !== 'string') { throw new Error('旧文件夹数据损坏'); }
        const f = new DlFolder(); f.id = old.id; f.title = old.title;
        for (const t of tasks) {
          // 旧版本同视频的不同P可归入不同文件夹，迁移不能扩大原归属。
          const whole: boolean = tasks.filter((v: DownloadTask): boolean => v.bvid === t.bvid)
            .every((v: DownloadTask): boolean => v.folderId === f.id);
          const ref: string = whole ? 'v:' + t.bvid : 't:' + t.bvid + ':' + t.cid.toString();
          if (t.folderId === f.id && !f.members.includes(ref)) { f.members.push(ref); }
        }
        migrated.push(f);
      }
      // 仅备份迁移所需的旧定义和归属，不复制任务/文件/播放地址。
      if ((await prefsGet(BACKUP, '')).length === 0) {
        await prefsPut(BACKUP, JSON.stringify(migrated));
      }
      await DownloadFolderService.save(migrated);
    }
    DownloadFolderService.loaded = true;
  }

  private static validate(folders: DlFolder[]): DlFolder[] {
    const ids: Set<string> = new Set<string>();
    for (const f of folders) {
      if (!f || typeof f.id !== 'string' || !f.id || ids.has(f.id) || typeof f.title !== 'string' || !Array.isArray(f.members) ||
        f.members.some((m: string): boolean => typeof m !== 'string' || !/^(s:[0-9]+|v:BV[0-9A-Za-z]+|t:BV[0-9A-Za-z]+:[0-9]+)$/.test(m))) {
        throw new Error('文件夹数据损坏，原数据已保留');
      }
      ids.add(f.id); f.members = Array.from(new Set<string>(f.members));
    }
    return folders;
  }

  private static async save(folders: DlFolder[]): Promise<void> {
    DownloadFolderService.validate(folders);
    const store: FolderStore = { version: 2, folders: folders };
    const raw: string = JSON.stringify(store);
    await prefsPut(KEY, raw);
    if (await prefsGet(KEY, '') !== raw) { throw new Error('文件夹保存校验失败'); }
    DownloadFolderService.folders = folders;
  }

  private static update(work: (folders: DlFolder[]) => void): Promise<void> {
    const next = DownloadFolderService.writes.then(async (): Promise<void> => {
      if (!DownloadFolderService.loaded) { throw new Error('文件夹尚未初始化'); }
      const folders = JSON.parse(JSON.stringify(DownloadFolderService.folders)) as DlFolder[];
      work(folders); await DownloadFolderService.save(folders);
    });
    DownloadFolderService.writes = next.catch((): void => {});
    return next;
  }

  static add(title: string): Promise<void> {
    return DownloadFolderService.update((folders: DlFolder[]): void => {
      const name: string = title.trim(); if (!name) { throw new Error('请输入文件夹名称'); }
      const f = new DlFolder(); f.id = 'f' + Date.now().toString() + Math.random().toString(36).slice(2, 6); f.title = name;
      folders.push(f);
    });
  }
  static rename(id: string, title: string): Promise<void> {
    return DownloadFolderService.update((folders: DlFolder[]): void => {
      const f = folders.find((v: DlFolder): boolean => v.id === id);
      if (!f || !title.trim()) { throw new Error('文件夹不存在或名称为空'); } f.title = title.trim();
    });
  }
  static remove(id: string): Promise<void> {
    return DownloadFolderService.update((folders: DlFolder[]): void => {
      const i: number = folders.findIndex((f: DlFolder): boolean => f.id === id); if (i >= 0) { folders.splice(i, 1); }
    });
  }
  static addMembers(id: string, refs: string[]): Promise<void> {
    return DownloadFolderService.update((folders: DlFolder[]): void => {
      const f = folders.find((v: DlFolder): boolean => v.id === id); if (!f) { throw new Error('文件夹不存在'); }
      for (const ref of refs) { if (!f.members.includes(ref)) { f.members.push(ref); } }
    });
  }
  static removeMembers(id: string, refs: string[]): Promise<void> {
    return DownloadFolderService.update((folders: DlFolder[]): void => {
      const f = folders.find((v: DlFolder): boolean => v.id === id); if (f) { f.members = f.members.filter((m: string): boolean => !refs.includes(m)); }
    });
  }
  static move(id: string, ref: string, delta: number): Promise<void> {
    return DownloadFolderService.update((folders: DlFolder[]): void => {
      const f = folders.find((v: DlFolder): boolean => v.id === id); if (!f) { return; }
      const i: number = f.members.indexOf(ref), j: number = i + delta;
      if (i < 0 || j < 0 || j >= f.members.length) { return; }
      f.members.splice(i, 1); f.members.splice(j, 0, ref);
    });
  }
  static prune(tasks: DownloadTask[]): Promise<void> {
    const changed: boolean = DownloadFolderService.folders.some((f: DlFolder): boolean =>
      f.members.some((m: string): boolean => !tasks.some((t: DownloadTask): boolean => memberMatches(m, t))));
    if (!changed) { return Promise.resolve(); }
    return DownloadFolderService.update((folders: DlFolder[]): void => {
      for (const f of folders) { f.members = f.members.filter((m: string): boolean => tasks.some((t: DownloadTask): boolean => memberMatches(m, t))); }
    });
  }
}
