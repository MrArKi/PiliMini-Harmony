/**
 * 观看记录服务（spec-02 V2「我的页」观看记录横滑卡片，对齐 Nara 实拍 40）
 *  接口：/x/web-interface/history/cursor（需登录态 Cookie）
 */
import { getJson, postForm, parseEnvelope, ensureOk } from '../infra/http/http';
import { API_BASE } from '../config/constants';
import { CookieStore } from '../infra/cookie/cookie_store';
import { emitHistoryChanged } from '../infra/event/app_events';

interface HistoryWrite {
  bvid: string;
  cid: number;
  seconds: number;
  session: Promise<string>;
}

function cookieValue(raw: string, name: string): string {
  const prefix: string = name + '=';
  const parts: string[] = raw.split(';');
  for (let i: number = 0; i < parts.length; i++) {
    const part: string = parts[i].trim();
    if (part.startsWith(prefix)) { return part.substring(prefix.length); }
  }
  return '';
}

export interface HistoryItem {
  key: string;
  bvid: string;
  cid: number;
  title: string;
  cover: string;
  upName: string;
  /** 播放进度（秒） */
  progress: number;
  /** 总时长（秒） */
  duration: number;
  /** 多分P按Nara缩为一行标题。 */
  videos?: number;
  /** 观看时间（秒） */
  viewAt: number;
}

interface HistHistory {
  oid: number;
  bvid?: string;
  cid: number;
  page?: number;
  part?: string;
  business: string;
}

interface HistItem {
  title: string;
  long_title?: string;
  cover: string;
  history: HistHistory;
  author_name?: string;
  view_at: number;
  progress: number;
  duration: number;
  videos?: number;
}

export interface HistoryPage {
  items: HistoryItem[];
  hasMore: boolean;
  nextMax: number;
  nextViewAt: number;
}

/** 页面查询绑定的只读会话，不持久化，不在日志中输出。 */
export interface HistorySession {
  cookie: string;
  revision: number;
  logged: boolean;
}

export interface HistorySearchResult {
  items: HistoryItem[];
  hasMore: boolean;
  nextPage: number;
}

interface HistCursor {
  max: number;
  view_at: number;
  business: string;
  ps: number;
}

interface HistData {
  list?: HistItem[];
  cursor?: HistCursor;
}

function toHttps(u: string): string {
  if (u.startsWith('http://')) {
    return 'https://' + u.substring(7);
  }
  return u;
}

function mapHistory(list: HistItem[]): HistoryItem[] {
  const out: HistoryItem[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i: number = 0; i < list.length; i++) {
    const it: HistItem = list[i];
    const hist: HistHistory | undefined = it.history;
    if (hist === undefined || hist.business !== 'archive') { continue; }
    const bvid: string = hist.bvid || '';
    if (!/^BV[0-9A-Za-z]{10}$/.test(bvid)) { continue; }
    const key: string = bvid + '_' + (hist.cid || 0).toString() + '_' + (it.view_at || 0).toString();
    if (seen.has(key)) { continue; }
    seen.add(key);
    out.push({ key: key, bvid: bvid, cid: hist.cid || 0, title: it.title || '',
      cover: toHttps(it.cover || ''), upName: it.author_name || '',
      progress: it.progress || 0, duration: it.duration || 0, viewAt: it.view_at || 0, videos: it.videos || 1 });
  }
  return out;
}

export class HistoryService {
  private static pending: Map<string, HistoryWrite> = new Map<string, HistoryWrite>();
  private static sending: boolean = false;

