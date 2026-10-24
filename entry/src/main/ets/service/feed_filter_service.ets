/** 首页本机规则。仅存有限文本元数据；不发送App反馈、不影响其他内容列表。 */
import { prefsGet, prefsPut } from '../infra/storage/prefs';
import { VideoItem } from '../model/video_item';
import { CookieStore } from '../infra/cookie/cookie_store';
import { MemberService, MemberRelation, MemberRelationSession } from './member_service';

export interface FeedFilterRule {
  id: string;
  kind: string; // up | title | zone | video
  value: string;
  label: string;
}

interface SessionBlockedUser { mid: number; revision: number; }

const KEY: string = 'home_feed_filters_v1';
const MAX_RULES: number = 500;

export class FeedFilterService {
  private static rules: FeedFilterRule[] = [];
  private static initialized: Promise<void> | undefined = undefined;
  private static writing: Promise<void> = Promise.resolve();
  private static listeners: (() => void)[] = [];
  private static sessionBlocked: SessionBlockedUser[] = [];

  static async ready(): Promise<void> {
    if (FeedFilterService.initialized === undefined) {
      FeedFilterService.initialized = FeedFilterService.read().catch((e: Error): void => {
        FeedFilterService.initialized = undefined;
        throw e;
      });
    }
    await FeedFilterService.initialized;
  }

  private static async read(): Promise<void> {
    const raw: string = await prefsGet(KEY, '[]');
    if (raw.length > 1024 * 1024) { throw new Error('本地屏蔽数据过大，请检查存储'); }
    const parsed: FeedFilterRule[] = JSON.parse(raw) as FeedFilterRule[];
    if (!Array.isArray(parsed)) { throw new Error('本地屏蔽数据格式错误'); }
    const valid: FeedFilterRule[] = [];
    for (let i: number = 0; i < Math.min(parsed.length, MAX_RULES); i++) {
      const rule: FeedFilterRule = parsed[i];
      if (rule !== undefined && rule !== null && typeof rule.kind === 'string' &&
        typeof rule.value === 'string' && typeof rule.label === 'string' &&
        ['up', 'title', 'zone', 'video'].indexOf(rule.kind) >= 0 &&
        rule.value.length > 0 && rule.value.length <= 500 && rule.label.length <= 520) {
        const id: string = rule.kind + ':' + rule.value;
        if (!valid.some((item: FeedFilterRule): boolean => item.id === id)) {
          valid.push({ id: id, kind: rule.kind, value: rule.value, label: rule.label });
        }
      }
    }
    FeedFilterService.rules = valid;
  }

  static snapshot(): FeedFilterRule[] { return FeedFilterService.rules.slice(); }

  static subscribe(listener: () => void): void {
    if (FeedFilterService.listeners.indexOf(listener) < 0) { FeedFilterService.listeners.push(listener); }
  }

  static unsubscribe(listener: () => void): void {
    const index: number = FeedFilterService.listeners.indexOf(listener);
    if (index >= 0) { FeedFilterService.listeners.splice(index, 1); }
  }

  private static notify(): void {
    const listeners: (() => void)[] = FeedFilterService.listeners.slice();
    for (let i: number = 0; i < listeners.length; i++) {
      try { listeners[i](); } catch (_) { console.warn('[PiliMini-feed] filter observer unavailable'); }
    }
  }

  static matches(item: VideoItem): boolean {
    const revision: number = CookieStore.sessionRevision();
    if (FeedFilterService.sessionBlocked.some((user: SessionBlockedUser): boolean =>
      user.revision === revision && user.mid === item.upMid)) {
      return true;
    }
    return FeedFilterService.rules.some((rule: FeedFilterRule): boolean => {
      if (rule.kind === 'up') { return (item.upMid || 0).toString() === rule.value; }
      if (rule.kind === 'video') { return item.bvid === rule.value; }
      if (rule.kind === 'zone') { return (item.zoneName || '').toLowerCase().includes(rule.value.toLowerCase()); }
      return item.title.toLowerCase().includes(rule.value.toLowerCase());
    });
  }

