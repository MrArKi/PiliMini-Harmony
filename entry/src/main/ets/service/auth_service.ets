/**
 * 账号服务（spec-02 读取 + spec-03 扫码登录）
 */
import { getJson, getJsonWithHeaders, parseEnvelope, ensureOk } from '../infra/http/http';
import { API_BASE } from '../config/constants';
import { CookieStore } from '../infra/cookie/cookie_store';
import { AppError } from '../infra/error/app_error';

export const PASSPORT_BASE: string = 'https://passport.bilibili.com';

export interface UserInfo {
  mid: number;
  uname: string;
  face: string;
  /** 等级（LV 徽章；未取到为 0） */
  level: number;
  /** 硬币数 */
  coins: number;
  /** 当前经验 / 升级所需经验 */
  curExp: number;
  nextExp: number;
}

/** 关注/粉丝数（/x/relation/stat） */
export interface RelStat {
  following: number;
  follower: number;
}

export interface QrGenerateResult {
  url: string;
  qrcodeKey: string;
}

export interface QrPollResult {
  /** 0=成功；86101=未扫码；86090=已扫码待确认；86038=已过期；-1=异常 */
  code: number;
  message: string;
  success: boolean;
}

interface NavLevelInfo {
  current_level: number;
  current_exp: number;
  /** 满级时接口返回字符串 "--" */
  next_exp: number | string;
}

interface NavData {
  isLogin: boolean;
  mid: number;
  uname: string;
  face: string;
  /** 硬币数（nav 字段名为 money） */
  money?: number;
  level_info?: NavLevelInfo;
}

interface RelStatData {
  following: number;
  follower: number;
}

interface QrGenData {
  url: string;
  qrcode_key: string;
}

interface QrPollData {
  url: string;
  code: number;
  message: string;
}

function toHttps(u: string): string {
  if (u.startsWith('http://')) {
    return 'https://' + u.substring(7);
  }
  return u;
}

/** 经验值字段可能是数字或 "--"（满级） */
function toExp(v: number | string | undefined): number {
  if (v === undefined) {
    return 0;
  }
  if (typeof v === 'number') {
    return v;
  }
  const n: number = parseInt(v, 10);
  return isNaN(n) ? 0 : n;
}

export class AuthService {
  /** 读取当前登录用户（未登录/失效返回 null）；不走 apiGet（-101 属常态，不触发登出事件） */
  static async fetchNav(strict: boolean = false): Promise<UserInfo | null> {
    try {
      const raw: string = await getJson(API_BASE + '/x/web-interface/nav');
      // 不走 ensureOk：未登录时 -101 属常态，不触发全局登出事件
      const resp = parseEnvelope<NavData>(raw);
      if (resp.code === -101 && await CookieStore.isLogin()) { ensureOk(resp); }
      if (resp.code !== 0) {
        if (strict && resp.code !== -101) { ensureOk(resp); }
        return null;
      }
      const d: NavData | undefined = resp.data;
      if (d === undefined || !d.isLogin) {
        return null;
      }
      const lv: NavLevelInfo | undefined = d.level_info;
      const info: UserInfo = {
        mid: d.mid,
        uname: d.uname,
        face: toHttps(d.face),
        level: lv !== undefined ? lv.current_level : 0,
        coins: d.money !== undefined ? d.money : 0,
        curExp: lv !== undefined ? lv.current_exp : 0,
        nextExp: lv !== undefined ? toExp(lv.next_exp) : 0
      };
      return info;
    } catch (e) {
      console.warn('[PiliMini-nav] exception=' + JSON.stringify(e));
      if (strict) { throw e as Error; }
      return null;
    }
  }

  /** 关注 / 粉丝数（失败返回 0/0，不阻塞页面） */
  static async relationStat(mid: number): Promise<RelStat> {
    if (mid <= 0) {
      return { following: 0, follower: 0 };
    }
    try {
      const raw: string = await getJson(API_BASE + '/x/relation/stat?vmid=' + mid.toString());
      const resp = parseEnvelope<RelStatData>(raw);
      ensureOk(resp);
      const d: RelStatData | undefined = resp.data;
      if (d === undefined) {
        return { following: 0, follower: 0 };
      }
      return { following: d.following, follower: d.follower };
    } catch (e) {
      console.warn('[PiliMini-relStat] exception=' + JSON.stringify(e));
      return { following: 0, follower: 0 };
    }
  }

  static async isLogin(): Promise<boolean> {
    return await CookieStore.isLogin();
  }

  /** 退出登录：清 Cookie */
  static async logout(): Promise<void> {
    await CookieStore.clear();
  }

  /** 扫码登录：获取二维码 */
  static async qrcodeGenerate(): Promise<QrGenerateResult> {
    const raw: string = await getJson(PASSPORT_BASE + '/x/passport-login/web/qrcode/generate');
    const resp = parseEnvelope<QrGenData>(raw);
    const d: QrGenData | undefined = resp.data;
    if (resp.code !== 0 || d === undefined) {
      throw new AppError('biz', resp.code, '获取二维码失败');
    }
    return { url: d.url, qrcodeKey: d.qrcode_key };
  }

  /** 扫码登录：轮询状态（成功时从 Set-Cookie 提取并落盘） */
  static async qrcodePoll(qrcodeKey: string, isCurrent: () => boolean = (): boolean => true): Promise<QrPollResult> {
    const resp = await getJsonWithHeaders(PASSPORT_BASE + '/x/passport-login/web/qrcode/poll?qrcode_key=' + qrcodeKey);
    const r = parseEnvelope<QrPollData>(resp.body);
    const d: QrPollData | undefined = r.data;
    if (r.code !== 0 || d === undefined) {
      return { code: -1, message: r.message, success: false };
    }
    if (d.code === 0) {
      if (!isCurrent()) { return { code: -1, message: '二维码已失效', success: false }; }
      const cookieStr: string = AuthService.buildCookie(resp.setCookie);
      if (cookieStr.length === 0) { return { code: -1, message: '未收到登录凭据，请刷新二维码', success: false }; }
      await CookieStore.save(cookieStr);
      return { code: 0, message: '登录成功', success: true };
    }
    return { code: d.code, message: d.message, success: false };
  }

  /** Set-Cookie 数组 → "k=v; k=v" */
  private static buildCookie(setCookies: string[]): string {
    const pairs: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < setCookies.length; i++) {
      const seg: string = setCookies[i];
      const semi: number = seg.indexOf(';');
      const kv: string = (semi >= 0 ? seg.substring(0, semi) : seg).trim();
      const eq: number = kv.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name: string = kv.substring(0, eq).trim();
      if (name.length === 0 || seen.has(name)) {
        continue;
      }
      seen.add(name);
      pairs.push(kv);
    }
    return pairs.join('; ');
  }
}
