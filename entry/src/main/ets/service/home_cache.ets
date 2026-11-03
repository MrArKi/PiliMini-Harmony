/** 首页首屏快照：官方 Preferences + SHA256 账号隔离，不阻塞主壳导航。 */
import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { prefsGet, prefsPut } from '../infra/storage/prefs';
import { CookieStore } from '../infra/cookie/cookie_store';
import { VideoItem } from '../model/video_item';

export interface HomeCacheScope { key: string; revision: number; }
export interface HomeSnapshot { schema: number; savedAt: number; nextCursor: number; items: VideoItem[]; }

const PREFIX: string = 'home_snapshot_v1_';
const TTL: number = 24 * 60 * 60 * 1000;

function validNumber(value: number): boolean {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER;
}

/** 只拷贝展示字段，损坏内容不送入组件，也不保留任意接口扩展字段。 */
function cleanItem(item: VideoItem): VideoItem | undefined {
  if (item === undefined || item === null || typeof item !== 'object' ||
    typeof item.bvid !== 'string' || !/^BV[0-9A-Za-z]{10}$/.test(item.bvid) ||
    typeof item.title !== 'string' || item.title.length > 1000 ||
    typeof item.cover !== 'string' || item.cover.length > 2048 || !/^https?:\/\//.test(item.cover) ||
    typeof item.upName !== 'string' || item.upName.length > 200 ||
    typeof item.upFace !== 'string' || item.upFace.length > 2048 ||
    !validNumber(item.cid) || !validNumber(item.playCount) || !validNumber(item.danmaku) ||
    !validNumber(item.pubdate) || !validNumber(item.duration)) { return undefined; }
  return {
    key: item.bvid + '_snapshot', bvid: item.bvid, cid: item.cid, title: item.title, cover: item.cover,
    upName: item.upName, upMid: validNumber(item.upMid || 0) ? (item.upMid || 0) : 0,
    upFace: item.upFace, playCount: item.playCount, danmaku: item.danmaku,
    pubdate: item.pubdate, duration: item.duration, aid: validNumber(item.aid || 0) ? (item.aid || 0) : 0,
    zoneName: typeof item.zoneName === 'string' ? item.zoneName.substring(0, 200) : ''
  };
}

export class HomeCache {
  private static writing: Promise<void> = Promise.resolve();

  static async scope(revision: number): Promise<HomeCacheScope | undefined> {
    try {
      const loggedIn: boolean = await CookieStore.isLogin();
      if (revision !== CookieStore.sessionRevision()) { return undefined; }
      if (!loggedIn) { return { key: PREFIX + 'guest', revision: revision }; }
      const uid: string = await CookieStore.get('DedeUserID');
      if (!/^[0-9]{1,20}$/.test(uid) || revision !== CookieStore.sessionRevision()) { return undefined; }
      const md = cryptoFramework.createMd('SHA256');
      await md.update({ data: new Uint8Array(buffer.from('PiliMini.home.v1:' + uid, 'utf-8').buffer) });
      const digest = await md.digest();
      if (revision !== CookieStore.sessionRevision()) { return undefined; }
      return { key: PREFIX + buffer.from(digest.data).toString('hex'), revision: revision };
    } catch (_) { return undefined; }
  }

  static async read(scope: HomeCacheScope): Promise<HomeSnapshot | undefined> {
    try {
      if (scope.revision !== CookieStore.sessionRevision()) { return undefined; }
      const raw: string = await prefsGet(scope.key, '');
      if (scope.revision !== CookieStore.sessionRevision() || raw.length === 0 || raw.length > 65536) { return undefined; }
      const parsed: HomeSnapshot = JSON.parse(raw) as HomeSnapshot;
      const now: number = Date.now();
      if (parsed === undefined || parsed === null || parsed.schema !== 1 ||
        !validNumber(parsed.savedAt) || parsed.savedAt > now + 60000 || now - parsed.savedAt > TTL ||
        !validNumber(parsed.nextCursor) || parsed.nextCursor < 1 || !Number.isInteger(parsed.nextCursor) ||
        !Array.isArray(parsed.items) || parsed.items.length > 12) { return undefined; }
      const items: VideoItem[] = [];
      const seen: Set<string> = new Set<string>();
      for (let i: number = 0; i < parsed.items.length; i++) {
        const item: VideoItem | undefined = cleanItem(parsed.items[i]);
        if (item === undefined) { return undefined; }
        if (!seen.has(item.bvid)) { seen.add(item.bvid); items.push(item); }
      }
      if (items.length === 0) { return undefined; }
      return { schema: 1, savedAt: parsed.savedAt, nextCursor: parsed.nextCursor, items: items };
    } catch (_) { return undefined; }
  }

  static save(scope: HomeCacheScope, items: VideoItem[], nextCursor: number): void {
    if (scope.revision !== CookieStore.sessionRevision() || !validNumber(nextCursor) || nextCursor < 1) { return; }
    const safe: VideoItem[] = [];
    for (let i: number = 0; i < Math.min(items.length, 12); i++) {
      const item: VideoItem | undefined = cleanItem(items[i]);
      if (item !== undefined) { safe.push(item); }
    }
    if (safe.length === 0) { return; }
    const snapshot: HomeSnapshot = { schema: 1, savedAt: Date.now(), nextCursor: nextCursor, items: safe };
    const raw: string = JSON.stringify(snapshot);
    if (raw.length > 65536) { return; }
    HomeCache.writing = HomeCache.writing.then(async (): Promise<void> => {
      if (scope.revision !== CookieStore.sessionRevision()) { return; }
      await prefsPut(scope.key, raw);
    }).catch((): void => {});
  }
}
