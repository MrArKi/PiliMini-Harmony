/** UP空间：Web/WBI接口，与Nara空间模型分开映射；无APP密钥、无全局列表缓存。 */
import { getJson, postForm, buildQuery, parseEnvelope, ensureOk } from '../infra/http/http';
import { wbiSign } from '../infra/sign/wbi';
import { CookieStore } from '../infra/cookie/cookie_store';
import { API_BASE } from '../config/constants';
import { VideoItem } from '../model/video_item';
import { DynamicService, DynItem } from './dynamic_service';
import { emitFollowChanged } from '../infra/event/app_events';

export interface MemberProfile {
  mid: number; name: string; face: string; banner: string; sign: string;
  level: number; vip: boolean; official: string; followers: number; following: number;
  likes: number; videoCount: number;
}
export interface MemberOpus {
  opus_id: string; content: string; cover?: MemberCover; stat?: OpusStat;
}
interface OpusStat { like?: string; }
export interface MemberCover { url: string; width: number; height: number; }
export interface MemberCollection {
  id: number; title: string; cover: string; count: number; kind: string; ptime: number;
}
export interface MemberEntry {
  key: string; video?: VideoItem; dynamic?: DynItem; opus?: MemberOpus; collection?: MemberCollection;
}
export interface MemberResult { items: MemberEntry[]; next: string; hasMore: boolean; total: number; }
export interface MemberRelation { attribute?: number; special?: number; }
/** 单次关系操作的会话快照，仅在请求期间持有，不持久化或记录日志。 */
export interface MemberRelationSession { cookie: string; csrf: string; account: string; revision: number; }
interface Official { title?: string; desc?: string; }
interface OfficialVerify { desc?: string; type?: number; }
interface Level { current_level?: number; }
interface Vip { status?: number; vipStatus?: number; }
interface ProfileRaw {
  mid: number; name: string; face: string; sign?: string; top_photo?: string;
  level?: number; vip?: Vip; official?: Official;
}
interface CardRaw {
  mid: string; name: string; face: string; sign?: string; fans?: number; friend?: number;
  level_info?: Level; vip?: Vip; Official?: Official; official_verify?: OfficialVerify;
}
interface CardSpace { s_img?: string; l_img?: string; }
interface CardData { card: CardRaw; space?: CardSpace; archive_count?: number; follower?: number; like_num?: number; }
interface VideoStat { view?: number; danmaku?: number; }
interface ArchiveOwner { name?: string; face?: string; }
interface ArchiveRaw {
  aid?: number; bvid: string; title: string; pic?: string; cover?: string;
  length?: string; duration?: number; play?: number; video_review?: number;
  created?: number; pubdate?: number; author?: string; stat?: VideoStat;
  owner?: ArchiveOwner;
}
interface ArchiveList { vlist?: ArchiveRaw[]; }
interface PageRaw { count?: number; total?: number; num?: number; size?: number; }
interface ArchiveData { list?: ArchiveList; page?: PageRaw; }
interface OpusData { items?: MemberOpus[]; offset?: string; has_more?: boolean; }
interface CollectionMeta {
  season_id?: number; series_id?: number; name?: string; cover?: string; total?: number; ptime?: number; ctime?: number;
}
interface CollectionRaw { meta?: CollectionMeta; archives?: ArchiveRaw[]; }
interface CollectionLists { seasons_list?: CollectionRaw[]; series_list?: CollectionRaw[]; page?: PageRaw; }
interface CollectionData { items_lists?: CollectionLists; }
interface SeasonData { archives?: ArchiveRaw[]; page?: PageRaw; meta?: CollectionMeta; }
export interface MemberFolder {
  id: number; title: string; cover: string; media_count: number; attr?: number; type?: number;
  upper?: ArchiveOwner; view_count?: number; state?: number;
}
interface FoldersData { list?: MemberFolder[]; count?: number; has_more?: boolean; }
export interface MemberFolderResult { items: MemberFolder[]; hasMore: boolean; }

