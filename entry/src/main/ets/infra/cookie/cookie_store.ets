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

  static async get(): Promise<string | undefined> {
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
      // 查询失败仍沿用prefs回退；不能把临时系统错误永久缓存成未登录。
      return (e as BusinessError).code === 11000018 ? '' : undefined;
    }
  }

  static async remove(): Promise<void> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, aliasU8());
    await asset.remove(query);
  }
}

interface StoredCookie {
  raw: string;
  cacheable: boolean;
}

export class CookieStore {
  // 只在当前进程保留一份；首批并发请求共用读取，避免逐接口反复查询安全资产。
  private static cached: string | undefined = undefined;
  private static reading: Promise<string> | undefined = undefined;
  private static storageQueue: Promise<void> = Promise.resolve();
  private static revision: number = 0;
  private static mutations: number = 0;

  /** 保存/清除开始即递增；异步查询据此丢弃旧会话结果，不暴露凭据。 */
  static sessionRevision(): number { return CookieStore.revision; }

  /** 读取中的旧迁移、登录保存与退出清除必须遵循同一持久化顺序。 */
  private static mutate(work: () => Promise<void>, value: string): Promise<void> {
    const revision: number = ++CookieStore.revision;
    CookieStore.mutations++;
    // 后来的读取不能复用写入开始前的在途结果。
    CookieStore.reading = undefined;
    const operation: Promise<void> = CookieStore.storageQueue.then(async (): Promise<void> => {
      try {
        await work();
        if (revision === CookieStore.revision) { CookieStore.cached = value; }
      } catch (e) {
        // 资产删除后写入/回退也可能失败，旧缓存已不能代表持久来源。
        CookieStore.cached = undefined;
        throw e as Error;
      }
    }).finally((): void => { CookieStore.mutations--; });
    CookieStore.storageQueue = operation.catch((): void => {});
    return operation;
  }

  /** 保存整串 Cookie（asset 优先，失败回退 prefs） */
  static save(raw: string): Promise<void> {
    if (raw.length === 0) { return CookieStore.clear(); }
    return CookieStore.mutate(async (): Promise<void> => {
      const ok: boolean = await AssetCookie.put(raw);
      if (ok) {
        // 成功入 asset 后清除旧明文
        await prefsDelete(KEY_COOKIE);
        return;
      }
      await prefsPut(KEY_COOKIE, raw);
    }, raw);
  }

  static getRaw(): Promise<string> {
    if (CookieStore.mutations === 0 && CookieStore.cached !== undefined) {
      return Promise.resolve(CookieStore.cached);
    }
    if (CookieStore.reading !== undefined) { return CookieStore.reading; }
    const revision: number = CookieStore.revision;
    const reading: Promise<string> = CookieStore.storageQueue.then(async (): Promise<string> => {
      // 等待中的保存/清除已经成功提交，无需再查询一次系统资产。
      if (revision === CookieStore.revision && CookieStore.cached !== undefined) { return CookieStore.cached; }
      const stored: StoredCookie = await CookieStore.readStored();
      if (revision === CookieStore.revision && stored.cacheable) { CookieStore.cached = stored.raw; }
      return stored.raw;
    }).finally((): void => {
      if (CookieStore.reading === reading) { CookieStore.reading = undefined; }
    });
    CookieStore.reading = reading;
    CookieStore.storageQueue = reading.then((): void => {}, (): void => {});
    return reading;
  }

  private static async readStored(): Promise<StoredCookie> {
    const fromAsset: string | undefined = await AssetCookie.get();
    if (fromAsset !== undefined && fromAsset.length > 0) { return { raw: fromAsset, cacheable: true }; }
    // 旧版明文迁移：首次读到即搬入 asset 并清除
    const legacy: string = await prefsGet(KEY_COOKIE, '');
    if (legacy.length > 0) {
      const ok: boolean = await AssetCookie.put(legacy);
      if (ok) {
        await prefsDelete(KEY_COOKIE);
      }
      return { raw: legacy, cacheable: ok || fromAsset !== undefined };
    }
    return { raw: '', cacheable: fromAsset !== undefined };
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

  static clear(): Promise<void> {
    return CookieStore.mutate(async (): Promise<void> => {
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
    }, '');
  }
}
