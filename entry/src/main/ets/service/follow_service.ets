/** 我的关注：按Nara Web接口映射，账号读写绑定同一Cookie快照，无全局名单缓存。 */
import { getJson, postForm, buildQuery, parseEnvelope, ensureOk, ApiEnvelope } from '../infra/http/http';
import { wbiSign } from '../infra/sign/wbi';
import { CookieStore } from '../infra/cookie/cookie_store';
import { emitFollowChanged } from '../infra/event/app_events';
import { API_BASE, UA_PC } from '../config/constants';
import { FollowSession, FollowItem, FollowGroup, FollowPage } from '../model/follow';

const PAGE_SIZE: number = 20;
const DEVICE_REQUEST: string = '{"platform":"web","device":"pc","spmid":"333.1387"}';

interface FollowOfficialRaw { type?: number; desc?: string; }
interface FollowItemRaw {
  mid?: number;
  uname?: string;
  face?: string;
  sign?: string;
  attribute?: number;
  official_verify?: FollowOfficialRaw;
}
interface FollowDataRaw { list?: FollowItemRaw[]; total?: number; }
interface FollowGroupRaw { tagid?: number; name?: string; count?: number; tip?: string; }
interface FollowCreateRaw { tagid?: number; }
interface FollowRelationRaw { tag?: number[]; }

/** 接口已接受创建，但未返回可用ID；必须先核对分组，不能直接重复新建。 */
export class FollowCreatePendingError extends Error {
  constructor() {
    super('新建请求已提交，分组结果待确认；请关闭后查看分组');
    this.name = 'FollowCreatePendingError';
  }
}

function integer(value: number): boolean {
  return Number.isFinite(value) && Math.floor(value) === value && Math.abs(value) <= Number.MAX_SAFE_INTEGER;
}
function validMid(mid: number): boolean { return integer(mid) && mid > 0 && mid <= Number.MAX_SAFE_INTEGER; }
function avatar(url: string): string {
  const value: string = (url || '').trim();
  const absolute: string = value.startsWith('//') ? 'https:' + value : value;
  return /^https?:\/\/[^/\s]+(?:\/|$)/i.test(absolute) ? absolute.replace(/^http:/i, 'https:') : '';
}
function displayText(value: string | undefined): string {
  // 搜索可能返回em高亮；关注名单仅展示文本，不执行或呈现HTML。
  return typeof value === 'string' ? value.replace(/<[^>]*>/g, '') : '';
}
function pageNumber(page: number): number {
  if (!integer(page) || page < 1) { throw new Error('关注列表页码无效'); }
  return page;
}
function orderValue(orderType: string): string {
  if (orderType !== '' && orderType !== 'attention') { throw new Error('关注排序无效'); }
  return orderType;
}
function groupName(name: string): string {
  const value: string = name.trim();
  if (value.length === 0 || value.length > 16) { throw new Error('分组名称须为1～16个字符'); }
  return value;
}
function customGroup(tagid: number): void {
  if (!integer(tagid) || tagid <= 0) { throw new Error('系统分组不可修改'); }
}
function memberId(mid: number): void {
  if (!validMid(mid)) { throw new Error('关注用户无效'); }
}
function groupId(tagid: number): void {
  if (!integer(tagid) || (tagid < 0 && tagid !== -10 && tagid !== -2)) {
    throw new Error('关注分组无效');
  }
}

function mapItems(raw: FollowItemRaw[]): FollowItem[] {
  const seen: Set<number> = new Set<number>();
  const items: FollowItem[] = [];
  for (let i: number = 0; i < raw.length; i++) {
    const item: FollowItemRaw = raw[i];
    if (item === undefined || item === null || typeof item.mid !== 'number' || !validMid(item.mid) || seen.has(item.mid)) {
      continue;
    }
    seen.add(item.mid);
    const official: FollowOfficialRaw | undefined = item.official_verify;
    items.push({ mid: item.mid, name: displayText(item.uname), face: avatar(item.face || ''),
      sign: displayText(item.sign), attribute: typeof item.attribute === 'number' ? item.attribute : 0,
      officialType: official !== undefined && official !== null && typeof official.type === 'number' ? official.type : -1,
      officialDesc: official !== undefined && official !== null ? displayText(official.desc) : '' });
  }
  return items;
}

function mapPage(raw: FollowItemRaw[], page: number, total: number = -1): FollowPage {
  return { items: mapItems(raw), page: page, nextPage: page + 1, total: total,
    // 组内接口无total，和Nara一样只在空页停止；短页不冒充完整名单。
    hasMore: raw.length > 0 && (total < 0 || page * PAGE_SIZE < total) };
}

