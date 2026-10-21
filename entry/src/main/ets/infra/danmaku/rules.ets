import { prefsGet, prefsPut } from '../storage/prefs';
import { DanmakuItem } from '../../model/danmaku';

export type DanmakuRuleKind = 'keyword' | 'sender';

export interface DanmakuRule {
  id: string;
  kind: DanmakuRuleKind;
  value: string;
  enabled: boolean;
}

const KEY: string = 'setting_danmaku_rules_v1';
const MAX_RULES_LENGTH: number = 64 * 1024;
const MAX_KEYWORDS: number = 100;
const MAX_SENDERS: number = 200;
const MAX_RULES: number = MAX_KEYWORDS + MAX_SENDERS;
let idSequence: number = 0;

function normalizedValue(kind: DanmakuRuleKind, source: string): string {
  if (typeof source !== 'string') { throw new Error('屏蔽内容格式无效'); }
  const value: string = source.trim();
  if (kind === 'keyword') {
    if (value.length === 0 || value.length > 100 || Array.from(value).length > 50) { throw new Error('关键词须为1至50个字符'); }
    return value;
  }
  if (kind === 'sender') {
    if (!/^[0-9a-fA-F]{1,16}$/.test(value)) { throw new Error('发送者标识格式无效'); }
    return value.toLowerCase();
  }
  throw new Error('屏蔽类型无效');
}

function validId(id: string): boolean {
  return typeof id === 'string' && id.length > 0 && id.length <= 80 && id.trim() === id && !/[\u0000-\u001f\u007f]/.test(id);
}

/** 宽松用于读旧数据，严格用于显式保存/修改；始终创建数组和条目副本。 */
function copyRules(source: DanmakuRule[], strict: boolean): DanmakuRule[] {
  if (!Array.isArray(source)) {
    if (strict) { throw new Error('屏蔽规则格式无效'); }
    return [];
  }
  if (strict && source.length > MAX_RULES) { throw new Error('屏蔽规则数量超限'); }
  const rules: DanmakuRule[] = [];
  const ids: Set<string> = new Set<string>();
  const identities: Set<string> = new Set<string>();
  let keywords: number = 0;
  let senders: number = 0;
  // 畸形存储不扩大遍历范围；每类独立限额，超出项跳过且不写回。
  for (let index: number = 0; index < Math.min(source.length, MAX_RULES); index++) {
    const rule: DanmakuRule = source[index];
    try {
      if (rule === null || typeof rule !== 'object' || Array.isArray(rule) || !validId(rule.id) ||
        (rule.kind !== 'keyword' && rule.kind !== 'sender') || typeof rule.enabled !== 'boolean') {
        throw new Error('屏蔽规则字段无效');
      }
      const value: string = normalizedValue(rule.kind, rule.value);
      const identity: string = rule.kind + ':' + value;
      if (ids.has(rule.id) || identities.has(identity)) { throw new Error('该屏蔽规则已存在'); }
      if (rule.kind === 'keyword' ? keywords >= MAX_KEYWORDS : senders >= MAX_SENDERS) {
        throw new Error(rule.kind === 'keyword' ? '关键词最多100条' : '发送者最多200条');
      }
      rules.push({ id: rule.id, kind: rule.kind, value: value, enabled: rule.enabled });
      ids.add(rule.id);
      identities.add(identity);
      if (rule.kind === 'keyword') { keywords++; } else { senders++; }
    } catch (error) {
      if (strict) { throw error as Error; }
    }
  }
  return rules;
}

function ruleIndex(rules: DanmakuRule[], id: string): number {
  const index: number = rules.findIndex((rule: DanmakuRule): boolean => rule.id === id);
  if (index < 0) { throw new Error('屏蔽规则不存在'); }
  return index;
}

export class DanmakuRuleStore {
  private static writes: Promise<void> = Promise.resolve();

