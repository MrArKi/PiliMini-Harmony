/**
 * 播放进度记忆（spec-06a 任务 6a.4）
 * key = bvid:cid → 毫秒；内存缓存 + 节流落盘（5s）；退出时强制落盘
 * 风险5加固：看完即删记录 + LRU 淘汰（最多 200 条，防键无限增长）
 */
import { prefsPut, prefsGet, prefsDelete, prefsAllKeys } from './prefs';

const PREFIX: string = 'pos_';
const THROTTLE_MS: number = 5000;
const INDEX_KEY: string = 'pos_index';
const MAX_ENTRIES: number = 200;

const mem: Map<string, number> = new Map<string, number>();
const lastSave: Map<string, number> = new Map<string, number>();
let indexCache: string[] | null = null;
let writes: Promise<void> = Promise.resolve();

function enqueue(work: () => Promise<void>): Promise<void> {
  const next: Promise<void> = writes.then(work);
  writes = next.catch((): void => {});
  return next;
}

function cache(k: string, ms: number): void {
  mem.delete(k);
  mem.set(k, ms);
  while (mem.size > MAX_ENTRIES) {
    const oldest: string = Array.from(mem.keys())[0];
    mem.delete(oldest);
    lastSave.delete(oldest);
  }
}

function keyOf(bvid: string, cid: number): string {
  return PREFIX + bvid + ':' + cid.toString();
}

/** 读键索引（首次运行迁移历史遗留 pos_ 键） */
async function loadIndex(): Promise<string[]> {
  if (indexCache !== null) {
    return indexCache;
  }
  const raw: string = await prefsGet(INDEX_KEY, '[]');
  let arr: string[] = [];
  try {
    const parsed = JSON.parse(raw) as string[];
    if (Array.isArray(parsed)) {
      for (let i = 0; i < parsed.length; i++) {
        if (typeof parsed[i] === 'string' && parsed[i] !== INDEX_KEY && parsed[i].startsWith(PREFIX)) {
          arr.push(parsed[i]);
        }
      }
    }
  } catch (e) {
    arr = [];
  }
  if (arr.length === 0) {
    // 一次性迁移：历史版本无索引，扫描 prefs 全部 pos_ 键并入
    try {
      const allKeys: string[] = await prefsAllKeys();
      for (let i = 0; i < allKeys.length; i++) {
        if (allKeys[i] !== INDEX_KEY && allKeys[i].startsWith(PREFIX)) {
          arr.push(allKeys[i]);
        }
      }
      if (arr.length > 0) {
        await prefsPut(INDEX_KEY, JSON.stringify(arr));
      }
    } catch (e) {
      // 迁移失败不影响功能
    }
  }
  indexCache = arr;
  return arr;
}

async function saveIndex(list: string[]): Promise<void> {
  indexCache = list;
  await prefsPut(INDEX_KEY, JSON.stringify(list));
}

/** 写盘后登记键（LRU 移到末尾）+ 超量淘汰最旧 */
async function trackKey(k: string): Promise<void> {
  const list: string[] = await loadIndex();
  const at: number = list.indexOf(k);
  if (at >= 0) {
    if (at === list.length - 1) {
      return; // 已在末尾
    }
    list.splice(at, 1);
    list.push(k);
  } else {
    list.push(k);
  }
  while (list.length > MAX_ENTRIES) {
    const oldest: string = list[0];
    list.splice(0, 1);
    await prefsDelete(oldest);
    mem.delete(oldest);
    lastSave.delete(oldest);
  }
  await saveIndex(list);
}

async function untrackKey(k: string): Promise<void> {
  const list: string[] = await loadIndex();
  const at: number = list.indexOf(k);
  if (at >= 0) {
    list.splice(at, 1);
    await saveIndex(list);
  }
}

export class PlaybackPos {
  /** 读取上次进度（毫秒；0 = 无记录） */
  static async get(bvid: string, cid: number): Promise<number> {
    await writes;
    const k: string = keyOf(bvid, cid);
    const cached: number | undefined = mem.get(k);
    if (cached !== undefined) {
      return cached;
    }
    const raw: string = await prefsGet(k, '');
    if (raw.length === 0) {
      return 0;
    }
    const v: number = parseInt(raw, 10);
    const ms: number = isNaN(v) ? 0 : v;
    cache(k, ms);
    return ms;
  }

  /** 节流写入（播放中每 5s 调一次） */
  static async save(bvid: string, cid: number, ms: number): Promise<void> {
    const k: string = keyOf(bvid, cid);
    cache(k, ms);
    const last: number = lastSave.get(k) !== undefined ? (lastSave.get(k) as number) : 0;
    const now: number = Date.now();
    if (now - last < THROTTLE_MS) {
      return;
    }
    lastSave.set(k, now);
    await enqueue(async (): Promise<void> => {
      await prefsPut(k, ms.toString());
      await trackKey(k);
    });
  }

  /** 强制落盘（暂停 / 退出播放页 / onBackground） */
  static async flush(bvid: string, cid: number, ms: number): Promise<void> {
    const k: string = keyOf(bvid, cid);
    cache(k, ms);
    lastSave.set(k, Date.now());
    await enqueue(async (): Promise<void> => {
      await prefsPut(k, ms.toString());
      await trackKey(k);
    });
  }

  /** 删除一条进度记录（看完 / 清理用） */
  static async remove(bvid: string, cid: number): Promise<void> {
    const k: string = keyOf(bvid, cid);
    mem.delete(k);
    lastSave.delete(k);
    await enqueue(async (): Promise<void> => {
      await prefsDelete(k);
      await untrackKey(k);
    });
  }

  /** 进度视为已看完（距结尾 10s 内）→ 删除记录（风险5：防键无限增长） */
  static async clearIfFinished(bvid: string, cid: number, ms: number, durationMs: number): Promise<boolean> {
    if (durationMs > 0 && ms > durationMs - 10000) {
      await PlaybackPos.remove(bvid, cid);
      return true;
    }
    return false;
  }
}
