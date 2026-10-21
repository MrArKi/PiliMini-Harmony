/**
 * HTTP 基础封装（spec-01 任务 1.2 雏形）
 * 统一注入 UA / Referer；返回原始字符串（保持最小可用，错误模型后续加）
 */
import { http } from '@kit.NetworkKit';
import { UA_PC, BILI_REFERER } from '../../config/constants';
import { AppError } from '../error/app_error';
import { emitAuthLogout } from '../event/app_events';
import { CookieStore } from '../cookie/cookie_store';

export interface ApiEnvelope<T> {
  code: number;
  message: string;
  data?: T;
}

/**
 * 解析 B 站通用响应 envelope（{code,message,data}）
 * 统一 try/catch + 结构校验（风险 4：裸 JSON.parse 不设防）
 */
export function parseEnvelope<T>(raw: string): ApiEnvelope<T> {
  let env: ApiEnvelope<T> | null = null;
  try {
    env = JSON.parse(raw) as ApiEnvelope<T>;
  } catch (e) {
    throw new AppError('parse', -1, 'JSON 解析失败');
  }
  if (env === null || env === undefined) {
    throw new AppError('parse', -1, '响应体为空');
  }
  if (typeof env.code !== 'number' || typeof env.message !== 'string') {
    throw new AppError('parse', -1, '响应结构异常');
  }
  return env;
}

/**
 * envelope code 统一检查（风险 1/3：service 唯一入口，替代各处手写 code!==0）
 * -101 → 触发全局登出事件（spec-03 验收 6）并抛 auth 错误；其它非 0 抛 biz 错误
 */
export function ensureOk<T>(env: ApiEnvelope<T>): void {
  if (env.code !== 0) {
    if (env.code === -101) {
      emitAuthLogout();
      throw new AppError('auth', env.code, env.message);
    }
    throw new AppError('biz', env.code, env.message);
  }
}

/** 高层 API 请求：解析 {code,message,data}，统一错误；-101 触发全局登出事件 */
export async function apiGet<T>(url: string): Promise<T> {
  let raw: string = '';
  try {
    raw = await getJson(url);
  } catch (e) {
    throw new AppError('network', -1, 'HTTP 请求失败');
  }
  const env: ApiEnvelope<T> = parseEnvelope<T>(raw);
  ensureOk(env);
  const d: T | undefined = env.data;
  if (d === undefined) {
    throw new AppError('parse', -1, 'data 为空');
  }
  return d;
}

export async function buildGetHeaders(extraHeaders?: Record<string, string>): Promise<Record<string, string>> {
  const headers: Record<string, string> = {
    'User-Agent': UA_PC,
    'Referer': BILI_REFERER
  };
  // 已登录则附带 Cookie（统一注入）
  const rawCookie: string = await CookieStore.getRaw();
  if (rawCookie.length > 0) {
    headers['Cookie'] = rawCookie;
  }
  if (extraHeaders !== undefined) {
    const keys: string[] = Object.keys(extraHeaders);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = extraHeaders[keys[i]];
    }
  }
  return headers;
}

async function getJsonOnce(url: string, headers: Record<string, string>): Promise<string> {
  const req = http.createHttp();
  try {
    const res = await req.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 15000,
      readTimeout: 15000
    });
    if (typeof res.result === 'string') {
      return res.result as string;
    }
    return JSON.stringify(res.result);
  } finally {
    req.destroy();
  }
}

/** 网络类错误重试 1 次（设计约束；GET 幂等，写操作见 postForm 不重试） */
export async function getJson(url: string, extraHeaders?: Record<string, string>): Promise<string> {
  const headers: Record<string, string> = await buildGetHeaders(extraHeaders);
  try {
    return await getJsonOnce(url, headers);
  } catch (e) {
    return await getJsonOnce(url, headers);
  }
}

export function buildQuery(params: Record<string, string>): string {
  const keys: string[] = Object.keys(params);
  const parts: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    parts.push(encodeURIComponent(keys[i]) + '=' + encodeURIComponent(params[keys[i]]));
  }
  return parts.join('&');
}

/** POST（application/x-www-form-urlencoded；带 Cookie，spec-07 收藏/稍后写操作用） */
export async function postForm(url: string, form: Record<string, string>, cookieSnapshot?: string): Promise<string> {
  const req = http.createHttp();
  try {
    const headers: Record<string, string> = {
      'User-Agent': UA_PC,
      'Referer': BILI_REFERER,
      'Content-Type': 'application/x-www-form-urlencoded'
    };
    // 延迟发送的播放心跳绑定采样时的会话，不能在排队后意外使用另一个账号。
    const rawCookie: string = cookieSnapshot !== undefined ? cookieSnapshot : await CookieStore.getRaw();
    if (rawCookie.length > 0) {
      headers['Cookie'] = rawCookie;
    }
    const res = await req.request(url, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: buildQuery(form),
      connectTimeout: 15000,
      readTimeout: 15000
    });
    if (typeof res.result === 'string') {
      return res.result as string;
    }
    return JSON.stringify(res.result);
  } finally {
    req.destroy();
  }
}

/** 返回响应体 + Set-Cookie（登录轮询用） */
export interface RawResponse {
  body: string;
  setCookie: string[];
}

function extractSetCookie(header: Object | undefined): string[] {
  const out: string[] = [];
  if (header === undefined) {
    return out;
  }
  const rec = header as Record<string, Object>;
  const keys: string[] = Object.keys(rec);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === 'set-cookie') {
      const v: Object = rec[keys[i]];
      if (typeof v === 'string') {
        out.push(v as string);
      } else if (Array.isArray(v)) {
        const arr: string[] = v as string[];
        for (let j = 0; j < arr.length; j++) {
          out.push(arr[j]);
        }
      }
    }
  }
  return out;
}

export async function getJsonWithHeaders(url: string, extraHeaders?: Record<string, string>): Promise<RawResponse> {
  const req = http.createHttp();
  try {
    const headers: Record<string, string> = {
      'User-Agent': UA_PC,
      'Referer': BILI_REFERER
    };
    if (extraHeaders !== undefined) {
      const keys: string[] = Object.keys(extraHeaders);
      for (let i = 0; i < keys.length; i++) {
        headers[keys[i]] = extraHeaders[keys[i]];
      }
    }
    const res = await req.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 15000,
      readTimeout: 15000
    });
    let body: string = '';
    if (typeof res.result === 'string') {
      body = res.result as string;
    } else {
      body = JSON.stringify(res.result);
    }
    return { body: body, setCookie: extractSetCookie(res.header) };
  } finally {
    req.destroy();
  }
}
