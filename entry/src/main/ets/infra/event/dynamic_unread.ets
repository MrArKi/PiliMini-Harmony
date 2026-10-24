/** 动态未读：仅保存服务端基线，数字来自 Web update 接口，不按列表长度猜测。 */
import { getJson, buildQuery, parseEnvelope, ensureOk } from '../http/http';
import { CookieStore } from '../cookie/cookie_store';
import { prefsGet, prefsPut } from '../storage/prefs';
import { API_BASE } from '../../config/constants';

export const DYNAMIC_UNREAD_KEY: string = 'dynamicUnreadCount';
interface DynamicUpdate { update_num?: number; }

export class DynamicUnread {
  private static account: string = '';
  private static baseline: string = '';
  private static baselineWrite: Promise<void> = Promise.resolve();
  private static baselineVersion: number = 0;
  /** 仅留在当前进程，绑定请求与账号初始化，不落盘。 */
  private static cookieSnapshot: string = '';
  private static cookieRevision: number = -1;
  private static version: number = 0;
  private static activity: number = 0;
  private static running: boolean = false;
  private static allowed: boolean = false;
  private static pending: boolean = false;
  private static syncing: Promise<boolean> | undefined = undefined;
  private static syncingActivity: number = -1;

  private static publish(count: number): void {
    AppStorage.setOrCreate(DYNAMIC_UNREAD_KEY, count);
  }

  /** Nara setDynCount：进入动态只清UI角标；不请求、不推进持久化已读基线。 */
  static dismissBadge(): void { DynamicUnread.publish(0); }

  /** 取消旧请求的 UI 回写，不中断 HTTP，也不留下定时任务。 */
  static cancel(): void {
    DynamicUnread.allowed = false;
    DynamicUnread.pending = false;
    DynamicUnread.activity++;
    DynamicUnread.version++;
  }

  static reset(): void {
    DynamicUnread.cancel();
    DynamicUnread.account = '';
    DynamicUnread.baseline = '';
    DynamicUnread.baselineVersion++;
    DynamicUnread.cookieSnapshot = '';
    DynamicUnread.cookieRevision = -1;
    DynamicUnread.publish(0);
  }

  private static syncAccount(activity: number): Promise<boolean> {
    if (activity !== DynamicUnread.activity) { return Promise.resolve(false); }
    if (DynamicUnread.syncing !== undefined && DynamicUnread.syncingActivity === activity) {
      return DynamicUnread.syncing;
    }
    const operation: Promise<boolean> = DynamicUnread.loadAccount(activity).finally((): void => {
      if (DynamicUnread.syncing === operation) { DynamicUnread.syncing = undefined; }
    });
    DynamicUnread.syncingActivity = activity;
    DynamicUnread.syncing = operation;
    return operation;
  }

  private static async loadAccount(activity: number): Promise<boolean> {
    const version: number = DynamicUnread.version;
    const cookieRevision: number = CookieStore.sessionRevision();
    const raw: string = await CookieStore.getRaw();
    if (!DynamicUnread.isCurrent(activity, version, cookieRevision)) { return false; }
    let logged: boolean = false;
    let mid: string = '';
    const parts: string[] = raw.split(';');
    for (let i: number = 0; i < parts.length; i++) {
      const pair: string = parts[i].trim();
      if (pair.startsWith('SESSDATA=') && pair.length > 9) { logged = true; }
      if (pair.startsWith('DedeUserID=')) { mid = pair.substring(11); }
    }
    if (!logged) { DynamicUnread.reset(); return false; }
    // Cookie 登录缺少 UID 时仅保留本次进程基线，绝不把凭据写入键名。
    const account: string = mid.length > 0 ? mid : 'session';
    if (account === DynamicUnread.account && raw === DynamicUnread.cookieSnapshot) {
      DynamicUnread.cookieRevision = cookieRevision;
      return true;
    }
    const baseline: string = mid.length > 0 ? await prefsGet('dynamic_read_baseline_' + mid, '') : '';
    if (!DynamicUnread.isCurrent(activity, version, cookieRevision)) { return false; }
    // 初始化原子提交；并发 refresh/markRead 不会先看见账号、再看见空基线。
    DynamicUnread.version++;
    DynamicUnread.account = account;
    DynamicUnread.baseline = baseline;
    DynamicUnread.baselineVersion++;
    DynamicUnread.cookieSnapshot = raw;
    DynamicUnread.cookieRevision = cookieRevision;
    DynamicUnread.publish(0);
    return true;
  }

