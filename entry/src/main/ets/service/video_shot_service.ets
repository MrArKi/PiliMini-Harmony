import { http } from '@kit.NetworkKit';
import { buildGetHeaders, ensureOk, parseEnvelope } from '../infra/http/http';
import { API_BASE, BILI_REFERER, UA_PC } from '../config/constants';
import { VideoShotData } from '../model/video_shot';
import { CookieStore } from '../infra/cookie/cookie_store';

interface VideoShotRaw {
  img_x_len?: number;
  img_y_len?: number;
  img_x_size?: number;
  img_y_size?: number;
  image?: string[];
  index?: number[];
}

/** 只取服务端快照；HTTP句柄由视图持有以便松手/换源/退页立即取消。 */
export class VideoShotService {
  static async load(bvid: string, cid: number, request: http.HttpRequest, isCurrent: () => boolean): Promise<VideoShotData> {
    const revision: number = CookieStore.sessionRevision();
    const extraHeaders: Record<string, string> = {};
    extraHeaders['Referer'] = 'https://www.bilibili.com/video/' + bvid;
    const headers: Record<string, string> = await buildGetHeaders(extraHeaders);
    if (!isCurrent() || revision !== CookieStore.sessionRevision()) { throw new Error('预览请求已失效'); }
    const response: http.HttpResponse = await request.request(API_BASE + '/x/player/videoshot?bvid=' +
      encodeURIComponent(bvid) + '&cid=' + cid.toString() + '&index=1', {
      method: http.RequestMethod.GET, header: headers, expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000, readTimeout: 8000, maxLimit: 512 * 1024, usingCache: false
    });
    // 旧账号/旧手势的迟到-101不能把当前账号退出。
    if (!isCurrent() || revision !== CookieStore.sessionRevision()) { throw new Error('预览请求已失效'); }
    if (response.responseCode !== 200 || typeof response.result !== 'string') { throw new Error('预览索引不可用'); }
    const envelope = parseEnvelope<VideoShotRaw>(response.result as string);
    ensureOk(envelope);
    const raw: VideoShotRaw | undefined = envelope.data;
    if (!raw || !raw.image || !raw.index || raw.image.length === 0 || raw.image.length > 256 ||
      raw.index.length === 0 || raw.index.length > 100000) { throw new Error('预览索引为空'); }
    const columns: number = raw.img_x_len || 0;
    const rows: number = raw.img_y_len || 0;
    if (!Number.isInteger(columns) || !Number.isInteger(rows) || columns <= 0 || rows <= 0 ||
      columns * rows > 1024) { throw new Error('预览网格无效'); }
    const images: string[] = [];
    for (let i: number = 0; i < raw.image.length; i++) {
      const original: string = raw.image[i];
      if (typeof original !== 'string') { throw new Error('预览图片地址无效'); }
      const url: string = original.startsWith('//') ? 'https:' + original : original.replace(/^http:/, 'https:');
      if (!/^https:\/\/[^/]+\.hdslb\.com\//i.test(url)) { throw new Error('预览图片域名无效'); }
      images.push(url);
    }
    for (let i: number = 0; i < raw.index.length; i++) {
      if (!Number.isFinite(raw.index[i]) || raw.index[i] < 0 || (i > 0 && raw.index[i] < raw.index[i - 1])) {
        throw new Error('预览时间索引无效');
      }
    }
    return { columns: columns, rows: rows, frameWidth: Math.max(0, raw.img_x_size || 0),
      frameHeight: Math.max(0, raw.img_y_size || 0), images: images, index: raw.index };
  }

  static async loadSheet(url: string, request: http.HttpRequest): Promise<ArrayBuffer> {
    const response: http.HttpResponse = await request.request(url, {
      method: http.RequestMethod.GET, header: { 'User-Agent': UA_PC, Referer: BILI_REFERER },
      expectDataType: http.HttpDataType.ARRAY_BUFFER, connectTimeout: 8000, readTimeout: 8000,
      maxLimit: 2 * 1024 * 1024, usingCache: false
    });
    if (response.responseCode !== 200 || typeof response.result === 'string') { throw new Error('预览图片不可用'); }
    const bytes: ArrayBuffer = response.result as ArrayBuffer;
    if (bytes.byteLength === 0 || bytes.byteLength > 2 * 1024 * 1024) { throw new Error('预览图片超出预算'); }
    return bytes;
  }
}
