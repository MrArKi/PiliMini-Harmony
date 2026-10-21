/**
 * 视频接口服务（spec-04/05）：推荐流 / 热门 / 搜索 / 详情 / 评论
 */
import { getJson, postForm, buildQuery, parseEnvelope, ensureOk } from '../infra/http/http';
import { wbiSign } from '../infra/sign/wbi';
import { API_BASE } from '../config/constants';
import { AppError } from '../infra/error/app_error';
import { CookieStore } from '../infra/cookie/cookie_store';
import { VideoItem } from '../model/video_item';
import { VideoQuality } from '../model/video_quality';

interface OwnerInfo {
  mid?: number;
  name: string;
  face: string;
}

interface StatInfo {
  view: number;
  danmaku?: number;
  reply?: number;
}

interface RcmdItem {
  bvid?: string;
  aid?: number;
  id?: number;
  cid: number;
  goto?: string;
  title: string;
  pic: string;
  duration: number;
  pubdate?: number;
  owner: OwnerInfo;
  stat: StatInfo;
}

interface RcmdData {
  item: RcmdItem[];
  fresh_idx: number;
}

interface PopItem {
  bvid: string;
  aid?: number;
  cid: number;
  title: string;
  pic: string;
  duration: number;
  pubdate?: number;
  owner: OwnerInfo;
  stat: StatInfo;
}

interface PopData {
  list: PopItem[];
  no_more: boolean;
}

interface SearchItem {
  bvid: string;
  title: string;
  pic: string;
  author: string;
  play: number;
  danmaku?: number;
  pubdate?: number;
  duration: string;
}

interface SearchData {
  result?: SearchItem[];
  numPages: number;
  page: number;
}

// ===== 详情（view） =====

export interface VideoPageInfo {
  cid: number;
  page: number;
  part: string;
  duration: number;
  /** 分P 视频原始宽高（dimension；0 = 未知），用于竖屏视频判定（Nara isVertical 同构） */
  width: number;
  height: number;
  cover?: string;
  pubdate?: number;
}

/** UGC合集按接口原section顺序保留，下载seasonOrder仍使用全合集顺序。 */
export interface VideoEpisode {
  id: number;
  aid: number;
  bvid: string;
  cid: number;
  title: string;
  cover: string;
  duration: number;
  pubdate: number;
  viewCount: number;
  danmakuCount: number;
  pages: VideoPageInfo[];
}

export interface VideoSeasonSection { id: number; title: string; episodes: VideoEpisode[]; }
export interface VideoSeason { id: string; title: string; sections: VideoSeasonSection[]; }

export interface VideoDetail {
  aid: number;
  bvid: string;
  title: string;
  cover: string;
  desc: string;
  pubdate: number;
  duration: number;
  ownerName: string;
  ownerMid: number;
  ownerFace: string;
  viewCount: number;
  danmakuCount: number;
  replyCount: number;
  pages: VideoPageInfo[];
  seasonId?: string;
  seasonTitle?: string;
  seasonOrder?: number;
  season?: VideoSeason;
}

interface ViewDimensionRaw {
  width?: number;
  height?: number;
  rotate?: number;
}

interface ViewPageRaw {
  cid: number;
  page: number;
  part: string;
  duration: number;
  dimension?: ViewDimensionRaw;
  first_frame?: string;
  ctime?: number;
}

interface ViewDataRaw {
  aid: number;
  bvid: string;
  title: string;
  pic: string;
  desc: string;
  pubdate: number;
  duration: number;
  owner: OwnerInfo;
  stat: StatInfo;
  pages?: ViewPageRaw[];
  ugc_season?: ViewSeasonRaw;
}

interface ViewEpisodeArcRaw {
  pic?: string; title?: string; duration?: number; pubdate?: number;
  stat?: StatInfo;
}
interface ViewEpisodeRaw {
  id?: number; aid?: number; bvid?: string; cid?: number; title?: string;
  arc?: ViewEpisodeArcRaw; page?: ViewPageRaw; pages?: ViewPageRaw[];
}
interface ViewSectionRaw { id?: number; title?: string; episodes?: ViewEpisodeRaw[]; }
interface ViewSeasonRaw { id: number; title: string; sections?: ViewSectionRaw[]; }

// ===== 评论 =====

/**
 * 评论配图（pictures[]: img_src / img_width / img_height）
 */
export interface CommentPic {
  url: string;
  width: number;
  height: number;
}

/**
 * 评论条目（@Observed：支持 @ObjectLink 增量刷新，如楼中楼展开）
 */
@Observed
export class CommentItem {
  rpid: number = 0;
  mid: number = 0;
  uname: string = '';
  avatar: string = '';
  message: string = '';
  ctime: number = 0;
  like: number = 0;
  rcount: number = 0;
  isUpTop: boolean = false;
  pics: CommentPic[] = [];
  replies: CommentItem[] = [];
  expanded: boolean = false;
  // 楼中楼分页加载状态（主接口只返回前 2-3 条预览）
  subLoaded: boolean = false;
  subLoading: boolean = false;
  subHasMore: boolean = false;
  subPage: number = 0;
  subErr: boolean = false;
}

export interface SubReplyPage {
  items: CommentItem[];
  page: number;
  total: number;
  hasMore: boolean;
}

/** 按子回复直达的时间序窗口，前后游标不能与普通页码混用。 */
export interface SubReplyWindow {
  items: CommentItem[];
  total: number;
  prevOffset: string;
  nextOffset: string;
  hasPrevious: boolean;
  hasMore: boolean;
}

export interface ReplyPage {
  items: CommentItem[];
  topItems: CommentItem[];
  nextOffset: string;
  isEnd: boolean;
  total: number;
  sortName: string;
}

