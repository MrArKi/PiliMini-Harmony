/**
 * 动态服务（spec-08）：关注动态流（wbi 签名 + 登录态；REST 降级方案）
 */
import { getJson, buildQuery, parseEnvelope, ensureOk } from '../infra/http/http';
import { wbiSign } from '../infra/sign/wbi';
import { API_BASE } from '../config/constants';
import { AppError } from '../infra/error/app_error';

// ===== 映射后的模型 =====

export interface DynAuthor {
  mid: number;
  name: string;
  face: string;
  pubTs: number;
  pubText: string;
}

export interface DynArchive {
  bvid: string;
  title: string;
  cover: string;
  durationText: string;
  play: number;
  danmaku: number;
}

export interface DynPic {
  src: string;
  width: number;
  height: number;
}

export interface DynItem {
  id: string;
  /** av(视频/合集) | draw(图文) | forward(转发) | text(纯文本) | unsupported(占位) */
  kind: string;
  author: DynAuthor;
  text: string;
  archive?: DynArchive;
  pics?: DynPic[];
  orig?: DynItem;
  interactText: string;
  forwardCount: number;
  commentCount: number;
  likeCount: number;
  /** 评论接口参数（basic.comment_id_str / comment_type；缺省 = 动态 id + 17） */
  commentId: string;
  commentType: number;
  /** 充电专属（内容不下发，卡片显示占位） */
  onlyFans: boolean;
  pinned?: string;
  opusId?: string;
  paragraphs?: DynParagraph[];
}

export interface DynTextNode {
  text: string; link: string; mid: number; bold: boolean; italic: boolean; strike: boolean; size: number;
}
export interface DynParagraph { text: DynTextNode[]; pics: DynPic[]; heading: boolean; divider?: boolean; quote?: boolean; card?: DynLinkCard; }
export interface DynLinkCard { title: string; cover: string; link: string; }
interface OpusStyle { bold?: boolean; italic?: boolean; strikethrough?: boolean; }
interface OpusWord { words?: string; font_size?: number; style?: OpusStyle; }
interface OpusRich { text?: string; orig_text?: string; jump_url?: string; rid?: string; type?: string; style?: OpusStyle; }
interface OpusNode { word?: OpusWord; rich?: OpusRich; formula?: OpusFormula; }
interface OpusFormula { latex_content?: string; }
interface OpusText { nodes?: OpusNode[]; }
interface OpusPictures { pics?: RawOpusPic[]; }
interface OpusCode { content?: string; }
interface OpusListItem { nodes?: OpusNode[]; level?: number; order?: number; }
interface OpusList { items?: OpusListItem[]; style?: number; }
interface OpusCardContent { title?: string; cover?: string; jump_url?: string; }
interface OpusCard { ugc?: OpusCardContent; common?: OpusCardContent; opus?: OpusCardContent; }
interface OpusLink { card?: OpusCard; }
interface OpusLine { pic?: RawOpusPic; }
interface OpusParagraph {
  text?: OpusText; heading?: OpusText; pic?: OpusPictures; code?: OpusCode;
  list?: OpusList; link_card?: OpusLink; line?: OpusLine; blockquote?: OpusText;
}
interface OpusContent { paragraphs?: OpusParagraph[]; }
interface OpusAlbum { pics?: RawOpusPic[]; }
interface OpusDisplay { album?: OpusAlbum; }
interface OpusTop { display?: OpusDisplay; }
interface OpusTitle { text?: string; }
interface OpusModule {
  module_author?: RawAuthor; module_stat?: RawStat; module_content?: OpusContent;
  module_top?: OpusTop; module_title?: OpusTitle;
}
interface OpusItem { id_str: string; basic?: RawBasic; modules?: OpusModule[]; }
interface OpusDetail { item?: OpusItem; }
interface DynamicDetail { item?: RawDynItem; }
interface ModuleTag { text?: string; }

export interface DynPageResult {
  items: DynItem[];
  offset: string;
  hasMore: boolean;
  total?: number;
  /** 服务端已读基线；只在当前可见首页成功展示后推进。 */
  updateBaseline?: string;
}

// ===== 原始响应类型 =====

interface RawRichNode {
  type: string;
  orig_text: string;
  rid?: number;
}

interface RawDesc {
  text: string;
  rich_text_nodes?: RawRichNode[];
}

interface RawAuthor {
  mid: number;
  name: string;
  face: string;
  pub_ts: number;
  pub_time: string;
}

interface RawStatItem {
  count: number;
}

