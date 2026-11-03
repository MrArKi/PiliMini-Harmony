/**
 * wbi 签名（spec-01 任务 1.3 移植版）
 * 算法参照 PiliNara lib/utils/wbi_sign.dart（bilibili-API-collect 文档）
 * 流程：nav 取 img_key/sub_key → mixinKey → 参数排序 + wts → md5(query + mixinKey) = w_rid
 */
import { md5Hex } from './md5';
import { parseEnvelope } from '../http/http';
import { requestNav } from '../http/nav_request';
import { prefsGet, prefsPut } from '../storage/prefs';

const MIXIN_KEY_ENC_TAB: number[] = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13
];
const CHR_FILTER = /[!'()*]/g;

let cachedMixinKey: string = '';
let cachedDayKey: string = '';
let loadingKey: Promise<string> | undefined = undefined;
let keyGeneration: number = 0;
let keyWrites: Promise<void> = Promise.resolve();
const WBI_CACHE_KEY: string = 'wbi_public_key_v1';

interface StoredMixinKey {
  day: string;
  key: string;
}

interface WbiImg {
  img_url: string;
  sub_url: string;
}

interface NavData {
  wbi_img?: WbiImg;
}

export function getMixinKey(orig: string): string {
  let result: string = '';
  for (let i = 0; i < MIXIN_KEY_ENC_TAB.length; i++) {
    result += orig.charAt(MIXIN_KEY_ENC_TAB[i]);
  }
  return result;
}

function fileNameNoExt(url: string): string {
  const slash: number = url.lastIndexOf('/');
  const base: string = slash >= 0 ? url.substring(slash + 1) : url;
  const dot: number = base.indexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

function todayKey(): string {
  const now = new Date();
  return now.getFullYear().toString() + '-' + now.getMonth().toString() + '-' + now.getDate().toString();
}

/** 仅清公开签名材料，下一次签名重新取；不影响登录凭据。 */
export async function invalidateMixinKey(): Promise<void> {
  keyGeneration++;
  cachedMixinKey = ''; cachedDayKey = ''; loadingKey = undefined;
  await persistMixinKey('', keyGeneration);
}

function persistMixinKey(raw: string, generation: number): Promise<void> {
  const operation: Promise<void> = keyWrites.then(async (): Promise<void> => {
    if (generation !== keyGeneration) { return; }
    try { await prefsPut(WBI_CACHE_KEY, raw); } catch (_) { /* 公开缓存写失败不阻断签名。 */ }
  });
  keyWrites = operation.catch((): void => {});
  return keyWrites;
}

async function loadMixinKey(dayKey: string, generation: number): Promise<string> {
  try {
    const raw: string = await prefsGet(WBI_CACHE_KEY, '');
    if (raw.length > 0) {
      const stored: StoredMixinKey = JSON.parse(raw) as StoredMixinKey;
      if (stored !== null && stored.day === dayKey && typeof stored.key === 'string' && /^[0-9a-f]{32}$/.test(stored.key)) {
        if (generation === keyGeneration) { cachedMixinKey = stored.key; cachedDayKey = dayKey; }
        return stored.key;
      }
    }
  } catch (_) { /* 无缓存/缓存损坏/存储暂不可用均继续正常网络路径。 */ }
  const raw: string = await requestNav();
  // nav匿名也可返回wbi_img；公开签名材料不包含账号凭据。
  const resp = parseEnvelope<NavData>(raw);
  const img: WbiImg | undefined = resp.data?.wbi_img;
  if (img === undefined || img === null || typeof img.img_url !== 'string' || typeof img.sub_url !== 'string') {
    throw new Error('nav 无 wbi 数据');
  }
  const key: string = getMixinKey(fileNameNoExt(img.img_url) + fileNameNoExt(img.sub_url));
  if (!/^[0-9a-f]{32}$/.test(key)) { throw new Error('nav wbi 数据无效'); }
  if (generation === keyGeneration) {
    cachedMixinKey = key; cachedDayKey = dayKey;
    const stored: StoredMixinKey = { day: dayKey, key: key };
    persistMixinKey(JSON.stringify(stored), generation);
  }
  return key;
}

/** 取公开mixin key：当天磁盘缓存优先，并发请求共用一个Promise。 */
export function getMixinKeyCached(): Promise<string> {
  const dayKey: string = todayKey();
  if (cachedMixinKey.length > 0 && cachedDayKey === dayKey) {
    return Promise.resolve(cachedMixinKey);
  }
  if (loadingKey !== undefined) { return loadingKey; }
  const operation: Promise<string> = loadMixinKey(dayKey, keyGeneration).finally((): void => {
    if (loadingKey === operation) { loadingKey = undefined; }
  });
  loadingKey = operation;
  return operation;
}

/** 对参数签名：附加 wts + w_rid 后返回新参数表 */
export async function wbiSign(params: Record<string, string>): Promise<Record<string, string>> {
  const mixinKey: string = await getMixinKeyCached();
  const p: Record<string, string> = {};
  const keys0: string[] = Object.keys(params);
  for (let i = 0; i < keys0.length; i++) {
    p[keys0[i]] = params[keys0[i]];
  }
  p['wts'] = Math.floor(Date.now() / 1000).toString();
  const keys: string[] = Object.keys(p).sort();
  const parts: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    const v: string = p[k].replace(CHR_FILTER, '');
    parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(v));
  }
  const query: string = parts.join('&');
  p['w_rid'] = await md5Hex(query + mixinKey);
  return p;
}