interface ReplyMemberRaw {
  mid: number;
  uname: string;
  avatar: string;
}

interface ReplyPictureRaw {
  img_src: string;
  img_width: number;
  img_height: number;
}

interface ReplyContentRaw {
  message: string;
  pictures?: ReplyPictureRaw[];
}

interface ReplyControlRaw {
  is_up_top?: number;
}

interface ReplyItemRaw {
  rpid: number;
  member: ReplyMemberRaw;
  content: ReplyContentRaw;
  ctime: number;
  like: number;
  rcount: number;
  reply_control?: ReplyControlRaw;
  replies?: ReplyItemRaw[];
}

interface ReplyCursorRaw {
  is_end: boolean;
  all_count: number;
  name?: string;
  mode?: number;
  pagination_reply?: Record<string, string>;
}

interface ReplyDataRaw {
  replies?: ReplyItemRaw[];
  top_replies?: ReplyItemRaw[];
  cursor?: ReplyCursorRaw;
  /** 老接口 /x/v2/reply 的分页信息（count = 总数） */
  page?: ReplyPageRaw;
}

interface ReplyPageRaw {
  num: number;
  size: number;
  count: number;
}

interface SubReplyData {
  replies?: ReplyItemRaw[];
  page?: ReplyPageRaw;
}

interface SubReplyWindowCursor {
  is_begin: boolean;
  is_end: boolean;
  pagination_reply?: Record<string, string>;
}

interface SubReplyWindowData {
  root?: ReplyItemRaw;
  cursor?: SubReplyWindowCursor;
}

export interface PageResult {
  items: VideoItem[];
  hasMore: boolean;
  nextCursor: number;
}

// ===== 相关推荐 / UP 关注（spec-05 V2） =====

interface RelatedItem {
  bvid?: string;
  cid: number;
  title: string;
  pic: string;
  duration: number;
  pubdate?: number;
  owner: OwnerInfo;
  stat: StatInfo;
}

interface RelData {
  attribute?: number;
}

// ===== 播放取流（spec-06a） =====

export interface PlayQuality {
  qn: number;
  label: string;
}

export interface PlayInfo {
  /** DASH 视频轨（无 dash 时 = durl 单流地址） */
  videoUrl: string;
  /** DASH 独立音频轨（durl 降级时为空串） */
  audioUrl: string;
  videoBackup: string[];
  audioBackup: string[];
  qualities: PlayQuality[];
  currentQn: number;
  durationMs: number;
  isDash: boolean;
}

interface DashSegRaw {
  id?: number;
  codecid?: number;
  codecs?: string;
  baseUrl?: string;
  base_url?: string;
  backupUrl?: string[];
  backup_url?: string[];
  width?: number;
  height?: number;
}

interface DashRaw {
  duration?: number;
  video?: DashSegRaw[];
  audio?: DashSegRaw[];
}

interface DurlSegRaw {
  order?: number;
  url?: string;
  backup_url?: string[];
  /** 文件字节数（下载完成判定用） */
  size?: number;
}

interface PlayDataRaw {
  quality?: number;
  timelength?: number;
  accept_quality?: number[];
  accept_description?: string[];
  dash?: DashRaw;
  durl?: DurlSegRaw[];
}

interface RelationStatData {
  follower: number;
}

function fixUrl(u: string): string {
  if (u.startsWith('//')) {
    return 'https:' + u;
  }
  if (u.startsWith('http://')) {
    return 'https://' + u.substring(7);
  }
  return u;
}

function stripTag(s: string): string {
  return s.replace(/<[^>]+>/g, '');
}

function stripAvatarSize(u: string): string {
  const at: number = u.indexOf('@');
  return at > 0 ? u.substring(0, at) : u;
}

function parseDurationStr(d: string): number {
  const parts: string[] = d.split(':');
  let sec: number = 0;
  for (let i = 0; i < parts.length; i++) {
    const v: number = parseInt(parts[i], 10);
    if (!isNaN(v)) {
      sec = sec * 60 + v;
    }
  }
  return sec;
}

function mapVideoPages(raw: ViewPageRaw[]): VideoPageInfo[] {
  return raw.filter((p: ViewPageRaw): boolean => Number.isSafeInteger(p.cid) && p.cid > 0)
    .map((p: ViewPageRaw, index: number): VideoPageInfo => ({
      cid: p.cid, page: p.page > 0 ? p.page : index + 1, part: p.part || '', duration: p.duration || 0,
      width: p.dimension?.width || 0, height: p.dimension?.height || 0,
      cover: p.first_frame ? fixUrl(p.first_frame) : '', pubdate: p.ctime || 0
    }));
}

function mapVideoSeason(raw: ViewSeasonRaw | undefined): VideoSeason | undefined {
  if (!raw || !Number.isSafeInteger(raw.id) || raw.id <= 0) { return undefined; }
  const sections: VideoSeasonSection[] = [];
  for (const section of raw.sections || []) {
    const episodes: VideoEpisode[] = [];
    for (const episode of section.episodes || []) {
      // 只展示可导航的真实BV，不把缺失bvid误当成当前视频。
      if (!episode.bvid || !/^BV[0-9A-Za-z]{10}$/.test(episode.bvid)) { continue; }
      const pages: VideoPageInfo[] = mapVideoPages(episode.pages || (episode.page ? [episode.page] : []));
      const cid: number = episode.cid || (pages.length > 0 ? pages[0].cid : 0);
      if (!Number.isSafeInteger(cid) || cid <= 0) { continue; }
      episodes.push({ id: episode.id || episode.aid || cid, aid: episode.aid || 0,
        bvid: episode.bvid, cid: cid, title: episode.title || episode.arc?.title || '',
        cover: episode.arc?.pic ? fixUrl(episode.arc.pic) : '',
        duration: episode.arc?.duration || 0, pubdate: episode.arc?.pubdate || 0,
        viewCount: episode.arc?.stat?.view || 0, danmakuCount: episode.arc?.stat?.danmaku || 0, pages: pages });
    }
    if (episodes.length > 0) {
      sections.push({ id: section.id || sections.length + 1, title: section.title || '选集', episodes: episodes });
    }
  }
  return sections.length > 0 ? { id: raw.id.toString(), title: raw.title || '', sections: sections } : undefined;
}

