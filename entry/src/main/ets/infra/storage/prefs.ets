/**
 * Preferences 封装（spec-01 存储基础）
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'pilimini_store';
let store: preferences.Preferences | undefined = undefined;
let initializing: Promise<void> | undefined = undefined;

export async function initPrefs(context: common.Context): Promise<void> {
  if (store !== undefined) { return; }
  if (initializing === undefined) {
    initializing = preferences.getPreferences(context, STORE_NAME).then((value: preferences.Preferences): void => {
      store = value;
    }).catch((e: Error): void => {
      initializing = undefined;
      throw e;
    });
  }
  await initializing;
}

async function ready(): Promise<preferences.Preferences> {
  if (initializing !== undefined) { await initializing; }
  if (store === undefined) { throw new Error('存储尚未初始化'); }
  return store;
}

export async function prefsPut(key: string, value: string): Promise<void> {
  const s: preferences.Preferences = await ready();
  await s.put(key, value);
  await s.flush();
}

export async function prefsGet(key: string, def: string): Promise<string> {
  const s: preferences.Preferences = await ready();
  const v = await s.get(key, def);
  return v as string;
}

export async function prefsDelete(key: string): Promise<void> {
  const s: preferences.Preferences = await ready();
  await s.delete(key);
  await s.flush();
}

/** 全部键名（playback_pos 历史键迁移用） */
export async function prefsAllKeys(): Promise<string[]> {
  const s: preferences.Preferences = await ready();
  const all: object = await s.getAll();
  const out: string[] = [];
  if (all !== undefined && all !== null && typeof all === 'object') {
    const rec: Record<string, Object> = all as Record<string, Object>;
    const keys: string[] = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      out.push(keys[i]);
    }
  }
  return out;
}