  /** 只记录本次真实拉黑成功的UID；回首页时复查，空间解除后恢复。 */
  static markBlocked(mid: number, revision: number): void {
    if (revision !== CookieStore.sessionRevision()) { return; }
    FeedFilterService.sessionBlocked = FeedFilterService.sessionBlocked
      .filter((user: SessionBlockedUser): boolean => user.revision === revision && user.mid !== mid).slice(-99);
    FeedFilterService.sessionBlocked.push({ mid: mid, revision: revision });
    FeedFilterService.notify();
  }

  private static dropExpiredSessionBlocks(): void {
    const revision: number = CookieStore.sessionRevision();
    const previousCount: number = FeedFilterService.sessionBlocked.length;
    FeedFilterService.sessionBlocked = FeedFilterService.sessionBlocked
      .filter((user: SessionBlockedUser): boolean => user.revision === revision);
    if (previousCount !== FeedFilterService.sessionBlocked.length) { FeedFilterService.notify(); }
  }

  static async refreshSessionBlocks(): Promise<void> {
    FeedFilterService.dropExpiredSessionBlocks();
    if (FeedFilterService.sessionBlocked.length === 0) { return; }
    const revision: number = CookieStore.sessionRevision();
    let session: MemberRelationSession;
    try { session = await MemberService.captureRelationSession(revision); }
    catch (_) { FeedFilterService.dropExpiredSessionBlocks(); return; }
    if (revision !== CookieStore.sessionRevision()) { FeedFilterService.dropExpiredSessionBlocks(); return; }
    const users: SessionBlockedUser[] = FeedFilterService.sessionBlocked.slice();
    let changed: boolean = false;
    for (let i: number = 0; i < users.length; i++) {
      const user: SessionBlockedUser = users[i];
      let relation: MemberRelation;
      try { relation = await MemberService.relationForSession(user.mid, session); }
      catch (_) {
        if (revision !== CookieStore.sessionRevision()) { FeedFilterService.dropExpiredSessionBlocks(); return; }
        continue;
      }
      if (revision !== CookieStore.sessionRevision()) { FeedFilterService.dropExpiredSessionBlocks(); return; }
      if (relation.attribute !== 128) {
        const index: number = FeedFilterService.sessionBlocked.indexOf(user);
        if (index >= 0) { FeedFilterService.sessionBlocked.splice(index, 1); changed = true; }
      }
    }
    if (changed) { FeedFilterService.notify(); }
  }

  static async add(kind: string, value: string, label: string): Promise<void> {
    const job: Promise<void> = FeedFilterService.writing.then(async (): Promise<void> => {
      await FeedFilterService.ready();
      const text: string = value.trim();
      if (['up', 'title', 'zone', 'video'].indexOf(kind) < 0 || text.length === 0 || text.length > 500) {
        throw new Error('屏蔽内容无效或过长');
      }
      const id: string = kind + ':' + text;
      if (FeedFilterService.rules.some((rule: FeedFilterRule): boolean => rule.id === id)) { return; }
      if (FeedFilterService.rules.length >= MAX_RULES) { throw new Error('屏蔽规则已达500条，请先在屏蔽管理中解除'); }
      const next: FeedFilterRule[] = FeedFilterService.rules.concat([{ id: id, kind: kind,
        value: text, label: label.substring(0, 520) }]);
      await prefsPut(KEY, JSON.stringify(next));
      FeedFilterService.rules = next;
      FeedFilterService.notify();
    });
    FeedFilterService.writing = job.catch((): void => {});
    await job;
  }

  static async remove(id: string): Promise<void> {
    const job: Promise<void> = FeedFilterService.writing.then(async (): Promise<void> => {
      await FeedFilterService.ready();
      const next: FeedFilterRule[] = FeedFilterService.rules.filter((rule: FeedFilterRule): boolean => rule.id !== id);
      await prefsPut(KEY, JSON.stringify(next));
      FeedFilterService.rules = next;
      FeedFilterService.notify();
    });
    FeedFilterService.writing = job.catch((): void => {});
    await job;
  }
}
