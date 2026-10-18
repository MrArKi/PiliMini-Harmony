/**
 * 收藏与稍后再看服务（spec-07）
 *  收藏夹：created/list-all、resource/list、resource/deal（增删）、folder/add（新建）
 *  稍后再看：history/toview（列表）、toview/add、toview/del
 *  状态：fav/video/favoured（是否已收藏）
 * 写操作需 csrf（bili_jct，来自 Cookie）
 */
import { getJson, postForm, buildQuery, parseEnvelope, ensureOk } from '../infra/http/http';
import { API_BASE } from '../config/constants';
import { CookieStore } from '../infra/cookie/cookie_store';
import { VideoItem } from '../model/video_item';

export interface FavFolder {
  id: number;
  title: string;
  mediaCount: number;
  favState?: boolean;
  stateKnown?: boolean;
}

export interface FavPage {
  items: VideoItem[];
  hasMore: boolean;
}

interface FavFolderRaw {
  id: number;
  title: string;
  media_count: number;
  fav_state?: number;
}

interface FavFolderListData {
  count?: number;
  list?: FavFolderRaw[];
}

interface FavUpperRaw {
  mid?: number;
  name?: string;
  face?: string;
}

interface FavCntRaw {
  play?: number;
  danmaku?: number;
}

interface FavMediaRaw {
  id: number;
  bvid?: string;
  title: string;
  cover: string;
  duration: number;
  attr?: number;
  upper?: FavUpperRaw;
  cnt_info?: FavCntRaw;
}

interface FavResourceData {
  medias?: FavMediaRaw[];
  has_more?: boolean;
  info?: FavSeasonInfo;
}
interface FavSeasonInfo { media_count?: number; }

interface FavouredData {
  favoured?: boolean;
  count?: number;
}

interface LaterRaw {
  aid: number;
  bvid: string;
  title: string;
  pic: string;
  duration: number;
  progress?: number;
  owner?: FavUpperRaw;
  stat?: FavCntRaw;
}

interface LaterData {
  list?: LaterRaw[];
  count?: number;
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

async function csrf(): Promise<string> {
  return await CookieStore.get('bili_jct');
}

export class FavService {
  /** 收藏夹列表（需登录） */
  static async folders(mid: number, rid: number = 0): Promise<FavFolder[]> {
    const raw: string = await getJson(API_BASE + '/x/v3/fav/folder/created/list-all?up_mid=' + mid.toString() +
      (rid > 0 ? '&type=2&rid=' + rid.toString() : ''));
    const resp = parseEnvelope<FavFolderListData>(raw);
    ensureOk(resp);
    const out: FavFolder[] = [];
    const list: FavFolderRaw[] | undefined = resp.data !== undefined && resp.data !== null ? resp.data.list : undefined;
    if (list !== undefined && list !== null) {
      for (let i = 0; i < list.length; i++) {
        out.push({ id: list[i].id, title: list[i].title, mediaCount: list[i].media_count,
          favState: list[i].fav_state === 1, stateKnown: list[i].fav_state === 0 || list[i].fav_state === 1 });
      }
    }
    return out;
  }

  /** 收藏夹内容（分页，ps=20） */
  static async folderItems(mediaId: number, page: number, subscription: boolean = false): Promise<FavPage> {
    const url: string = subscription ? API_BASE + '/x/space/fav/season/list?season_id=' + mediaId.toString()
      + '&pn=' + page.toString() + '&ps=20' : API_BASE + '/x/v3/fav/resource/list?media_id=' + mediaId.toString() +
      '&pn=' + page.toString() + '&ps=20&platform=web&order=mtime&type=0&tid=0';
    const raw: string = await getJson(url);
    const resp = parseEnvelope<FavResourceData>(raw);
    ensureOk(resp);
    const items: VideoItem[] = [];
    const data: FavResourceData | undefined = resp.data;
    if (data !== undefined && data !== null) {
      const medias: FavMediaRaw[] | undefined = data.medias;
      if (medias !== undefined && medias !== null) {
        for (let i = 0; i < medias.length; i++) {
          const m: FavMediaRaw = medias[i];
          const invalid: boolean = m.attr !== undefined && m.attr !== 0;
          items.push({
            key: 'fav_' + mediaId.toString() + '_' + page.toString() + '_' + m.id.toString(),
            bvid: m.bvid !== undefined && m.bvid !== null ? m.bvid : '',
            cid: 0,
            title: invalid ? '已失效视频' : m.title,
            cover: fixUrl(m.cover),
            upName: (m.upper !== undefined && m.upper !== null && m.upper.name !== undefined) ? (m.upper.name as string) : '',
            upFace: (m.upper !== undefined && m.upper !== null && m.upper.face !== undefined) ? fixUrl(m.upper.face as string) : '',
            playCount: (m.cnt_info !== undefined && m.cnt_info !== null && m.cnt_info.play !== undefined) ? (m.cnt_info.play as number) : 0,
            danmaku: (m.cnt_info !== undefined && m.cnt_info !== null && m.cnt_info.danmaku !== undefined) ? (m.cnt_info.danmaku as number) : 0,
            pubdate: 0,
            duration: m.duration
          });
        }
      }
    }
    return { items: items, hasMore: data !== undefined && data !== null && (subscription
      ? page * 20 < (data.info?.media_count || 0) : data.has_more === true) };
  }