  private static isCurrent(activity: number, version: number, cookieRevision: number): boolean {
    return activity === DynamicUnread.activity && version === DynamicUnread.version
      && cookieRevision === CookieStore.sessionRevision();
  }

  private static canUseAccount(activity: number): boolean {
    return activity === DynamicUnread.activity && DynamicUnread.cookieSnapshot.length > 0
      && DynamicUnread.cookieRevision === CookieStore.sessionRevision();
  }

  private static async refreshCurrent(activity: number): Promise<void> {
    if (!await DynamicUnread.syncAccount(activity) || !DynamicUnread.canUseAccount(activity)) { return; }
    const version: number = DynamicUnread.version;
    const cookieRevision: number = DynamicUnread.cookieRevision;
    const cookie: string = DynamicUnread.cookieSnapshot;
    const params: Record<string, string> = { 'type': 'all' };
    if (DynamicUnread.baseline.length > 0) { params['update_baseline'] = DynamicUnread.baseline; }
    const raw: string = await getJson(API_BASE + '/x/polymer/web-dynamic/v1/feed/all/update?' + buildQuery(params),
      { 'Cookie': cookie });
    // getJson 仅返回原串；必须在 ensureOk 之前丢弃失效响应，避免旧 -101 退出新会话。
    if (!DynamicUnread.isCurrent(activity, version, cookieRevision)) { return; }
    const response = parseEnvelope<DynamicUpdate>(raw); ensureOk(response);
    const value: number | undefined = response.data?.update_num;
    if (value !== undefined && Number.isFinite(value) && value >= 0) {
      DynamicUnread.publish(Math.floor(value));
    }
  }

  static async refresh(): Promise<void> {
    DynamicUnread.allowed = true;
    if (DynamicUnread.running) { DynamicUnread.pending = true; return; }
    DynamicUnread.running = true;
    const activity: number = DynamicUnread.activity;
    try {
      await DynamicUnread.refreshCurrent(activity);
    } catch (_) {
      // 请求失败保留上次服务端数字；全局 -101 由原有 HTTP 事件处理。
    } finally {
      DynamicUnread.running = false;
      if (DynamicUnread.pending && DynamicUnread.allowed) {
        DynamicUnread.pending = false;
        DynamicUnread.refresh();
      }
    }
  }

  /** 仅由当前可见分类成功展示首页后调用。 */
  static async markRead(baseline: string, cookieRevision: number): Promise<void> {
    const activity: number = DynamicUnread.activity;
    if (cookieRevision !== CookieStore.sessionRevision()) { return; }
    if (!await DynamicUnread.syncAccount(activity) || !DynamicUnread.canUseAccount(activity)) { return; }
    if (cookieRevision !== CookieStore.sessionRevision()) { return; }
    DynamicUnread.version++;
    DynamicUnread.publish(0);
    if (baseline.length === 0) { return; }
    DynamicUnread.baseline = baseline;
    const baselineVersion: number = ++DynamicUnread.baselineVersion;
    const account: string = DynamicUnread.account;
    if (account !== 'session') {
      const operation: Promise<void> = DynamicUnread.baselineWrite.then(async (): Promise<void> => {
        // activity 随离页变化；已经确认已读的同账号保存仍须完成。
        if (account !== DynamicUnread.account || baselineVersion !== DynamicUnread.baselineVersion
          || cookieRevision !== CookieStore.sessionRevision()) { return; }
        await prefsPut('dynamic_read_baseline_' + account, baseline);
      });
      DynamicUnread.baselineWrite = operation.catch((): void => {});
      await DynamicUnread.baselineWrite;
    }
  }
}
