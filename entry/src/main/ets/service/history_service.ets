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
}

export interface HistoryPage {
  items: HistoryItem[];
  hasMore: boolean;
  nextMax: number;
  nextViewAt: number;
}

interface HistCursor {
  max: number;
  view_at: number;
  business: string;
  ps: number;
}

interface HistData {
  list: HistItem[];
  cursor?: HistCursor;
}

function toHttps(u: string): string {
  if (u.startsWith('http://')) {
    return 'https://' + u.substring(7);
  }
  return u;
}

export class HistoryService {
  private static pending: Map<string, HistoryWrite> = new Map<string, HistoryWrite>();
  private static sending: boolean = false;

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
      const url: string = API_BASE + '/x/web-interface/history/cursor?max=0&view_at=0&business=&ps=' + ps.toString();
      const raw: string = await getJson(url);
      const resp = parseEnvelope<HistData>(raw);
      if (resp.code === -101) { ensureOk(resp); }
      if (resp.code !== 0) {
        return [];
      }
      const data: HistData | undefined = resp.data;
      if (data === undefined) {
        return [];
      }
      const out: HistoryItem[] = [];
      for (let i = 0; i < data.list.length; i++) {
        const it: HistItem = data.list[i];
        const hist: HistHistory | undefined = it.history;
        if (hist === undefined || hist.business !== 'archive') {
          continue;
        }
        const bvid: string = hist.bvid !== undefined ? hist.bvid : '';
        if (bvid.length === 0) {
          continue;
        }
        out.push({
          key: bvid + '_' + it.view_at.toString() + '_' + i.toString(),
          bvid: bvid,
          cid: hist.cid,
          title: it.title,
          cover: toHttps(it.cover),
          upName: it.author_name !== undefined ? it.author_name : '',
          progress: it.progress,
          duration: it.duration,
          viewAt: it.view_at
        });
      }
      return out;
    } catch (e) {
      console.warn('[PiliMini-history] exception=' + JSON.stringify(e));
      return [];
    }
  }

  /** 分页拉取（观看记录页用）：cursor = 上一页返回的 max/view_at */
  static async page(max: number, viewAt: number, ps: number = 20): Promise<HistoryPage> {
    const url: string = API_BASE + '/x/web-interface/history/cursor?max=' + max.toString() +
      '&view_at=' + viewAt.toString() + '&business=&ps=' + ps.toString();
    const raw: string = await getJson(url);
    const resp = parseEnvelope<HistData>(raw);
    ensureOk(resp);
    const data: HistData | undefined = resp.data;
    if (data === undefined) {
      return { items: [], hasMore: false, nextMax: 0, nextViewAt: 0 };
    }
    const out: HistoryItem[] = [];
    for (let i = 0; i < data.list.length; i++) {
      const it: HistItem = data.list[i];
      const hist: HistHistory | undefined = it.history;
      if (hist === undefined) {
        continue;
      }
      const bvid: string = hist.bvid !== undefined ? hist.bvid : '';
      if (bvid.length === 0 || hist.business !== 'archive') {
        continue;
      }
      out.push({
        key: bvid + '_' + it.view_at.toString() + '_' + i.toString(),
        bvid: bvid,
        cid: hist.cid,
        title: it.title,
        cover: toHttps(it.cover),
        upName: it.author_name !== undefined ? it.author_name : '',
        progress: it.progress,
        duration: it.duration,
        viewAt: it.view_at
      });
    }
    let nextMax: number = 0;
    let nextViewAt: number = 0;
    let hasMore: boolean = false;
    const cur: HistCursor | undefined = data.cursor;
    if (cur !== undefined && data.list.length > 0) {
      nextMax = cur.max;
      nextViewAt = cur.view_at;
      hasMore = true;
    }
    return { items: out, hasMore: hasMore, nextMax: nextMax, nextViewAt: nextViewAt };
  }
}