interface RawStat {
  forward?: RawStatItem;
  comment?: RawStatItem;
  like?: RawStatItem;
}

interface RawArchiveStat {
  play: number;
  danmaku: number;
}

interface RawDrawPic {
  src: string;
  width: number;
  height: number;
}

interface RawOpusPic {
  url: string;
  width: number;
  height: number;
}

interface RawMajorArchive {
  bvid: string;
  title: string;
  cover: string;
  duration_text: string;
  stat?: RawArchiveStat;
}

interface RawMajorDraw {
  items?: RawDrawPic[];
}

interface RawOpusSummary {
  text?: string;
}

interface RawMajorOpus {
  title?: string;
  summary?: RawOpusSummary;
  pics?: RawOpusPic[];
}

interface RawMajor {
  type: string;
  archive?: RawMajorArchive;
  ugc_season?: RawMajorArchive;
  draw?: RawMajorDraw;
  opus?: RawMajorOpus;
}

interface RawModuleDynamic {
  desc?: RawDesc;
  major?: RawMajor;
}

interface RawInteractItem {
  type: number;
  desc?: RawDesc;
}

interface RawModuleInteraction {
  items?: RawInteractItem[];
}

interface RawModules {
  module_author?: RawAuthor;
  module_dynamic?: RawModuleDynamic;
  module_stat?: RawStat;
  module_interaction?: RawModuleInteraction;
  module_tag?: ModuleTag;
}

interface RawBasic {
  is_only_fans?: boolean;
  /** 评论目标（动态 id / 视频 aid 等）与类型（1=视频 17=动态） */
  comment_id_str?: string;
  comment_type?: number;
}

interface RawDynItem {
  id_str: string;
  type: string;
  visible?: boolean;
  basic?: RawBasic;
  modules?: RawModules;
  orig?: RawDynItem;
}

interface RawDynData {
  items?: RawDynItem[];
  offset?: string;
  has_more?: boolean;
  update_num?: number;
  update_baseline?: string;
  total?: number;
  load_next?: boolean;
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

/** opus 正文里会用「[图片]」占位，列表展示时去掉 */
function cleanText(s: string): string {
  const lines: string[] = s.split('\n');
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const t: string = lines[i].trim();
    if (t === '[图片]' || t === '[视频]' || t === '[表情]') {
      continue;
    }
    out.push(lines[i]);
  }
  return out.join('\n').trim();
}

/** 判定映射类型（图文类统一走 'draw'：正文 + 图片网格） */
function kindOf(rawType: string): string {
  switch (rawType) {
    case 'DYNAMIC_TYPE_AV':
    case 'DYNAMIC_TYPE_UGC_SEASON':
      return 'av';
    case 'DYNAMIC_TYPE_DRAW':
    case 'DYNAMIC_TYPE_OPUS':
    case 'DYNAMIC_TYPE_ARTICLE':
    case 'DYNAMIC_TYPE_WORD':
      return 'draw';
    case 'DYNAMIC_TYPE_FORWARD':
      return 'forward';
    default:
      return 'unsupported';
  }
}