export function memberUrl(url: string): string {
  const value: string = (url || '').trim();
  // WBI top_photo也会返回bfs/space/...；不能把相对路径当域名请求。
  if (/^\/?bfs\//.test(value)) { return 'https://i0.hdslb.com/' + value.replace(/^\//, ''); }
  const absolute: string = value.startsWith('//') ? 'https:' + value : value;
  return /^https?:\/\/[^/\s]+(?:\/|$)/i.test(absolute) ? absolute.replace(/^http:/i, 'https:') : '';
}
function duration(v: ArchiveRaw): number {
  if (v.duration !== undefined) { return v.duration; }
  const parts: string[] = (v.length || '0').split(':');
  let n: number = 0;
  for (let i: number = 0; i < parts.length; i++) { n = n * 60 + (parseInt(parts[i], 10) || 0); }
  return n;
}
function video(v: ArchiveRaw): VideoItem {
  return { key: 'space_video_' + v.bvid, bvid: v.bvid, aid: v.aid || 0, cid: 0,
    title: (v.title || '').replace(/<[^>]*>/g, ''), cover: memberUrl(v.pic || v.cover || ''),
    upName: v.author || v.owner?.name || '', upFace: memberUrl(v.owner?.face || ''), playCount: v.play || v.stat?.view || 0,
    danmaku: v.video_review || v.stat?.danmaku || 0, pubdate: v.created || v.pubdate || 0,
    duration: duration(v) };
}
async function read<T>(path: string, params: Record<string, string>, signed: boolean = false,
  mid: number = 0): Promise<T> {
  const p: Record<string, string> = signed ? await wbiSign(params) : params;
  const raw: string = await getJson(API_BASE + path + '?' + buildQuery(p), {
    'Referer': mid > 0 ? 'https://space.bilibili.com/' + mid.toString() : 'https://www.bilibili.com/',
    'Origin': 'https://space.bilibili.com'
  });
  const response = parseEnvelope<T>(raw); ensureOk(response);
  if (response.data === undefined || response.data === null) { throw new Error('空间数据为空，请重试'); }
  return response.data;
}

export class MemberService {
  static assertRelationSession(session: MemberRelationSession): void {
    if (session.revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化，请重新操作'); }
  }

  static async captureRelationSession(revision: number = CookieStore.sessionRevision()): Promise<MemberRelationSession> {
    if (revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化，请重新操作'); }
    const cookie: string = await CookieStore.getRaw();
    if (revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化，请重新操作'); }
    const values: Record<string, string> = {};
    const parts: string[] = cookie.split(';');
    for (let i: number = 0; i < parts.length; i++) {
      const segment: string = parts[i].trim();
      const separator: number = segment.indexOf('=');
      if (separator > 0) { values[segment.substring(0, separator).trim()] = segment.substring(separator + 1).trim(); }
    }
    if (!values['SESSDATA'] || !values['bili_jct'] || !values['DedeUserID']) { throw new Error('请先登录'); }
    return { cookie: cookie, csrf: values['bili_jct'], account: values['DedeUserID'], revision: revision };
  }

  static async relationForSession(mid: number, session: MemberRelationSession): Promise<MemberRelation> {
    MemberService.assertRelationSession(session);
    const raw: string = await getJson(API_BASE + '/x/relation?fid=' + mid.toString(), { 'Cookie': session.cookie });
    // 旧会话的-101不得登出已经切换的新会话。
    MemberService.assertRelationSession(session);
    const response = parseEnvelope<MemberRelation>(raw); ensureOk(response);
    if (response.data === undefined || response.data === null) { throw new Error('关系状态为空，请重试'); }
    return response.data;
  }

  static async modifyRelationForSession(mid: number, act: number, session: MemberRelationSession): Promise<void> {
    MemberService.assertRelationSession(session);
    const raw: string = await postForm(API_BASE + '/x/relation/modify', {
      'fid': mid.toString(), 'act': act.toString(), 're_src': '11', 'csrf': session.csrf
    }, session.cookie);
    MemberService.assertRelationSession(session);
    ensureOk(parseEnvelope<object>(raw));
    if (act === 1 || act === 2 || act === 5) { emitFollowChanged(mid, act === 1, session.revision); }
  }

  static async recent(mid: number, kind: string): Promise<MemberResult> {
    const data: ArchiveRaw[] = await read<ArchiveRaw[]>('/x/space/' + (kind === 'coin' ? 'coin' : 'like') + '/video',
      { 'vmid': mid.toString(), 'jsonp': 'jsonp' }, false, mid);
    return MemberService.archiveResult(data || [], 1, (data || []).length);
  }
  static async profile(mid: number): Promise<MemberProfile> {
    const card: CardData = await read<CardData>('/x/web-interface/card', { 'mid': mid.toString(), 'photo': 'true' });
    const c: CardRaw = card.card;
    const result: MemberProfile = { mid: mid, name: c.name, face: memberUrl(c.face), banner: memberUrl(card.space?.l_img || card.space?.s_img || ''), sign: c.sign || '',
      level: c.level_info?.current_level || 0, vip: c.vip?.vipStatus === 1 || c.vip?.status === 1,
      official: c.official_verify?.desc || c.Official?.title || '', followers: card.follower || c.fans || 0,
      following: c.friend || 0, likes: card.like_num || 0, videoCount: card.archive_count || 0 };
    // 基础资料独立可用，WBI补充头图/认证失败不清空已获得的资料。
    try {
      const info: ProfileRaw = await read<ProfileRaw>('/x/space/wbi/acc/info', {
        'mid': mid.toString(), 'platform': 'web', 'web_location': '1550101'
      }, true, mid);
      result.banner = memberUrl(info.top_photo || '') || result.banner; result.sign = info.sign || result.sign;
      result.level = info.level || result.level; result.official = info.official?.title || result.official;
    } catch (_) { /* API可能限制WBI资料；基础card不受影响。 */ }
    return result;
  }

  static async relation(mid: number): Promise<MemberRelation> {
    return read<MemberRelation>('/x/relation', { 'fid': mid.toString() });
  }
  static async modifyRelation(mid: number, act: number): Promise<void> {
    const session: MemberRelationSession = await MemberService.captureRelationSession();
    await MemberService.modifyRelationForSession(mid, act, session);
  }

  static async videos(mid: number, page: number, order: string, keyword: string = '',
    ascending: boolean = false): Promise<MemberResult> {
    const params: Record<string, string> = { 'mid': mid.toString(), 'pn': page.toString(), 'ps': '30',
      'tid': '0', 'order': order, 'keyword': keyword, 'platform': 'web', 'web_location': '333.1387',
      'order_avoided': 'true' };
    const data: ArchiveData = await read<ArchiveData>('/x/space/wbi/arc/search', params, true, mid);
    const list: ArchiveRaw[] = data.list?.vlist || [];
    const total: number = data.page?.count || 0;
    if (ascending) {
      // Web端无sort参数；按总页数反向取页，页内倒序，不能只反转当前页冒充全局倒序。
      const last: number = Math.max(1, Math.ceil(total / 30));
      const target: number = Math.max(1, last - page + 1);
      if (target !== page) {
        params['pn'] = target.toString();
        const reverse: ArchiveData = await read<ArchiveData>('/x/space/wbi/arc/search', params, true, mid);
        return MemberService.archiveResult((reverse.list?.vlist || []).slice().reverse(), page, total);
      }
      return MemberService.archiveResult(list.slice().reverse(), page, total);
    }
    return MemberService.archiveResult(list, page, total);
  }
  private static archiveResult(list: ArchiveRaw[], page: number, total: number): MemberResult {
    const entries: MemberEntry[] = list.filter((v: ArchiveRaw) => !!v.bvid).map((v: ArchiveRaw) => {
      const item: VideoItem = video(v); return { key: item.key, video: item } as MemberEntry;
    });
    return { items: entries, next: (page + 1).toString(), total: total, hasMore: page * 30 < total };
  }
  static async dynamics(mid: number, offset: string, keyword: string = '', page: number = 1): Promise<MemberResult> {
    const result = await DynamicService.space(mid, offset, keyword, page);
    return { items: result.items.map((d: DynItem): MemberEntry => ({ key: 'dyn_' + d.id, dynamic: d })),
      next: result.offset, hasMore: result.hasMore && result.offset !== offset, total: result.total === undefined ? -1 : result.total };
  }
  static async opus(mid: number, offset: string, page: number): Promise<MemberResult> {
    const data: OpusData = await read<OpusData>('/x/polymer/web-dynamic/v1/opus/feed/space', {
      'host_mid': mid.toString(), 'offset': offset, 'page': page.toString(), 'type': 'all', 'web_location': '333.1387'
    }, true, mid);
    const items: MemberEntry[] = (data.items || []).map((o: MemberOpus): MemberEntry => ({ key: 'opus_' + o.opus_id, opus: o }));
    return { items: items, next: data.offset || '', total: items.length,
      hasMore: data.has_more === true && !!data.offset && data.offset !== offset };
  }
  static async collections(mid: number, page: number): Promise<MemberResult> {
    const data: CollectionData = await read<CollectionData>('/x/polymer/web-space/seasons_series_list', {
      'mid': mid.toString(), 'page_num': page.toString(), 'page_size': '10'
    }, false, mid);
    const all: CollectionRaw[] = (data.items_lists?.seasons_list || []).concat(data.items_lists?.series_list || []);
    const items: MemberEntry[] = all.filter((c: CollectionRaw) => c.meta !== undefined).map((c: CollectionRaw): MemberEntry => {
      const m: CollectionMeta = c.meta as CollectionMeta;
      const kind: string = m.season_id ? 'season' : 'series'; const id: number = m.season_id || m.series_id || 0;
      return { key: kind + id.toString(), collection: { id: id, kind: kind, title: m.name || '',
        cover: memberUrl(m.cover || c.archives?.[0]?.pic || ''), count: m.total || 0, ptime: m.ptime || m.ctime || 0 } };
    });
    const total: number = data.items_lists?.page?.total || 0;
    return { items: items, next: (page + 1).toString(), total: total, hasMore: page * 10 < total };
  }
  static async collectionVideos(mid: number, id: number, kind: string, page: number,
    ascending: boolean): Promise<MemberResult> {
    const params: Record<string, string> = kind === 'season' ? {
      'mid': mid.toString(), 'season_id': id.toString(), 'page_num': page.toString(), 'page_size': '30',
      'sort_reverse': ascending ? 'true' : 'false'
    } : { 'mid': mid.toString(), 'series_id': id.toString(), 'pn': page.toString(), 'ps': '30',
      'sort': ascending ? 'asc' : 'desc' };
    const data: SeasonData = await read<SeasonData>(kind === 'season'
      ? '/x/polymer/web-space/seasons_archives_list' : '/x/series/archives', params, false, mid);
    return MemberService.archiveResult(data.archives || [], page, data.page?.total || data.meta?.total || 0);
  }
  static async folders(mid: number, page: number, collected: boolean): Promise<MemberFolderResult> {
    const data: FoldersData = await read<FoldersData>('/x/v3/fav/folder/' + (collected ? 'collected' : 'created') + '/list', {
      'up_mid': mid.toString(), 'pn': page.toString(), 'ps': '20', 'platform': 'web'
    }, false, mid);
    return { items: data.list || [], hasMore: data.has_more === true };
  }
}