export class FollowService {
  static assertSession(session: FollowSession): void {
    if (session.revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化，请重新打开我的关注'); }
  }

  static async captureSession(revision: number = CookieStore.sessionRevision()): Promise<FollowSession> {
    if (revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化，请重新打开我的关注'); }
    const cookie: string = await CookieStore.getRaw();
    if (revision !== CookieStore.sessionRevision()) { throw new Error('登录状态已变化，请重新打开我的关注'); }
    const values: Record<string, string> = {};
    const parts: string[] = cookie.split(';');
    for (let i: number = 0; i < parts.length; i++) {
      const segment: string = parts[i].trim();
      const separator: number = segment.indexOf('=');
      if (separator > 0) { values[segment.substring(0, separator).trim()] = segment.substring(separator + 1).trim(); }
    }
    const account: string = values['DedeUserID'] || '';
    if (!values['SESSDATA'] || !/^\d+$/.test(account) || !validMid(Number(account))) { throw new Error('请先登录'); }
    return { cookie: cookie, csrf: values['bili_jct'] || '', account: account, revision: revision };
  }

  private static async read<T>(session: FollowSession, path: string, params: Record<string, string>,
    signed: boolean = false, emptyValue?: T): Promise<T> {
    FollowService.assertSession(session);
    let raw: string = '';
    try {
      const query: Record<string, string> = signed ? await wbiSign(params) : params;
      FollowService.assertSession(session);
      raw = await getJson(API_BASE + path + (Object.keys(query).length > 0 ? '?' + buildQuery(query) : ''), {
        'Cookie': session.cookie, 'Referer': 'https://space.bilibili.com/' + session.account + '/fans/follow',
        'Origin': 'https://space.bilibili.com'
      });
    } catch (e) { FollowService.assertSession(session); throw e as Error; }
    // 旧账号的-101必须在触发全局登出之前废弃。
    FollowService.assertSession(session);
    const response: ApiEnvelope<T> = parseEnvelope<T>(raw);
    ensureOk(response);
    if (response.data === undefined || response.data === null) {
      if (emptyValue !== undefined) { return emptyValue; }
      throw new Error('关注数据为空，请重试');
    }
    return response.data;
  }

  private static async write<T>(session: FollowSession, path: string, form: Record<string, string>,
    relation: boolean = false): Promise<ApiEnvelope<T>> {
    FollowService.assertSession(session);
    if (session.csrf.length === 0) { throw new Error('登录凭据缺少校验信息，请重新登录'); }
    form['csrf'] = session.csrf;
    const query: Record<string, string> = { 'x-bili-device-req-json': DEVICE_REQUEST };
    if (relation) { query['statistics'] = '{"appId":100,"platform":5}'; }
    let raw: string = '';
    try { raw = await postForm(API_BASE + path + '?' + buildQuery(query), form, session.cookie); }
    catch (e) { FollowService.assertSession(session); throw e as Error; }
    FollowService.assertSession(session);
    const response: ApiEnvelope<T> = parseEnvelope<T>(raw);
    ensureOk(response);
    return response;
  }

  private static fromData(data: FollowDataRaw, page: number): FollowPage {
    const raw: FollowItemRaw[] = data.list || [];
    if (!Array.isArray(raw)) { throw new Error('关注名单格式异常，请重试'); }
    const total: number = typeof data.total === 'number' && integer(data.total) && data.total >= 0 ? data.total : -1;
    return mapPage(raw, page, total);
  }

  static async list(session: FollowSession, page: number = 1, orderType: string = ''): Promise<FollowPage> {
    const pn: number = pageNumber(page);
    const data: FollowDataRaw = await FollowService.read<FollowDataRaw>(session, '/x/relation/followings', {
      'vmid': session.account, 'pn': pn.toString(), 'ps': PAGE_SIZE.toString(), 'order': 'desc',
      'order_type': orderValue(orderType)
    });
    FollowService.assertSession(session);
    return FollowService.fromData(data, pn);
  }

  static async search(session: FollowSession, name: string, page: number = 1): Promise<FollowPage> {
    const keyword: string = name.trim();
    if (keyword.length === 0) { throw new Error('请输入关注昵称'); }
    const pn: number = pageNumber(page);
    const data: FollowDataRaw = await FollowService.read<FollowDataRaw>(session, '/x/relation/followings/search', {
      'vmid': session.account, 'pn': pn.toString(), 'ps': PAGE_SIZE.toString(), 'order': 'desc',
      'order_type': 'attention', 'gaia_source': 'main_web', 'name': keyword, 'web_location': '333.999'
    }, true);
    FollowService.assertSession(session);
    return FollowService.fromData(data, pn);
  }

  static async groups(session: FollowSession): Promise<FollowGroup[]> {
    const raw: FollowGroupRaw[] = await FollowService.read<FollowGroupRaw[]>(session, '/x/relation/tags', {});
    FollowService.assertSession(session);
    if (!Array.isArray(raw)) { throw new Error('关注分组格式异常，请重试'); }
    const seen: Set<number> = new Set<number>();
    const groups: FollowGroup[] = [];
    for (let i: number = 0; i < raw.length; i++) {
      const group: FollowGroupRaw = raw[i];
      if (group === undefined || group === null || typeof group.tagid !== 'number' || !integer(group.tagid) || seen.has(group.tagid)) {
        continue;
      }
      seen.add(group.tagid);
      groups.push({ tagid: group.tagid, name: typeof group.name === 'string' ? group.name : '',
        count: typeof group.count === 'number' && integer(group.count) && group.count >= 0 ? group.count : 0,
        tip: typeof group.tip === 'string' ? group.tip : '', custom: group.tagid > 0 });
    }
    return groups;
  }

  static async groupMembers(session: FollowSession, tagid: number, page: number = 1,
    orderType: string = ''): Promise<FollowPage> {
    // 分组表返回的系统ID可只读浏览；写入仍只接受已证实的系统ID。
    if (!integer(tagid)) { throw new Error('关注分组无效'); }
    const pn: number = pageNumber(page);
    const raw: FollowItemRaw[] = await FollowService.read<FollowItemRaw[]>(session, '/x/relation/tag', {
      'mid': session.account, 'tagid': tagid.toString(), 'pn': pn.toString(), 'ps': PAGE_SIZE.toString(),
      'order_type': orderValue(orderType)
    }, false, []);
    FollowService.assertSession(session);
    if (!Array.isArray(raw)) { throw new Error('分组名单格式异常，请重试'); }
    return mapPage(raw, pn);
  }

  static async memberGroups(session: FollowSession, mid: number): Promise<number[]> {
    memberId(mid);
    const data: FollowRelationRaw = await FollowService.read<FollowRelationRaw>(session, '/x/relation', { 'fid': mid.toString() });
    FollowService.assertSession(session);
    if (data.tag === undefined || data.tag === null) { return []; }
    if (!Array.isArray(data.tag)) { throw new Error('成员分组格式异常，请重试'); }
    const tags: number[] = [];
    for (let i: number = 0; i < data.tag.length; i++) {
      const tagid: number = data.tag[i];
      if (typeof tagid === 'number' && integer(tagid) && tags.indexOf(tagid) < 0) { tags.push(tagid); }
    }
    return tags;
  }

  static async create(session: FollowSession, name: string): Promise<FollowGroup> {
    const value: string = groupName(name);
    const response: ApiEnvelope<FollowCreateRaw> = await FollowService.write<FollowCreateRaw>(session,
      '/x/relation/tag/create', { 'tag': value });
    FollowService.assertSession(session);
    const tagid: number | undefined = response.data?.tagid;
    if (typeof tagid !== 'number' || !integer(tagid) || tagid <= 0) {
      // 请求可能已执行，不自动重试写入；调用页可刷新分组核对。
      throw new FollowCreatePendingError();
    }
    return { tagid: tagid, name: value, count: 0, tip: '', custom: true };
  }

  static async rename(session: FollowSession, tagid: number, name: string): Promise<void> {
    customGroup(tagid);
    await FollowService.write<object>(session, '/x/relation/tag/update', { 'tagid': tagid.toString(), 'name': groupName(name) });
    FollowService.assertSession(session);
  }

  static async delete(session: FollowSession, tagid: number): Promise<void> {
    customGroup(tagid);
    await FollowService.write<object>(session, '/x/relation/tag/del', { 'tagid': tagid.toString() });
    FollowService.assertSession(session);
  }

  static async setGroups(session: FollowSession, mid: number, tagids: number[]): Promise<void> {
    memberId(mid);
    const tags: number[] = [];
    for (let i: number = 0; i < tagids.length; i++) {
      groupId(tagids[i]);
      if (tags.indexOf(tagids[i]) < 0) { tags.push(tagids[i]); }
    }
    if (tags.length > 1 && tags.indexOf(0) >= 0) { throw new Error('默认分组不能与其他分组同时选择'); }
    await FollowService.write<object>(session, '/x/relation/tags/addUsers', {
      'fids': mid.toString(), 'tagids': tags.length === 0 ? '0' : tags.join(',')
    });
    FollowService.assertSession(session);
  }

  static async sortGroups(session: FollowSession, tagids: number[]): Promise<void> {
    if (tagids.length === 0) { throw new Error('没有可排序的自定义分组'); }
    const tags: number[] = [];
    for (let i: number = 0; i < tagids.length; i++) {
      customGroup(tagids[i]);
      if (tags.indexOf(tagids[i]) >= 0) { throw new Error('分组排序不能重复'); }
      tags.push(tagids[i]);
    }
    await FollowService.write<object>(session, '/x/relation/tags/update_sort', { 'tagids': tags.join(',') });
    FollowService.assertSession(session);
  }

  static async cancelFollow(session: FollowSession, mid: number): Promise<void> {
    memberId(mid);
    if (Number(session.account) === mid) { throw new Error('不能对自己执行取消关注'); }
    await FollowService.write<object>(session, '/x/relation/modify', {
      'fid': mid.toString(), 'act': '2', 're_src': '11', 'gaia_source': 'web_main', 'spmid': '333.1387',
      'extend_content': JSON.stringify({ entity: 'user', entity_id: mid, fp: UA_PC })
    }, true);
    FollowService.assertSession(session);
    emitFollowChanged(mid, false, session.revision);
  }
}