  /** 仅本机规则，不请求账号；读损坏项跳过，原始存储保持不变。 */
  static async load(): Promise<DanmakuRule[]> {
    await DanmakuRuleStore.writes;
    const raw: string = await prefsGet(KEY, '');
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > MAX_RULES_LENGTH) { return []; }
    try {
      return copyRules(JSON.parse(raw) as DanmakuRule[], false);
    } catch (_) { return []; }
  }

  static save(rules: DanmakuRule[]): Promise<void> {
    let encoded: string;
    try {
      encoded = JSON.stringify(copyRules(rules, true));
      if (encoded.length > MAX_RULES_LENGTH) { throw new Error('屏蔽规则存储大小超限'); }
    } catch (error) { return Promise.reject(error); }
    const write: Promise<void> = DanmakuRuleStore.writes.then((): Promise<void> => prefsPut(KEY, encoded));
    DanmakuRuleStore.writes = write.catch((_error: Error): void => {});
    return write;
  }

  static add(rules: DanmakuRule[], kind: DanmakuRuleKind, value: string): DanmakuRule[] {
    const next: DanmakuRule[] = copyRules(rules, true);
    const normalized: string = normalizedValue(kind, value);
    if (next.some((rule: DanmakuRule): boolean => rule.kind === kind && rule.value === normalized)) {
      throw new Error('该屏蔽规则已存在');
    }
    const count: number = next.filter((rule: DanmakuRule): boolean => rule.kind === kind).length;
    if (count >= (kind === 'keyword' ? MAX_KEYWORDS : MAX_SENDERS)) {
      throw new Error(kind === 'keyword' ? '关键词最多100条' : '发送者最多200条');
    }
    let id: string;
    do {
      idSequence++;
      id = 'dm_' + Date.now().toString(36) + '_' + idSequence.toString(36);
    } while (next.some((rule: DanmakuRule): boolean => rule.id === id));
    next.push({ id: id, kind: kind, value: normalized, enabled: true });
    return next;
  }

  static edit(rules: DanmakuRule[], id: string, value: string): DanmakuRule[] {
    const next: DanmakuRule[] = copyRules(rules, true);
    const index: number = ruleIndex(next, id);
    const normalized: string = normalizedValue(next[index].kind, value);
    if (next.some((rule: DanmakuRule): boolean => rule.id !== id && rule.kind === next[index].kind && rule.value === normalized)) {
      throw new Error('该屏蔽规则已存在');
    }
    next[index].value = normalized;
    return next;
  }

  static toggle(rules: DanmakuRule[], id: string): DanmakuRule[] {
    const next: DanmakuRule[] = copyRules(rules, true);
    const index: number = ruleIndex(next, id);
    next[index].enabled = !next[index].enabled;
    return next;
  }

  static remove(rules: DanmakuRule[], id: string): DanmakuRule[] {
    const next: DanmakuRule[] = copyRules(rules, true);
    next.splice(ruleIndex(next, id), 1);
    return next;
  }
}

/** 区分大小写关键词包含；发送者仅比对hash，不把它当UID或账户黑名单。 */
export function matchesDanmakuRules(item: DanmakuItem, rules: DanmakuRule[]): boolean {
  const sender: string = item.midHash.toLowerCase();
  for (let index: number = 0; index < Math.min(rules.length, MAX_RULES); index++) {
    const rule: DanmakuRule = rules[index];
    if (!rule.enabled) { continue; }
    if (rule.kind === 'keyword' && item.text.includes(rule.value)) { return true; }
    if (rule.kind === 'sender' && sender.length > 0 && sender === rule.value) { return true; }
  }
  return false;
}

/** 规则变化时编译一次；投放窗口发送者O(1)查找，避免逐条扫描最多200个hash。 */
export class DanmakuRuleMatcher {
  private keywords: string[] = [];
  private senders: Set<string> = new Set<string>();

  constructor(rules: DanmakuRule[]) {
    for (let index: number = 0; index < Math.min(rules.length, MAX_RULES); index++) {
      const rule: DanmakuRule = rules[index];
      if (!rule.enabled) { continue; }
      if (rule.kind === 'keyword') { this.keywords.push(rule.value); }
      else if (rule.kind === 'sender') { this.senders.add(rule.value); }
    }
  }

  matches(item: DanmakuItem): boolean {
    if (item.midHash.length > 0 && this.senders.has(item.midHash.toLowerCase())) { return true; }
    for (let index: number = 0; index < this.keywords.length; index++) {
      if (item.text.includes(this.keywords[index])) { return true; }
    }
    return false;
  }
}