function mapItem(raw: RawDynItem): DynItem {
  const modules: RawModules = raw.modules !== undefined && raw.modules !== null ? raw.modules : {};
  const authorRaw: RawAuthor | undefined = modules.module_author;
  const author: DynAuthor = {
    mid: authorRaw !== undefined && authorRaw !== null ? authorRaw.mid : 0,
    name: authorRaw !== undefined && authorRaw !== null ? authorRaw.name : '',
    face: authorRaw !== undefined && authorRaw !== null ? fixUrl(authorRaw.face) : '',
    pubTs: authorRaw !== undefined && authorRaw !== null ? authorRaw.pub_ts : 0,
    pubText: authorRaw !== undefined && authorRaw !== null ? authorRaw.pub_time : ''
  };

  const dyn: RawModuleDynamic | undefined = modules.module_dynamic;
  const major: RawMajor | undefined =
    (dyn !== undefined && dyn !== null && dyn.major !== undefined && dyn.major !== null) ? dyn.major : undefined;

  // 正文：优先 desc.text（视频/转发类）；图文类（OPUS）正文在 major.opus
  let text: string = '';
  if (dyn !== undefined && dyn !== null && dyn.desc !== undefined && dyn.desc !== null
    && dyn.desc.text !== undefined && dyn.desc.text !== null && dyn.desc.text.length > 0) {
    text = dyn.desc.text;
  } else if (major !== undefined && major.opus !== undefined && major.opus !== null) {
    const opus: RawMajorOpus = major.opus;
    const title: string = opus.title !== undefined && opus.title !== null ? opus.title : '';
    const summary: string = (opus.summary !== undefined && opus.summary !== null
      && opus.summary.text !== undefined && opus.summary.text !== null) ? opus.summary.text : '';
    if (title.length > 0 && summary.length > 0) {
      text = title + '\n' + summary;
    } else {
      text = title.length > 0 ? title : summary;
    }
  }
  text = cleanText(text);

  const item: DynItem = {
    id: raw.id_str,
    kind: kindOf(raw.type),
    author: author,
    text: text,
    interactText: '',
    forwardCount: 0,
    commentCount: 0,
    likeCount: 0,
    commentId: raw.basic !== undefined && raw.basic !== null && raw.basic.comment_id_str !== undefined
      ? raw.basic.comment_id_str : raw.id_str,
    commentType: raw.basic !== undefined && raw.basic !== null && raw.basic.comment_type !== undefined
      ? raw.basic.comment_type : 17,
    onlyFans: raw.basic !== undefined && raw.basic !== null && raw.basic.is_only_fans === true
  };
  item.pinned = modules.module_tag?.text || '';
  if (major?.opus !== undefined && major.opus !== null) { item.opusId = raw.id_str; }

  // 统计
  const stat: RawStat | undefined = modules.module_stat;
  if (stat !== undefined && stat !== null) {
    if (stat.forward !== undefined && stat.forward !== null) {
      item.forwardCount = stat.forward.count;
    }
    if (stat.comment !== undefined && stat.comment !== null) {
      item.commentCount = stat.comment.count;
    }
    if (stat.like !== undefined && stat.like !== null) {
      item.likeCount = stat.like.count;
    }
  }

  // 互动提示（"共X人赞了这条动态"）
  const inter: RawModuleInteraction | undefined = modules.module_interaction;
  if (inter !== undefined && inter !== null && inter.items !== undefined && inter.items !== null && inter.items.length > 0) {
    const d: RawDesc | undefined = inter.items[0].desc;
    if (d !== undefined && d !== null && d.rich_text_nodes !== undefined && d.rich_text_nodes !== null) {
      const parts: string[] = [];
      for (let i = 0; i < d.rich_text_nodes.length; i++) {
        parts.push(d.rich_text_nodes[i].orig_text);
      }
      item.interactText = parts.join('');
    }
  }

  // 类型内容
  if (item.kind === 'av' && major !== undefined) {
    const a: RawMajorArchive | undefined =
      major.archive !== undefined && major.archive !== null ? major.archive : major.ugc_season;
    if (a !== undefined && a !== null) {
      item.archive = {
        bvid: a.bvid,
        title: stripTag(a.title),
        cover: fixUrl(a.cover),
        durationText: a.duration_text || '',
        play: a.stat !== undefined && a.stat !== null ? a.stat.play : 0,
        danmaku: a.stat !== undefined && a.stat !== null ? a.stat.danmaku : 0
      };
    }
  } else if (item.kind === 'draw') {
    const pics: DynPic[] = [];
    // 旧式图片动态：major.draw.items[{src,width,height}]
    const drawItems: RawDrawPic[] | undefined = (major !== undefined && major.draw !== undefined && major.draw !== null)
      ? major.draw.items : undefined;
    if (drawItems !== undefined && drawItems !== null) {
      for (let i = 0; i < drawItems.length; i++) {
        pics.push({
          src: fixUrl(drawItems[i].src),
          width: drawItems[i].width,
          height: drawItems[i].height
        });
      }
    }
    // 新式 OPUS 动态：major.opus.pics[{url,width,height}]
    const opusPics: RawOpusPic[] | undefined = (major !== undefined && major.opus !== undefined && major.opus !== null)
      ? major.opus.pics : undefined;
    if (opusPics !== undefined && opusPics !== null) {
      for (let i = 0; i < opusPics.length; i++) {
        pics.push({
          src: fixUrl(opusPics[i].url),
          width: opusPics[i].width,
          height: opusPics[i].height
        });
      }
    }
    item.pics = pics;
  } else if (item.kind === 'forward') {
    if (raw.orig !== undefined && raw.orig !== null) {
      item.orig = mapItem(raw.orig);
    }
  }

  return item;
}

export class DynamicService {
  /** 详情页缓存（router 只传 id，避免超长 JSON 参数） */
  private static detailCache: Map<string, DynItem> = new Map<string, DynItem>();

