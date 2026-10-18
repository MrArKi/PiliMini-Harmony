/** Nara新版资料库：任务是文件的唯一事实来源，分组不另存一份。 */
@Observed
export class DownloadTask {
  bvid: string = '';
  cid: number = 0;
  title: string = '';
  part: string = '';
  cover: string = '';
  quality: number = 64;
  duration: number = 0;
  upName: string = '';
  page: number = 0;
  seasonId: string = '';
  seasonTitle: string = '';
  seasonOrder: number = 0;
  status: string = 'queued';
  progress: number = 0;
  totalSize: number = 0;
  receivedSize: number = 0;
  filePath: string = '';
  errMsg: string = '';
  /** 只供旧版本迁移读取，新文件夹不再改写任务。 */
  folderId: string = '';
}

export class DlFolder {
  id: string = '';
  title: string = '';
  members: string[] = [];
}

@Observed
export class DlEntry {
  key: string = '';
  bvid: string = '';
  title: string = '';
  cover: string = '';
  seasonId: string = '';
  tasks: DownloadTask[] = [];
  subtitle: string = '';
  statusText: string = '';
  progress: number = -1;
}

export interface DownloadMetadata {
  page: number;
  seasonId: string;
  seasonTitle: string;
  seasonOrder: number;
}

export class OfflineContext {
  scope: string = 'all'; // all | season | folder | video
  key: string = '';
}

export function downloadKey(t: DownloadTask): string { return t.bvid + ':' + t.cid.toString(); }
export function memberMatches(ref: string, t: DownloadTask): boolean {
  return ref === 'v:' + t.bvid || ref === 't:' + downloadKey(t) ||
    (t.seasonId.length > 0 && ref === 's:' + t.seasonId);
}
