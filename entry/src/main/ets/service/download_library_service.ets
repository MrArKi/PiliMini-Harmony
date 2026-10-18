import { fileIo as fs } from '@kit.CoreFileKit';
import { DownloadTask, DlEntry, OfflineContext, downloadKey, memberMatches } from '../model/download';
import { DownloadService } from './download_service';
import { DownloadFolderService } from './download_folder_service';
import { PlaybackPos } from '../infra/storage/playback_pos';
import { prefsGet, prefsPut, prefsDelete } from '../infra/storage/prefs';

interface ContinueRecord { bvid: string; cid: number; scope: string; key: string; }
export interface ContinueTarget { task: DownloadTask; context: OfflineContext; position: number; }
const RECENT: string = 'dl_continue_v1';

/** 纯派生分组和播放范围；无定时器、无页面引用，不存自动分组。 */
export class DownloadLibraryService {
  private static lastRecord: string = '';
  private static writes: Promise<void> = Promise.resolve();

  static sort(tasks: DownloadTask[]): DownloadTask[] {
    const rank: Map<string, number> = new Map<string, number>();
    const videos: Map<string, number> = new Map<string, number>();
    const group = (t: DownloadTask): string => t.seasonId ? 's:' + t.seasonId : 'v:' + t.bvid;
    tasks.forEach((t: DownloadTask, i: number): void => {
      if (!rank.has(group(t))) { rank.set(group(t), i); }
      if (!videos.has(t.bvid)) { videos.set(t.bvid, i); }
    });
    return tasks.slice().sort((a: DownloadTask, b: DownloadTask): number => {
      const groups: number = (rank.get(group(a)) || 0) - (rank.get(group(b)) || 0);
      if (groups !== 0) { return groups; }
      if (a.bvid !== b.bvid) {
        const ai: number = a.seasonOrder > 0 ? a.seasonOrder : Number.MAX_SAFE_INTEGER;
        const bi: number = b.seasonOrder > 0 ? b.seasonOrder : Number.MAX_SAFE_INTEGER;
        if (ai !== bi) { return ai - bi; }
        return (videos.get(a.bvid) || 0) - (videos.get(b.bvid) || 0);
      }
      const ai: number = a.page || Number(/^P(\d+)/i.exec(a.part)?.[1] || '0');
      const bi: number = b.page || Number(/^P(\d+)/i.exec(b.part)?.[1] || '0');
      return (ai > 0 ? ai : Number.MAX_SAFE_INTEGER) - (bi > 0 ? bi : Number.MAX_SAFE_INTEGER);
    });
  }

  static inScope(tasks: DownloadTask[], context: OfflineContext): DownloadTask[] {
    if (context.scope === 'folder') {
      const f = DownloadFolderService.find(context.key); if (!f) { return []; }
      const out: DownloadTask[] = [], seen: Set<string> = new Set<string>();
      for (const ref of f.members) {
        for (const t of DownloadLibraryService.sort(tasks.filter((v: DownloadTask): boolean => memberMatches(ref, v)))) {
          if (!seen.has(downloadKey(t))) { seen.add(downloadKey(t)); out.push(t); }
        }
      }
      return out;
    }
    return DownloadLibraryService.sort(tasks.filter((t: DownloadTask): boolean => context.scope === 'all' ||
      (context.scope === 'season' && t.seasonId === context.key) || (context.scope === 'video' && t.bvid === context.key)));
  }

  static groups(tasks: DownloadTask[], context: OfflineContext, groupSeasons: boolean): DlEntry[] {
    const groups: Map<string, DlEntry> = new Map<string, DlEntry>();
    const scoped: DownloadTask[] = DownloadLibraryService.inScope(tasks, context);
    const folder = context.scope === 'folder' ? DownloadFolderService.find(context.key) : undefined;
    for (const t of scoped) {
      // 文件夹保留成员粒度和顺序：合集引用仍作为合集，视频/单P不被自动吞进合集。
      const ref: string | undefined = folder?.members.find((m: string): boolean => memberMatches(m, t));
      const season: boolean = !!t.seasonId && (ref ? ref.startsWith('s:') : groupSeasons);
      const key: string = context.scope === 'video' ? 't:' + downloadKey(t) : ref || (season ? 's:' + t.seasonId : 'v:' + t.bvid);
      let e = groups.get(key);
      if (!e) {
        e = new DlEntry(); e.key = key; e.bvid = season ? '' : t.bvid; e.title = season ? t.seasonTitle : t.title;
        e.cover = t.cover; e.seasonId = season ? t.seasonId : ''; groups.set(key, e);
      }
      e.tasks.push(t);
    }
    return Array.from(groups.values());
  }

  /** 传输列表按单P呈现，未完成任务不能误入只含完成内容的资料页。 */
  static transfers(tasks: DownloadTask[]): DlEntry[] {
    return tasks.map((t: DownloadTask): DlEntry => {
      const e = new DlEntry(); e.key = 't:' + downloadKey(t); e.bvid = t.bvid;
      e.title = t.part ? t.title + ' · ' + t.part : t.title; e.cover = t.cover; e.tasks = [t];
      return e;
    });
  }

  static available(t: DownloadTask): boolean {
    if (t.status !== 'done' || !t.filePath) { return false; }
    try { return fs.statSync(t.filePath).size > 0; } catch (_) { return false; }
  }
  static playlist(context: OfflineContext): DownloadTask[] {
    return DownloadLibraryService.inScope(DownloadService.list(), context).filter((t: DownloadTask): boolean => DownloadLibraryService.available(t));
  }
  static params(t: DownloadTask, context: OfflineContext): Record<string, string> {
    const params: Record<string, string> = {
      'bvid': t.bvid, 'cid': t.cid.toString(), 'localPath': t.filePath,
      'title': t.part ? t.title + ' · ' + t.part : t.title, 'localCover': t.cover, 'localArtist': t.upName,
      'localDuration': t.duration.toString(), 'offlineScope': context.scope, 'offlineKey': context.key
    };
    return params;
  }
  static remember(bvid: string, cid: number, context: OfflineContext): void {
    const record: ContinueRecord = { bvid: bvid, cid: cid, scope: context.scope, key: context.key };
    const raw: string = JSON.stringify(record); if (raw === DownloadLibraryService.lastRecord) { return; }
    DownloadLibraryService.lastRecord = raw;
    DownloadLibraryService.writes = DownloadLibraryService.writes.then(async (): Promise<void> => {
      try { await prefsPut(RECENT, raw); }
      catch (_) { if (DownloadLibraryService.lastRecord === raw) { DownloadLibraryService.lastRecord = ''; } }
    });
  }
  static async continueTarget(): Promise<ContinueTarget | undefined> {
    await DownloadLibraryService.writes;
    const raw: string = await prefsGet(RECENT, ''); if (!raw) { return undefined; }
    try {
      const rec = JSON.parse(raw) as ContinueRecord;
      const ctx: OfflineContext = { scope: rec.scope, key: rec.key };
      const t = DownloadLibraryService.playlist(ctx).find((v: DownloadTask): boolean => v.bvid === rec.bvid && v.cid === rec.cid);
      if (t) {
        const ms: number = await PlaybackPos.get(t.bvid, t.cid);
        if (ms > 5000 && t.duration * 1000 - ms > 400) { return { task: t, context: ctx, position: ms }; }
        // 已完成的记录不用保留，但不删除其他视频的进度。
      }
    } catch (_) { /* 无效记录只清此键，真实下载文件不受影响。 */ }
    await prefsDelete(RECENT); DownloadLibraryService.lastRecord = '';
    return undefined;
  }
}