function mapComment(raw: ReplyItemRaw): CommentItem {
  const c: CommentItem = new CommentItem();
  c.rpid = raw.rpid;
  const memberOk: boolean = raw.member !== undefined && raw.member !== null;
  c.mid = memberOk ? raw.member.mid : 0;
  c.uname = memberOk ? raw.member.uname : '';
  c.avatar = memberOk ? fixUrl(stripAvatarSize(raw.member.avatar)) : '';
  const contentOk: boolean = raw.content !== undefined && raw.content !== null;
  c.message = contentOk ? raw.content.message : '';
  c.ctime = raw.ctime;
  c.like = raw.like;
  c.rcount = raw.rcount;
  // 置顶标记
  const ctrl: ReplyControlRaw | undefined = raw.reply_control;
  if (ctrl !== undefined && ctrl !== null && ctrl.is_up_top !== undefined && ctrl.is_up_top === 1) {
    c.isUpTop = true;
  }
  // 评论配图
  if (contentOk && raw.content.pictures !== undefined && raw.content.pictures !== null) {
    const ps: ReplyPictureRaw[] = raw.content.pictures;
    for (let i = 0; i < ps.length; i++) {
      c.pics.push({
        url: fixUrl(ps[i].img_src),
        width: ps[i].img_width,
        height: ps[i].img_height
      });
    }
  }
  const sub: ReplyItemRaw[] | undefined = raw.replies;
  if (sub !== undefined && sub !== null) {
    for (let i = 0; i < sub.length; i++) {
      c.replies.push(mapComment(sub[i]));
    }
  }
  return c;
}

export class VideoService {
  /** 相关推荐（详情页「简介」面板底部，对齐 Nara 实拍 39） */
  static async related(bvid: string): Promise<VideoItem[]> {
    const raw: string = await getJson(API_BASE + '/x/web-interface/archive/related?bvid=' + bvid);
    const resp = parseEnvelope<RelatedItem[]>(raw);
    ensureOk(resp);
    const data: RelatedItem[] | undefined = resp.data;
    if (data === undefined) {
      return [];
    }
    const out: VideoItem[] = [];
    for (let i = 0; i < data.length; i++) {
      const it: RelatedItem = data[i];
      const bv: string = it.bvid !== undefined ? it.bvid : '';
      if (bv.length === 0) {
        continue;
      }
      out.push({
        key: 'rel_' + bv + '_' + i.toString(),
        bvid: bv,
        cid: it.cid,
        title: stripTag(it.title),
        cover: fixUrl(it.pic),
        upName: it.owner.name,
        upFace: fixUrl(it.owner.face),
        playCount: it.stat.view,
        danmaku: it.stat.danmaku !== undefined ? it.stat.danmaku : 0,
        pubdate: it.pubdate !== undefined ? it.pubdate : 0,
        duration: it.duration
      });
    }
    return out;
  }

  /** UP 是否已关注（未登录/失败返回 false） */
  static async relationState(mid: number): Promise<boolean> {
    if (mid <= 0) {
      return false;
    }
    try {
      const raw: string = await getJson(API_BASE + '/x/relation?fid=' + mid.toString());
      const resp = parseEnvelope<RelData>(raw);
      ensureOk(resp);
      const d: RelData | undefined = resp.data;
      if (d === undefined || d.attribute === undefined) {
        return false;
      }
      return d.attribute === 1 || d.attribute === 2 || d.attribute === 6;
    } catch (e) {
      console.warn('[PiliMini-rel] exception=' + JSON.stringify(e));
      return false;
    }
  }

  /** 关注 / 取关 UP（写操作，需登录） */
  static async relationModify(mid: number, follow: boolean): Promise<void> {
    const token: string = await CookieStore.get('bili_jct');
    const raw: string = await postForm(API_BASE + '/x/relation/modify', {
      'fid': mid.toString(),
      'act': follow ? '1' : '2',
      're_src': '11',
      'csrf': token
    });
    const resp = parseEnvelope<object>(raw);
    ensureOk(resp);
  }

