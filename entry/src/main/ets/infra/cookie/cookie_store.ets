/**
 * Cookie 管理（spec-01 任务 1.4）
 * 风险2加固：SESSDATA/bili_jct 等敏感凭据存 @ohos.security.asset（系统级加密，锁屏凭据派生）
 *  - asset 不可用（无锁屏凭据等）→ 回退 preferences 明文，保证可用性
 *  - 旧版 prefs 明文在首次读取时自动迁移入 asset 并清除
 */
import { prefsPut, prefsGet, prefsDelete } from '../storage/prefs';
import { asset } from '@kit.AssetStoreKit';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const KEY_COOKIE: string = 'ck_2a7f'; // 旧 prefs 混淆 key（迁移源/回退存储）
const ALIAS_COOKIE: string = 'pilimini_cookie_v1'; // asset 别名

function aliasU8(): Uint8Array {
  return new Uint8Array(buffer.from(ALIAS_COOKIE, 'utf-8').buffer);
}

function strToU8(s: string): Uint8Array {
  return new Uint8Array(buffer.from(s, 'utf-8').buffer);
}

function u8ToStr(v: Object): string {
  const u8: Uint8Array = v as Uint8Array;
  return buffer.from(u8.buffer).toString('utf-8');
}

/** asset 可用性探测 + 写入（失败返回 false 由调用方回退 prefs） */
class AssetCookie {
  static async put(value: string): Promise<boolean> {
    if (value.length === 0) {
      return true;
    }
    try {
      await AssetCookie.remove();
    } catch (e) {
      // 无旧记录，忽略
    }
    try {
      const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      attr.set(asset.Tag.ALIAS, aliasU8());
      attr.set(asset.Tag.SECRET, strToU8(value));
      await asset.add(attr);
      return true;
    } catch (e) {
      return false;
    }
  }

  static async get(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, aliasU8());
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const res: Array<asset.AssetMap> = await asset.query(query);
      if (res.length === 0) {
        return '';
      }
      const secret: asset.Value | undefined = res[0].get(asset.Tag.SECRET);
      if (secret === undefined || !(secret instanceof Uint8Array)) {
        return '';
      }
      return u8ToStr(secret);
    } catch (e) {
      return '';
    }
  }

  static async remove(): Promise<void> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, aliasU8());
    await asset.remove(query);
  }
}

export class CookieStore {
  /** 保存整串 Cookie（asset 优先，失败回退 prefs） */
  static async save(raw: string): Promise<void> {
    const ok: boolean = await AssetCookie.put(raw);
    if (ok) {
      // 成功入 asset 后清除旧明文
      await prefsDelete(KEY_COOKIE);
      return;
    }
    await prefsPut(KEY_COOKIE, raw);
  }

  static async getRaw(): Promise<string> {
    const fromAsset: string = await AssetCookie.get();
    if (fromAsset.length > 0) {
      return fromAsset;
    }
    // 旧版明文迁移：首次读到即搬入 asset 并清除
    const legacy: string = await prefsGet(KEY_COOKIE, '');
    if (legacy.length > 0) {
      const ok: boolean = await AssetCookie.put(legacy);
      if (ok) {
        await prefsDelete(KEY_COOKIE);
      }
      return legacy;
    }
    return '';
  }

  /** 解析某个 cookie 值 */
  static async get(name: string): Promise<string> {
    const raw: string = await CookieStore.getRaw();
    if (raw.length === 0) {
      return '';
    }
    const parts: string[] = raw.split(';');
    for (let i = 0; i < parts.length; i++) {
      const seg: string = parts[i].trim();
      const eq: number = seg.indexOf('=');
      if (eq > 0) {
        const k: string = seg.substring(0, eq).trim();
        if (k === name) {
          return seg.substring(eq + 1).trim();
        }
      }
    }
    return '';
  }

  /** 是否已登录（SESSDATA 非空） */
  static async isLogin(): Promise<boolean> {
    const sess: string = await CookieStore.get('SESSDATA');
    return sess.length > 0;
  }

  static async clear(): Promise<void> {
    try {
      await AssetCookie.remove();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 11000018 = 无匹配记录，属正常
      if (err.code !== 11000018) {
        console.warn('[PiliMini-cookie] asset remove failed: ' + err.code.toString());
        throw new Error('清除登录凭据失败（' + err.code.toString() + '）');
      }
    }
    await prefsDelete(KEY_COOKIE);
  }
}