  static assertSession(session: HistorySession): void {
    if (session.revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化'); }
  }

  static async captureSession(revision: number = CookieStore.sessionRevision()): Promise<HistorySession> {
    if (revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化'); }
    const cookie: string = await CookieStore.getRaw();
    if (revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化'); }
    return { cookie: cookie, revision: revision, logged: cookieValue(cookie, 'SESSDATA').length > 0 };
  }

  private static async read(url: string, session: HistorySession): Promise<HistData> {
    HistoryService.assertSession(session);
    if (!session.logged) { throw new Error('请先登录'); }
    const raw: string = await getJson(url, { 'Cookie': session.cookie });
    // 必须先拒绝旧账号响应，旧-101不能登出已切换的新账号。
    HistoryService.assertSession(session);
    const resp = parseEnvelope<HistData>(raw);
    ensureOk(resp);
    if (resp.data === undefined || resp.data === null || typeof resp.data !== 'object' || Array.isArray(resp.data)) {
      throw new Error('观看记录数据为空');
    }
    // Nara HistoryData.list为nullable；成功响应的null/缺失列表是正常空末页。
    if (resp.data.list !== undefined && resp.data.list !== null && !Array.isArray(resp.data.list)) {
      throw new Error('观看记录列表格式异常');
    }
    return resp.data;
  }

  /** 全局串行，单视频只留最新待发进度；慢网/切页不积累无限心跳。 */
  static report(bvid: string, cid: number, seconds: number, session: Promise<string>): void {
    if (!/^BV[0-9A-Za-z]{10}$/.test(bvid) || !Number.isSafeInteger(cid) || cid <= 0 ||
      !Number.isInteger(seconds) || (seconds !== -1 && seconds <= 0)) { return; }
    const key: string = bvid + ':' + cid.toString();
    HistoryService.pending.delete(key);
    HistoryService.pending.set(key, { bvid: bvid, cid: cid, seconds: seconds, session: session });
    while (HistoryService.pending.size > 16) {
      HistoryService.pending.delete(Array.from(HistoryService.pending.keys())[0]);
    }
    if (!HistoryService.sending) { HistoryService.drain(); }
  }

  private static async drain(): Promise<void> {
    HistoryService.sending = true;
    try {
      while (HistoryService.pending.size > 0) {
        const key: string = Array.from(HistoryService.pending.keys())[0];
        const item: HistoryWrite = HistoryService.pending.get(key) as HistoryWrite;
        HistoryService.pending.delete(key);
        try {
          const cookie: string = await item.session;
          const csrf: string = cookieValue(cookie, 'bili_jct');
          if (cookieValue(cookie, 'SESSDATA').length === 0 || csrf.length === 0 ||
            cookie !== await CookieStore.getRaw()) { continue; }
          const form: Record<string, string> = {
            'bvid': item.bvid, 'cid': item.cid.toString(), 'type': '3',
            'played_time': item.seconds.toString(), 'csrf': csrf
          };
          const raw: string = await postForm(API_BASE + '/x/click-interface/web/heartbeat', form, cookie);
          // 旧会话的迟到响应不能登出新账号，也不能刷新新账号的卡片。
          if (cookie !== await CookieStore.getRaw()) { continue; }
          const resp = parseEnvelope<Object>(raw);
          ensureOk(resp);
          console.info('[PiliMini-history] heartbeat ok progress=' + item.seconds.toString());
          emitHistoryChanged();
        } catch (e) {
          // 下次真实进度/状态变化再报；不阻塞内核，不记录凭据/响应体。
          console.warn('[PiliMini-history] heartbeat failed');
        }
      }
    } finally { HistoryService.sending = false; }
  }

  /** 最近观看记录（默认 20 条；未登录/失败返回空数组） */
  static async recent(ps: number = 20): Promise<HistoryItem[]> {
    try {
      const session: HistorySession = await HistoryService.captureSession();
      if (!session.logged) { return []; }
      const url: string = API_BASE + '/x/web-interface/history/cursor?max=0&view_at=0&business=&ps=' + ps.toString();
      const data: HistData = await HistoryService.read(url, session);
      return mapHistory(data.list || []);
    } catch (e) {
      console.warn('[PiliMini-history] recent failed');
      return [];
    }
  }

  /** 分页拉取（观看记录页用）：cursor = 上一页返回的 max/view_at */
  static async page(max: number, viewAt: number, ps: number = 20,
    session?: HistorySession): Promise<HistoryPage> {
    const used: HistorySession = session === undefined ? await HistoryService.captureSession() : session;
    const url: string = API_BASE + '/x/web-interface/history/cursor?max=' + max.toString() +
      '&view_at=' + viewAt.toString() + '&business=&ps=' + ps.toString();
    const data: HistData = await HistoryService.read(url, used);
    const list: HistItem[] = data.list || [];
    if (list.length === 0) {
      return { items: [], hasMore: false, nextMax: 0, nextViewAt: 0 };
    }
    const cur: HistCursor | undefined = data.cursor;
    // Nara用原始末项oid/viewAt推进；兼容接口未带cursor的返回，仍不跳过非视频业务。
    const last: HistItem = list[list.length - 1];
    const nextMax: number = cur !== undefined && cur.max > 0 ? cur.max : (last.history?.oid || 0);
    const nextViewAt: number = cur !== undefined && cur.view_at > 0 ? cur.view_at : (last.view_at || 0);
    if (!Number.isSafeInteger(nextMax) || !Number.isSafeInteger(nextViewAt) || nextMax <= 0 || nextViewAt <= 0 ||
      (nextMax === max && nextViewAt === viewAt)) {
      throw new Error('历史分页游标未推进，请重试');
    }
    return { items: mapHistory(list), hasMore: true, nextMax: nextMax, nextViewAt: nextViewAt };
  }

  /** Nara服务端搜索；以原始列表判末页，不能因当前仅支持视频而误判结束。 */
  static async search(keyword: string, pn: number, session: HistorySession): Promise<HistorySearchResult> {
    const query: string = keyword.trim();
    if (query.length === 0 || pn < 1 || !Number.isSafeInteger(pn)) { throw new Error('搜索参数无效'); }
    const url: string = API_BASE + '/x/web-interface/history/search?pn=' + pn.toString() +
      '&keyword=' + encodeURIComponent(query) + '&business=all';
    const data: HistData = await HistoryService.read(url, session);
    const list: HistItem[] = data.list || [];
    return { items: mapHistory(list), hasMore: list.length > 0, nextPage: list.length > 0 ? pn + 1 : pn };
  }
}
