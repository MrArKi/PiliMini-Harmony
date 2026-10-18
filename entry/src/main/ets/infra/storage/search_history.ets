/**
 * 搜索历史（spec-04）：本地保存，去重、上限 20、可清空
 */
import { prefsGet, prefsPut, prefsDelete } from './prefs';

const KEY: string = 'sh_9f21';
const MAX: number = 20;
let writes: Promise<void> = Promise.resolve();

export class SearchHistory {
  static async load(): Promise<string[]> {
    const raw: string = await prefsGet(KEY, '');
    if (raw.length === 0) {
      return [];
    }
    try {
      return JSON.parse(raw) as string[];
    } catch (e) {
      return [];
    }
  }

  /** 记录关键词（去重 + 置顶 + 上限 20），返回最新列表 */
  static async add(kw: string): Promise<string[]> {
    let result: string[] = [];
    const work: Promise<void> = writes.then(async (): Promise<void> => {
    let list: string[] = await SearchHistory.load();
    const kept: string[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== kw) {
        kept.push(list[i]);
      }
    }
    kept.unshift(kw);
    list = kept.length > MAX ? kept.slice(0, MAX) : kept;
    await prefsPut(KEY, JSON.stringify(list));
      result = list;
    });
    writes = work.catch((): void => {});
    await work;
    return result;
  }

  static async clear(): Promise<void> {
    const work: Promise<void> = writes.then(async (): Promise<void> => { await prefsDelete(KEY); });
    writes = work.catch((): void => {});
    await work;
  }
}