  static putDetail(item: DynItem): void {
    if (DynamicService.detailCache.size > 30) {
      DynamicService.detailCache.clear();
    }
    DynamicService.detailCache.set(item.id, item);
  }

  static getDetail(id: string): DynItem | undefined {
    return DynamicService.detailCache.get(id);
  }

  static async space(mid: number, offset: string, keyword: string = '', page: number = 1, hops: number = 0): Promise<DynPageResult> {
    const params: Record<string, string> = { 'host_mid': mid.toString(), 'offset': offset,
      'page': page.toString(), 'timezone_offset': '-480', 'features': 'itemOpusStyle,opusBigCover',
      'platform': 'web', 'web_location': '333.1387' };
    if (keyword.length > 0) { params['keyword'] = keyword; }
    const signed: Record<string, string> = await wbiSign(params);
    const raw: string = await getJson(API_BASE + '/x/polymer/web-dynamic/v1/feed/space'
      + (keyword.length > 0 ? '/search' : '') + '?' + buildQuery(signed), {
      'Referer': 'https://space.bilibili.com/' + mid.toString() + '/dynamic', 'Origin': 'https://space.bilibili.com'
    });
    const resp = parseEnvelope<RawDynData>(raw); ensureOk(resp);
    if (!resp.data) { throw new Error('动态数据为空'); }
    if (resp.data.load_next === true && resp.data.has_more !== false && resp.data.offset
      && resp.data.offset !== offset && hops < 3) {
      return DynamicService.space(mid, resp.data.offset, keyword, page + 1, hops + 1);
    }
    const items: DynItem[] = (resp.data.items || []).filter((r: RawDynItem) => r.visible !== false
      && r.type !== 'DYNAMIC_TYPE_NONE').map((r: RawDynItem) => mapItem(r));
    return { items: items, offset: resp.data.offset || '', hasMore: resp.data.has_more === true, total: resp.data.total };
  }

