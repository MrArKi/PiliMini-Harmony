/**
 * wbi 签名（spec-01 任务 1.3 移植版）
 * 算法参照 PiliNara lib/utils/wbi_sign.dart（bilibili-API-collect 文档）
 * 流程：nav 取 img_key/sub_key → mixinKey → 参数排序 + wts → md5(query + mixinKey) = w_rid
 */
import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { getJson, parseEnvelope } from '../http/http';
import { API_BASE } from '../../config/constants';

const MIXIN_KEY_ENC_TAB: number[] = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13
];
const CHR_FILTER = /[!'()*]/g;

let cachedMixinKey: string = '';
let cachedDayKey: string = '';

interface WbiImg {
  img_url: string;
  sub_url: string;
}

interface NavData {
  wbi_img?: WbiImg;
}

/** MD5（cryptoFramework，输出 hex） */
export async function md5Hex(input: string): Promise<string> {
  const md = cryptoFramework.createMd('MD5');
  await md.update({ data: new Uint8Array(buffer.from(input, 'utf-8').buffer) });
  const digest = await md.digest();
  return buffer.from(digest.data).toString('hex');
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

/** 取 mixinKey（按天缓存；nav 未登录也会返回 wbi_img） */
export async function getMixinKeyCached(): Promise<string> {
  const now = new Date();
  const dayKey: string = now.getFullYear() + '-' + now.getMonth() + '-' + now.getDate();
  if (cachedMixinKey.length > 0 && cachedDayKey === dayKey) {
    return cachedMixinKey;
  }
  const raw: string = await getJson(API_BASE + '/x/web-interface/nav');
  // nav 匿名也返回 code=0 + wbi_img；不走 ensureOk（-101 属常态）
  const resp = parseEnvelope<NavData>(raw);
  const data: NavData | undefined = resp.data;
  if (data === undefined || data === null) {
    throw new Error('nav 无 wbi 数据');
  }
  const img: WbiImg | undefined = data.wbi_img;
  if (img === undefined || img === null) {
    throw new Error('nav 无 wbi 数据');
  }
  const key: string = getMixinKey(fileNameNoExt(img.img_url) + fileNameNoExt(img.sub_url));
  cachedMixinKey = key;
  cachedDayKey = dayKey;
  return key;
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