  /** 收藏/取消收藏（addIds/delIds 为收藏夹 id；rid=视频 avid） */
  static async deal(rid: number, addIds: number[], delIds: number[]): Promise<void> {
    const token: string = await csrf();
    const form: Record<string, string> = {
      'rid': rid.toString(),
      'type': '2',
      'add_media_ids': addIds.join(','),
      'del_media_ids': delIds.join(','),
      'csrf': token
    };
    const raw: string = await postForm(API_BASE + '/x/v3/fav/resource/deal', form);
    const resp = parseEnvelope<object>(raw);
    ensureOk(resp);
  }

  /** 新建收藏夹 */
  static async newFolder(title: string): Promise<void> {
    const token: string = await csrf();
    const raw: string = await postForm(API_BASE + '/x/v3/fav/folder/add', {
      'title': title,
      'privacy': '0',
      'csrf': token
    });
    const resp = parseEnvelope<object>(raw);
    ensureOk(resp);
  }

  /** 是否已收藏（详情页按钮态） */
  static async favoured(aid: number): Promise<boolean> {
    try {
      const raw: string = await getJson(API_BASE + '/x/v2/fav/video/favoured?aid=' + aid.toString());
      const resp = parseEnvelope<FavouredData>(raw);
      ensureOk(resp);
      if (resp.data === undefined || resp.data === null) {
        return false;
      }
      return resp.data.favoured === true;
    } catch (e) {
      return false;
    }
  }

  // ===== 稍后再看 =====

  /** 稍后再看列表 */
  static async laterList(): Promise<VideoItem[]> {
    const raw: string = await getJson(API_BASE + '/x/v2/history/toview');
    const resp = parseEnvelope<LaterData>(raw);
    ensureOk(resp);
    const items: VideoItem[] = [];
    const data: LaterData | undefined = resp.data;
    if (data !== undefined && data !== null) {
      const list: LaterRaw[] | undefined = data.list;
      if (list !== undefined && list !== null) {
        for (let i = 0; i < list.length; i++) {
          const it: LaterRaw = list[i];
          items.push({
            key: 'later_' + it.aid.toString(),
            bvid: it.bvid,
            cid: 0,
            title: it.title,
            cover: fixUrl(it.pic),
            upName: (it.owner !== undefined && it.owner !== null && it.owner.name !== undefined) ? (it.owner.name as string) : '',
            upFace: (it.owner !== undefined && it.owner !== null && it.owner.face !== undefined) ? fixUrl(it.owner.face as string) : '',
            playCount: (it.stat !== undefined && it.stat !== null && it.stat.play !== undefined) ? (it.stat.play as number) : 0,
            danmaku: (it.stat !== undefined && it.stat !== null && it.stat.danmaku !== undefined) ? (it.stat.danmaku as number) : 0,
            pubdate: 0,
            duration: it.duration,
            aid: it.aid
          });
        }
      }
    }
    return items;
  }

  /** 加入稍后再看（接口用 aid，非 bvid） */
  static async laterAdd(aid: number): Promise<void> {
    const token: string = await csrf();
    const raw: string = await postForm(API_BASE + '/x/v2/history/toview/add', {
      'aid': aid.toString(),
      'csrf': token
    });
    const resp = parseEnvelope<object>(raw);
    ensureOk(resp);
  }

  /** 移出稍后再看（接口用 aid，非 bvid） */
  static async laterRemove(aid: number): Promise<void> {
    const token: string = await csrf();
    const raw: string = await postForm(API_BASE + '/x/v2/history/toview/del', {
      'aid': aid.toString(),
      'csrf': token
    });
    const resp = parseEnvelope<object>(raw);
    ensureOk(resp);
  }
}