  /** 首页推荐流（wbi 签名） */
  static async rcmd(freshIdx: number, ps: number): Promise<PageResult> {
    const params: Record<string, string> = {
      'web_location': '1430650',
      'y_num': '5',
      'fresh_type': '4',
      'feed_version': 'V8',
      'fresh_idx_1h': '1',
      'fetch_row': '1',
      'fresh_idx': freshIdx.toString(),
      'brush': '0',
      'homepage_ver': '1',
      'ps': ps.toString(),
      'last_y_num': '5',
      'screen': '1920-1080'
    };
    const signed: Record<string, string> = await wbiSign(params);
    const raw: string = await getJson(API_BASE + '/x/web-interface/wbi/index/top/feed/rcmd?' + buildQuery(signed));
    const resp = parseEnvelope<RcmdData>(raw);
    ensureOk(resp);
    const data: RcmdData | undefined = resp.data;
    if (data === undefined) {
      throw new AppError('parse', -1, '推荐数据为空');
    }
    const items: VideoItem[] = [];
    for (let i = 0; i < data.item.length; i++) {
      const it: RcmdItem = data.item[i];
      if (it.goto !== 'av') {
        continue;
      }
      const bvid: string = it.bvid !== undefined ? it.bvid : '';
      if (bvid.length === 0) {
        continue;
      }
      items.push({
        key: bvid + '_p' + freshIdx.toString() + '_' + i.toString(),
        bvid: bvid,
        cid: it.cid,
        title: stripTag(it.title),
        cover: fixUrl(it.pic),
        upName: it.owner.name,
        upMid: it.owner.mid !== undefined ? it.owner.mid : 0,
        upFace: fixUrl(it.owner.face),
        playCount: it.stat.view,
        danmaku: it.stat.danmaku !== undefined ? it.stat.danmaku : 0,
        pubdate: it.pubdate !== undefined ? it.pubdate : 0,
        duration: it.duration,
        aid: it.aid !== undefined ? it.aid : (it.id !== undefined ? it.id : 0)
      });
    }
    return { items: items, hasMore: true, nextCursor: data.fresh_idx > 0 ? data.fresh_idx : freshIdx + 1 };
  }

  /** 热门列表（无需签名） */
  static async hot(pn: number, ps: number): Promise<PageResult> {
    const raw: string = await getJson(API_BASE + '/x/web-interface/popular?pn=' + pn.toString() + '&ps=' + ps.toString());
    const resp = parseEnvelope<PopData>(raw);
    ensureOk(resp);
    const data: PopData | undefined = resp.data;
    if (data === undefined) {
      throw new AppError('parse', -1, '热门数据为空');
    }
    const items: VideoItem[] = [];
    for (let i = 0; i < data.list.length; i++) {
      const it: PopItem = data.list[i];
      items.push({
        key: it.bvid + '_hp' + pn.toString() + '_' + i.toString(),
        bvid: it.bvid,
        cid: it.cid,
        title: stripTag(it.title),
        cover: fixUrl(it.pic),
        upName: it.owner.name,
        upMid: it.owner.mid !== undefined ? it.owner.mid : 0,
        upFace: fixUrl(it.owner.face),
        playCount: it.stat.view,
        danmaku: it.stat.danmaku !== undefined ? it.stat.danmaku : 0,
        pubdate: it.pubdate !== undefined ? it.pubdate : 0,
        duration: it.duration,
        aid: it.aid !== undefined ? it.aid : 0
      });
    }
    return { items: items, hasMore: !data.no_more, nextCursor: pn + 1 };
  }

  /** 搜索（wbi 签名） */
  static async search(keyword: string, page: number): Promise<PageResult> {
    const params: Record<string, string> = {
      'search_type': 'video',
      'keyword': keyword,
      'page': page.toString(),
      'page_size': '20',
      'web_location': '1430650'
    };
    const signed: Record<string, string> = await wbiSign(params);
    const raw: string = await getJson(API_BASE + '/x/web-interface/wbi/search/type?' + buildQuery(signed));
    const resp = parseEnvelope<SearchData>(raw);
    ensureOk(resp);
    const data: SearchData | undefined = resp.data;
    if (data === undefined) {
      return { items: [], hasMore: false, nextCursor: page };
    }
    const items: VideoItem[] = [];
    const list: SearchItem[] | undefined = data.result;
    if (list !== undefined) {
      for (let i = 0; i < list.length; i++) {
        const it: SearchItem = list[i];
        if (it.bvid === undefined || it.bvid.length === 0) {
          continue;
        }
        items.push({
          key: it.bvid + '_s' + page.toString() + '_' + i.toString(),
          bvid: it.bvid,
          cid: 0,
          title: stripTag(it.title),
          cover: fixUrl(it.pic),
          upName: it.author,
          upFace: '',
          playCount: it.play,
          danmaku: it.danmaku !== undefined ? it.danmaku : 0,
          pubdate: it.pubdate !== undefined ? it.pubdate : 0,
          duration: parseDurationStr(it.duration)
        });
      }
    }
    return { items: items, hasMore: data.page < data.numPages, nextCursor: page + 1 };
  }

  /** 视频详情（view，无需签名） */
  static async viewDetail(bvid: string): Promise<VideoDetail> {
    const raw: string = await getJson(API_BASE + '/x/web-interface/view?bvid=' + bvid);
    const resp = parseEnvelope<ViewDataRaw>(raw);
    ensureOk(resp);
    const d: ViewDataRaw | undefined = resp.data;
    if (d === undefined) {
      throw new AppError('parse', -1, '详情数据为空');
    }
    const pages: VideoPageInfo[] = mapVideoPages(d.pages || []);
    let seasonOrder: number = 0;
    let order: number = 0;
    for (const section of d.ugc_season?.sections || []) {
      for (const episode of section.episodes || []) {
        order++;
        if (episode.bvid === d.bvid || episode.aid === d.aid) { seasonOrder = order; }
      }
    }
    return {
      aid: d.aid,
      bvid: d.bvid,
      title: d.title,
      cover: fixUrl(d.pic),
      desc: d.desc,
      pubdate: d.pubdate,
      duration: d.duration,
      ownerName: d.owner.name,
      ownerMid: d.owner.mid !== undefined ? d.owner.mid : 0,
      ownerFace: fixUrl(stripAvatarSize(d.owner.face)),
      viewCount: d.stat.view,
      danmakuCount: d.stat.danmaku !== undefined ? d.stat.danmaku : 0,
      replyCount: d.stat.reply !== undefined ? d.stat.reply : 0,
      pages: pages,
      seasonId: d.ugc_season ? d.ugc_season.id.toString() : '',
      seasonTitle: d.ugc_season?.title || '', seasonOrder: seasonOrder,
      season: mapVideoSeason(d.ugc_season)
    };
  }