  /** 详情必须联网；列表缓存只用作首帧，不作为完整长文数据。 */
  static async loadDetail(id: string, opusOnly: boolean = false): Promise<DynItem> {
    if (opusOnly) { return DynamicService.loadOpus(id); }
    const raw: string = await getJson(API_BASE + '/x/polymer/web-dynamic/v1/detail?'
      + buildQuery({ 'id': id, 'features': 'itemOpusStyle,opusBigCover' }));
    const response = parseEnvelope<DynamicDetail>(raw); ensureOk(response);
    if (!response.data?.item) { throw new Error('动态已失效或暂不可见'); }
    const item: DynItem = mapItem(response.data.item);
    if (item.opusId) { return DynamicService.loadOpus(id); }
    DynamicService.putDetail(item); return item;
  }
  private static async loadOpus(id: string): Promise<DynItem> {
    const params: Record<string, string> = await wbiSign({ 'id': id, 'features': 'htmlNewStyle', 'timezone_offset': '-480' });
    const raw: string = await getJson(API_BASE + '/x/polymer/web-dynamic/v1/opus/detail?' + buildQuery(params));
    const response = parseEnvelope<OpusDetail>(raw); ensureOk(response);
    const opus: OpusItem | undefined = response.data?.item;
    if (!opus) { throw new Error('图文已失效或暂不可见'); }
    let author: RawAuthor | undefined = undefined;
    let stat: RawStat | undefined = undefined;
    const paragraphs: DynParagraph[] = [];
    let title: string = '';
    const modules: OpusModule[] = opus.modules || [];
    for (let i: number = 0; i < modules.length; i++) {
      const m: OpusModule = modules[i];
      if (m.module_author) { author = m.module_author; }
      if (m.module_stat) { stat = m.module_stat; }
      if (m.module_title?.text) { title = m.module_title.text; }
      const top: RawOpusPic[] = m.module_top?.display?.album?.pics || [];
      if (top.length > 0) { paragraphs.push({ text: [], heading: false,
        pics: top.map((p: RawOpusPic): DynPic => ({ src: fixUrl(p.url), width: p.width, height: p.height })) }); }
      const content: OpusParagraph[] = m.module_content?.paragraphs || [];
      for (let j: number = 0; j < content.length; j++) {
        const p: OpusParagraph = content[j];
        const nodes: DynTextNode[] = (p.text?.nodes || p.heading?.nodes || p.blockquote?.nodes || []).map((n: OpusNode): DynTextNode => {
          const style: OpusStyle | undefined = n.word?.style || n.rich?.style;
          return { text: n.word?.words || n.rich?.text || n.rich?.orig_text || n.formula?.latex_content || '',
            link: n.rich?.jump_url || '', mid: n.rich?.type === 'RICH_TEXT_NODE_TYPE_AT' ? Number(n.rich.rid || 0) : 0,
            bold: style?.bold === true, italic: style?.italic === true, strike: style?.strikethrough === true,
            size: n.word?.font_size || 16 };
        });
        if (p.code?.content) { nodes.push({ text: p.code.content, link: '', mid: 0,
          bold: false, italic: false, strike: false, size: 14 }); }
        const lists: OpusListItem[] = p.list?.items || [];
        for (let k: number = 0; k < lists.length; k++) {
          const row: OpusListItem = lists[k];
          const prefix: string = p.list?.style === 1 ? (row.order || k + 1).toString() + '. ' : '• ';
          nodes.push({ text: (k > 0 ? '\n' : '') + '  '.repeat(Math.min(8, row.level || 0)) + prefix
            + (row.nodes || []).map((n: OpusNode) => n.word?.words || n.rich?.text || n.formula?.latex_content || '').join(''),
            link: '', mid: 0, bold: false, italic: false, strike: false, size: 16 });
        }
        const pictures: RawOpusPic[] = p.pic?.pics || [];
        if (p.line?.pic) { pictures.push(p.line.pic); }
        const contentCard: OpusCardContent | undefined = p.link_card?.card?.ugc || p.link_card?.card?.common || p.link_card?.card?.opus;
        paragraphs.push({ text: nodes, heading: !!p.heading, quote: !!p.blockquote,
          divider: !!p.line && !p.line.pic,
          card: contentCard ? { title: contentCard.title || '查看内容', cover: fixUrl(contentCard.cover || ''),
            link: contentCard.jump_url || '' } : undefined,
          pics: pictures.map((pic: RawOpusPic): DynPic => ({ src: fixUrl(pic.url), width: pic.width, height: pic.height })) });
      }
    }
    if (paragraphs.length === 0 && !opus.basic?.is_only_fans) { throw new Error('图文正文未返回，请重试'); }
    const item: DynItem = { id: id, kind: 'draw', opusId: id,
      author: { mid: author?.mid || 0, name: author?.name || '', face: fixUrl(author?.face || ''),
        pubTs: Number(author?.pub_ts || 0), pubText: author?.pub_time || '' },
      text: title, paragraphs: paragraphs, interactText: '', onlyFans: opus.basic?.is_only_fans === true,
      commentId: opus.basic?.comment_id_str || id, commentType: opus.basic?.comment_type || 17,
      forwardCount: stat?.forward?.count || 0, commentCount: stat?.comment?.count || 0, likeCount: stat?.like?.count || 0 };
    DynamicService.putDetail(item); return item;
  }

  /**
   * 关注动态流
   * @param dynType all | video | draw
   * @param offset 首页空串；翻页传上一页返回的 offset
   */
  static async feed(dynType: string, offset: string): Promise<DynPageResult> {
    const params: Record<string, string> = {
      'timezone_offset': '-480',
      'type': dynType,
      'page': '1',
      'platform': 'web',
      'features': 'itemOpusStyle,opusBigCover',
      'web_location': '333.1365'
    };
    if (offset.length > 0) {
      params['offset'] = offset;
    }
    const signed: Record<string, string> = await wbiSign(params);
    const url: string = API_BASE + '/x/polymer/web-dynamic/v1/feed/all?' + buildQuery(signed);
    const raw: string = await getJson(url);
    const resp = parseEnvelope<RawDynData>(raw);
    ensureOk(resp);
    const data: RawDynData | undefined = resp.data;
    if (data === undefined || data === null) {
      throw new AppError('parse', -1, '动态数据为空');
    }
    const items: DynItem[] = [];
    const rawItems: RawDynItem[] | undefined = data.items;
    if (rawItems !== undefined && rawItems !== null) {
      for (let i = 0; i < rawItems.length; i++) {
        if (rawItems[i].type === 'DYNAMIC_TYPE_NONE') {
          continue;
        }
        // Nara 同款：服务端标记不可见的动态（空占位）直接跳过
        if (rawItems[i].visible === false) {
          continue;
        }
        items.push(mapItem(rawItems[i]));
      }
    }
    return {
      items: items,
      offset: data.offset !== undefined && data.offset !== null ? data.offset : '',
      hasMore: data.has_more === true,
      updateBaseline: data.update_baseline || ''
    };
  }
}