  /** 评论列表（wbi 签名，只读）；mode 3=按热度 2=按时间 */
  static async reply(aid: number, offset: string, mode: number): Promise<ReplyPage> {
    const paginationStr: string = '{"offset":"' + offset + '"}';
    const params: Record<string, string> = {
      'oid': aid.toString(),
      'type': '1',
      'mode': mode.toString(),
      'pagination_str': paginationStr,
      'plat': '1',
      'web_location': '1315875'
    };
    const signed: Record<string, string> = await wbiSign(params);
    const raw: string = await getJson(API_BASE + '/x/v2/reply/wbi/main?' + buildQuery(signed));
    const resp = parseEnvelope<ReplyDataRaw>(raw);
    ensureOk(resp);
    const data: ReplyDataRaw | undefined = resp.data;
    if (data === undefined || data === null) {
      return { items: [], topItems: [], nextOffset: offset, isEnd: true, total: 0, sortName: '' };
    }
    const items: CommentItem[] = [];
    const list: ReplyItemRaw[] | undefined = data.replies;
    if (list !== undefined && list !== null) {
      for (let i = 0; i < list.length; i++) {
        items.push(mapComment(list[i]));
      }
    }
    // 置顶评论（top_replies）
    const topItems: CommentItem[] = [];
    const tops: ReplyItemRaw[] | undefined = data.top_replies;
    if (tops !== undefined && tops !== null) {
      for (let i = 0; i < tops.length; i++) {
        const t: CommentItem = mapComment(tops[i]);
        t.isUpTop = true;
        topItems.push(t);
      }
    }
    let nextOffset: string = '';
    let isEnd: boolean = true;
    let total: number = 0;
    let sortName: string = '';
    const cursor: ReplyCursorRaw | undefined = data.cursor;
    if (cursor !== undefined && cursor !== null) {
      isEnd = cursor.is_end === true;
      total = typeof cursor.all_count === 'number' ? cursor.all_count : 0;
      if (cursor.name !== undefined && cursor.name !== null) {
        sortName = cursor.name;
      }
      const pr: Record<string, string> | undefined = cursor.pagination_reply;
      if (pr !== undefined && pr !== null) {
        const no: string | undefined = pr.next_offset;
        if (no !== undefined && no !== null) {
          nextOffset = no;
        }
      }
    }
    return { items: items, topItems: topItems, nextOffset: nextOffset, isEnd: isEnd, total: total, sortName: sortName };
  }

  /**
   * 动态评论列表（type=17，oid=动态 id；mode 3=按热度 2=按时间）
   * 与视频评论同构，仅 oid/type 不同
   */
  static async dynReply(oid: string, commentType: number, offset: string, mode: number): Promise<ReplyPage> {
    if (offset.startsWith('legacy:')) {
      return VideoService.dynReplyLegacy(oid, commentType, Math.max(1, parseInt(offset.substring(7), 10) || 1), mode);
    }
    const paginationStr: string = '{"offset":"' + offset + '"}';
    const params: Record<string, string> = {
      'oid': oid,
      'type': commentType.toString(),
      'mode': mode.toString(),
      'pagination_str': paginationStr,
      'plat': '1',
      'web_location': '1315875'
    };
    const signed: Record<string, string> = await wbiSign(params);
    const raw: string = await getJson(API_BASE + '/x/v2/reply/wbi/main?' + buildQuery(signed));
    const resp = parseEnvelope<ReplyDataRaw>(raw);
    // 回退：老接口 /x/v2/reply（非 wbi）——仅非鉴权错误时回退（-101 已触发全局登出）
    if (resp.code !== 0 && resp.code !== -101) {
      return VideoService.dynReplyLegacy(oid, commentType, 1, mode);
    }

    // 走到这里 code 仍非 0 → 必为 -101（非鉴权错误已在上方回退处理）
    ensureOk(resp);
    const data: ReplyDataRaw | undefined = resp.data;
    if (data === undefined || data === null) {
      return { items: [], topItems: [], nextOffset: offset, isEnd: true, total: 0, sortName: '' };
    }
    const items: CommentItem[] = [];
    const list: ReplyItemRaw[] | undefined = data.replies;
    if (list !== undefined && list !== null) {
      for (let i = 0; i < list.length; i++) {
        items.push(mapComment(list[i]));
      }
    }
    const topItems: CommentItem[] = [];
    const tops: ReplyItemRaw[] | undefined = data.top_replies;
    if (tops !== undefined && tops !== null) {
      for (let i = 0; i < tops.length; i++) {
        const t: CommentItem = mapComment(tops[i]);
        t.isUpTop = true;
        topItems.push(t);
      }
    }
    let nextOffset: string = '';
    let isEnd: boolean = true;
    let total: number = 0;
    let sortName: string = '';
    const cursor: ReplyCursorRaw | undefined = data.cursor;
    if (cursor !== undefined && cursor !== null) {
      isEnd = cursor.is_end === true;
      total = typeof cursor.all_count === 'number' ? cursor.all_count : 0;
      if (cursor.name !== undefined && cursor.name !== null) {
        sortName = cursor.name;
      }
      const pr: Record<string, string> | undefined = cursor.pagination_reply;
      if (pr !== undefined && pr !== null) {
        const no: string | undefined = pr.next_offset;
        if (no !== undefined && no !== null) {
          nextOffset = no;
        }
      }
    }
    return { items: items, topItems: topItems, nextOffset: nextOffset, isEnd: isEnd, total: total, sortName: sortName };
  }

  private static async dynReplyLegacy(oid: string, type: number, page: number, mode: number): Promise<ReplyPage> {
    const raw: string = await getJson(API_BASE + '/x/v2/reply?type=' + type.toString() +
      '&oid=' + oid + '&pn=' + page.toString() + '&ps=20&sort=' + (mode === 3 ? '1' : '0'));
    const resp = parseEnvelope<ReplyDataRaw>(raw);
    ensureOk(resp);
    const data: ReplyDataRaw | undefined = resp.data;
    const items: CommentItem[] = [];
    if (data !== undefined && data !== null && data.replies !== undefined && data.replies !== null) {
      for (let i: number = 0; i < data.replies.length; i++) { items.push(mapComment(data.replies[i])); }
    }
    const total: number = data !== undefined && data !== null && data.page !== undefined && data.page !== null ? data.page.count : 0;
    return {
      items: items, topItems: [], nextOffset: 'legacy:' + (page + 1).toString(),
      isEnd: items.length === 0 || page * 20 >= total, total: total,
      sortName: mode === 3 ? '热门评论' : '最新评论'
    };
  }

  /** 动态楼中楼子评论（otype = basic.comment_type） */
  static async dynSubReplies(oid: string, commentType: number, rootRpid: number, page: number): Promise<SubReplyPage> {
    const url: string = API_BASE + '/x/v2/reply/reply?oid=' + oid +
      '&type=' + commentType.toString() + '&root=' + rootRpid.toString() +
      '&ps=20&pn=' + page.toString() + '&web_location=333.788';
    const raw: string = await getJson(url);
    const resp = parseEnvelope<SubReplyData>(raw);
    ensureOk(resp);
    const items: CommentItem[] = [];
    let total: number = 0;
    const data: SubReplyData | undefined = resp.data;
    if (data !== undefined && data !== null) {
      const list: ReplyItemRaw[] | undefined = data.replies;
      if (list !== undefined && list !== null) {
        for (let i = 0; i < list.length; i++) {
          items.push(mapComment(list[i]));
        }
      }
      const pg: ReplyPageRaw | undefined = data.page;
      if (pg !== undefined && pg !== null) {
        total = pg.count;
      }
    }
    const loaded: number = page * 20;
    return { items: items, page: page, total: total, hasMore: loaded < total && items.length > 0 };
  }

  /** UP 主粉丝数（relation/stat） */
  static async fans(mid: number): Promise<number> {    if (mid <= 0) {
      return 0;
    }
    try {
      const raw: string = await getJson(API_BASE + '/x/relation/stat?vmid=' + mid.toString());
      const resp = parseEnvelope<RelationStatData>(raw);
      if (resp.code === -101) { ensureOk(resp); }
      if (resp.code !== 0 || resp.data === undefined || resp.data === null) {
        return 0;
      }
      return resp.data.follower;
    } catch (e) {
      return 0;
    }
  }

  /** 目标附近的楼中楼窗口，后续请求仅带前/后游标，不重复携带目标。 */
  static async subReplyWindow(oid: string, commentType: number, rootRpid: number,
    targetRpid: number = 0, offset: string = ''): Promise<SubReplyWindow> {
    const params: Record<string, string> = {
      'oid': oid, 'type': commentType.toString(), 'root': rootRpid.toString(), 'mode': '2', 'ps': '20'
    };
    if (targetRpid > 0) {
      params['rpid'] = targetRpid.toString();
    } else if (offset.length > 0) {
      const pagination: Record<string, string> = { 'offset': offset };
      params['pagination_str'] = JSON.stringify(pagination);
    }
    const raw: string = await getJson(API_BASE + '/x/v2/reply/detail?' + buildQuery(params));
    const resp = parseEnvelope<SubReplyWindowData>(raw);
    ensureOk(resp);
    const data: SubReplyWindowData | undefined = resp.data;
    if (data === undefined || data === null || data.root === undefined || data.root === null
      || data.root.rpid !== rootRpid || data.cursor === undefined || data.cursor === null) {
      throw new AppError('parse', -1, '评论详情数据不完整');
    }
    const root: CommentItem = mapComment(data.root);
    const cursor: SubReplyWindowCursor = data.cursor;
    const offsets: Record<string, string> | undefined = cursor.pagination_reply;
    const prev: string = offsets !== undefined && offsets !== null ? (offsets['prev_offset'] || '') : '';
    const next: string = offsets !== undefined && offsets !== null ? (offsets['next_offset'] || '') : '';
    return { items: root.replies, total: root.rcount, prevOffset: prev, nextOffset: next,
      hasPrevious: !cursor.is_begin && prev.length > 0, hasMore: !cursor.is_end && next.length > 0 };
  }

  /** 普通楼中楼分页，无需签名；ps=20/页。 */
  static async subReplies(aid: number, rootRpid: number, page: number): Promise<SubReplyPage> {
    const url: string = API_BASE + '/x/v2/reply/reply?oid=' + aid.toString() +
      '&type=1&root=' + rootRpid.toString() +
      '&ps=20&pn=' + page.toString() + '&web_location=333.788';
    const raw: string = await getJson(url);
    const resp = parseEnvelope<SubReplyData>(raw);
    ensureOk(resp);
    const items: CommentItem[] = [];
    let total: number = 0;
    const data: SubReplyData | undefined = resp.data;
    if (data !== undefined && data !== null) {
      const list: ReplyItemRaw[] | undefined = data.replies;
      if (list !== undefined && list !== null) {
        for (let i = 0; i < list.length; i++) {
          items.push(mapComment(list[i]));
        }
      }
      const pg: ReplyPageRaw | undefined = data.page;
      if (pg !== undefined && pg !== null) {
        total = pg.count;
      }
    }
    const loaded: number = page * 20;
    return { items: items, page: page, total: total, hasMore: loaded < total && items.length > 0 };
  }

  /**
   * 播放取流（spec-06a；ADR-001）
   * 1) 优先 DASH（fnval=16，可拿独立音轨，供 spec-06b 自动切音频）
   * 2) 域名命中 PCDN 黑名单 → 用 durl(platform=html5，常规 CDN) 降级
   */
  static async playUrl(bvid: string, cid: number, qn: number, tryLook: boolean = false): Promise<PlayInfo> {
    const params: Record<string, string> = {
      'bvid': bvid,
      'cid': cid.toString(),
      'qn': qn.toString(),
      'fnval': '16',
      'fnver': '0',
      'fourk': '1'
    };
    if (tryLook) {
      // 免登录1080P（Nara 同款 try_look 参数：未登录 + 设置开启时附加）
      params['try_look'] = '1';
    }
    const signed: Record<string, string> = await wbiSign(params);
    const raw: string = await getJson(API_BASE + '/x/player/wbi/playurl?' + buildQuery(signed));
    const resp = parseEnvelope<PlayDataRaw>(raw);
    ensureOk(resp);
    const d: PlayDataRaw | undefined = resp.data;
    if (d === undefined || d === null) {
      throw new AppError('parse', -1, '取流数据为空');
    }

    const qualities: PlayQuality[] = [];
    const aq: number[] | undefined = d.accept_quality;
    const ad: string[] | undefined = d.accept_description;
    if (aq !== undefined && aq !== null) {
      for (let i = 0; i < aq.length; i++) {
        // accept_description 缺失时用 Nara 同款 qn→描述表兜底（Bug1：原显示裸 "qn80"）
        const label: string = (ad !== undefined && ad !== null && ad.length > i) ? ad[i] : VideoQuality.label(aq[i]);
        qualities.push({ qn: aq[i], label: label });
      }
    }

    const dash: DashRaw | undefined = d.dash;
    if (dash !== undefined && dash !== null && dash.video !== undefined && dash.video !== null
      && dash.video.length > 0) {
      const vList: DashSegRaw[] = dash.video;
      // 同档位可能先返回H.265；优先兼容性更广的H.264，不改变用户清晰度。
      let pickIdx: number = 0;
      for (let i = 0; i < vList.length; i++) {
        if (vList[i].id === qn) {
          pickIdx = i;
          break;
        }
      }
      const selectedQn: number | undefined = vList[pickIdx].id;
      for (let i = 0; i < vList.length; i++) {
        if (vList[i].id === selectedQn &&
          (vList[i].codecid === 7 || (vList[i].codecs || '').toLowerCase().startsWith('avc'))) {
          pickIdx = i;
          break;
        }
      }
      const v: DashSegRaw = vList[pickIdx];
      // 实际清晰度 = 所选流 id（请求档位不可得时 API 降级，video[0] 即最高可用档）
      const actualQn: number = v.id !== undefined ? v.id : (d.quality !== undefined ? d.quality : qn);
      const vUrls: string[] = conventionalUrls(dashUrl(v), v.backupUrl || v.backup_url || []);
      const vUrl: string = vUrls.length > 0 ? vUrls[0] : '';
      if (!isPcdn(vUrl)) {
        let aUrl: string = '';
        const aBackup: string[] = [];
        const aList: DashSegRaw[] | undefined = dash.audio;
        if (aList !== undefined && aList !== null && aList.length > 0) {
          const aUrls: string[] = conventionalUrls(dashUrl(aList[0]), aList[0].backupUrl || aList[0].backup_url || []);
          if (aUrls.length === 0) { return VideoService.requireDurl(bvid, cid, qn, qualities, tryLook); }
          aUrl = aUrls[0];
          const ab: string[] | undefined = aList[0].backupUrl !== undefined && aList[0].backupUrl !== null
            ? aList[0].backupUrl : aList[0].backup_url;
          if (ab !== undefined && ab !== null) {
            for (let i = 0; i < ab.length; i++) {
              const backup: string = fixUrl(ab[i]);
              if (!isPcdn(backup) && backup !== aUrl) { aBackup.push(backup); }
            }
          }
        }
        const vb: string[] | undefined = v.backupUrl !== undefined && v.backupUrl !== null
          ? v.backupUrl : v.backup_url;
        const vBackup: string[] = [];
        if (vb !== undefined && vb !== null) {
          for (let i = 0; i < vb.length; i++) {
            const backup: string = fixUrl(vb[i]);
            if (!isPcdn(backup) && backup !== vUrl) { vBackup.push(backup); }
          }
        }
        return {
          videoUrl: vUrl,
          audioUrl: aUrl,
          videoBackup: vBackup,
          audioBackup: aBackup,
          qualities: qualities,
          currentQn: actualQn,
          durationMs: dash.duration !== undefined ? dash.duration * 1000 : 0,
          isDash: true
        };
      }
    }

    // 降级：durl（第二次请求 platform=html5 拿常规 CDN；ADR-001 事实 2）
    const durlInfo: PlayInfo | null = await VideoService.playUrlDurl(bvid, cid, qn, qualities, tryLook);
    if (durlInfo !== null) {
      return durlInfo;
    }
    // 兜底：本次响应里若带了 durl 也可用
    const durl: DurlSegRaw[] | undefined = d.durl;
    if (durl !== undefined && durl !== null && durl.length > 0 && durl[0].url !== undefined) {
      return buildDurlInfo(durl, qualities, d.timelength, d.quality !== undefined ? d.quality : qn);
    }
    throw new AppError('parse', -1, '无可播放地址（PCDN 域名 + 无 durl 降级）');
  }

  private static async requireDurl(bvid: string, cid: number, qn: number, qualities: PlayQuality[],
    tryLook: boolean): Promise<PlayInfo> {
    const info: PlayInfo | null = await VideoService.playUrlDurl(bvid, cid, qn, qualities, tryLook);
    if (info === null) { throw new AppError('parse', -1, '没有可播放的常规CDN地址'); }
    return info;
  }

  /** 降级取流：platform=html5（常规 CDN，无独立音轨） */
  static async playUrlDurl(bvid: string, cid: number, qn: number, qualities: PlayQuality[],
    tryLook: boolean = false): Promise<PlayInfo | null> {
    try {
      const url: string = API_BASE + '/x/player/playurl?bvid=' + bvid + '&cid=' + cid.toString() +
        '&qn=' + qn.toString() + '&platform=html5&high_quality=1&otype=json'
        + (tryLook ? '&try_look=1' : '');
      const raw: string = await getJson(url);
      const resp = parseEnvelope<PlayDataRaw>(raw);
      if (resp.code === -101) { ensureOk(resp); }
      if (resp.code !== 0 || resp.data === undefined || resp.data === null) {
        return null;
      }
      const durl: DurlSegRaw[] | undefined = resp.data.durl;
      if (durl === undefined || durl === null || durl.length === 0 || durl[0].url === undefined) {
        return null;
      }
      return buildDurlInfo(durl, qualities, resp.data.timelength,
        resp.data.quality !== undefined ? resp.data.quality : qn);
    } catch (e) {
      return null;
    }
  }

  /** 下载用：直接取 durl 单流（带音轨 mp4，避免 DASH 音视频分离合并）。返回地址 + 备用 + 时长 */
  static async durlForDownload(bvid: string, cid: number, qn: number): Promise<DownloadUrl> {
    const url: string = API_BASE + '/x/player/playurl?bvid=' + bvid + '&cid=' + cid.toString() +
      '&qn=' + qn.toString() + '&platform=html5&high_quality=1&otype=json';
    const raw: string = await getJson(url);
    const resp = parseEnvelope<PlayDataRaw>(raw);
    ensureOk(resp);
    if (resp.code !== 0 || resp.data === undefined || resp.data === null) {
      throw new AppError('biz', resp.code, resp.message);
    }
    const durl: DurlSegRaw[] | undefined = resp.data.durl;
    if (durl === undefined || durl === null || durl.length === 0 || durl[0].url === undefined) {
      throw new AppError('parse', -1, '无 durl 下载源（可能需登录/大会员）');
    }
    if (durl.length !== 1) { throw new AppError('parse', -1, '该下载源包含多个媒体段，暂不支持缓存'); }
    const backup: string[] = [];
    const bu: string[] | undefined = durl[0].backup_url;
    if (bu !== undefined && bu !== null) {
      for (let i = 0; i < bu.length; i++) {
        backup.push(fixUrl(bu[i]));
      }
    }
    // 命中 PCDN 域名则用备用/重试常规源
    let main: string = fixUrl(durl[0].url as string);
    if (isPcdn(main) && backup.length > 0) {
      main = backup[0];
    }
    return {
      url: main,
      backup: backup,
      quality: resp.data.quality || qn,
      durationMs: resp.data.timelength !== undefined ? resp.data.timelength : 0,
      size: durl[0].size !== undefined ? durl[0].size : 0
    };
  }
}

/** 下载源（spec-09） */
export interface DownloadUrl {
  url: string;
  backup: string[];
  quality: number;
  durationMs: number;
  /** 文件字节数（0 表示未知） */
  size: number;
}

/** durl 段 → PlayInfo（单流，无独立音轨） */
function buildDurlInfo(durl: DurlSegRaw[], qualities: PlayQuality[], timelength: number | undefined,
  qn: number): PlayInfo {
  const backup: string[] = [];
  const bu: string[] | undefined = durl[0].backup_url;
  if (bu !== undefined && bu !== null) {
    for (let i = 0; i < bu.length; i++) {
      backup.push(fixUrl(bu[i]));
    }
  }
  return {
    videoUrl: fixUrl(durl[0].url as string),
    audioUrl: '',
    videoBackup: backup,
    audioBackup: [],
    qualities: qualities,
    currentQn: qn,
    durationMs: timelength !== undefined ? timelength : 0,
    isDash: false
  };
}

/** dash 段地址（baseUrl / base_url 双拼） */
function dashUrl(seg: DashSegRaw): string {
  const u: string | undefined = seg.baseUrl !== undefined && seg.baseUrl !== null ? seg.baseUrl : seg.base_url;
  return u !== undefined && u !== null ? fixUrl(u) : '';
}

/** PCDN 域名判定（ADR-001 事实 2） */
function isPcdn(u: string): boolean {
  if (u.length === 0) {
    return true;
  }
  const lower: string = u.toLowerCase();
  return lower.includes('mcdn') || lower.includes('mountaintoys') || lower.indexOf('szbdyd') >= 0;
}

/** 主地址与备用地址一起过滤，视频和音频遵守同一 CDN 选择规则。 */
function conventionalUrls(main: string, backup: string[]): string[] {
  const all: string[] = [main].concat(backup);
  const result: string[] = [];
  for (let i: number = 0; i < all.length; i++) {
    const url: string = fixUrl(all[i]);
    if (!isPcdn(url) && result.indexOf(url) < 0) { result.push(url); }
  }
  return result;
}
