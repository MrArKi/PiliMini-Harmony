import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { buildGetHeaders, parseEnvelope, ensureOk } from './http';
import { AppError } from '../error/app_error';

/** 一次性、可取消的有界二进制GET。复用http.ets唯一凭据注入；本类不读Cookie。 */
export class BinaryRequest {
  private request: http.HttpRequest | undefined = undefined;
  private cancelled: boolean = false;
  private started: boolean = false;
  private finish: ((error: AppError) => void) | undefined = undefined;

  cancel(): void {
    if (this.cancelled) { return; }
    this.cancelled = true;
    const finish: ((error: AppError) => void) | undefined = this.finish;
    if (finish !== undefined) { finish(new AppError('network', -2, '弹幕请求已取消')); }
    else if (this.request !== undefined) {
      try { this.request.destroy(); } catch (_) {}
      this.request = undefined;
    }
  }

  async get(url: string, maxBytes: number): Promise<ArrayBuffer> {
    if (this.started || this.cancelled) { throw new AppError('network', -2, '弹幕请求已取消'); }
    if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0 || maxBytes > 2 * 1024 * 1024) {
      throw new AppError('parse', -1, '弹幕响应预算异常');
    }
    this.started = true;
    const headers: Record<string, string> = await buildGetHeaders();
    if (this.cancelled) { throw new AppError('network', -2, '弹幕请求已取消'); }
    const req: http.HttpRequest = http.createHttp();
    this.request = req;
    return new Promise<ArrayBuffer>((resolve: (value: ArrayBuffer) => void, reject: (error: AppError) => void): void => {
      let settled: boolean = false;
      let ended: boolean = false;
      let status: number = 0;
      let contentType: string = '';
      let total: number = 0;
      const chunks: Uint8Array[] = [];
      let timer: number = -1;
      const cleanup = (): void => {
        if (timer >= 0) { clearTimeout(timer); timer = -1; }
        this.finish = undefined;
        try { req.off('headersReceive'); } catch (_) {}
        try { req.off('dataReceive'); } catch (_) {}
        try { req.off('dataEnd'); } catch (_) {}
        try { req.destroy(); } catch (_) {}
        this.request = undefined; chunks.length = 0;
      };
      const fail = (error: AppError): void => {
        if (settled) { return; }
        settled = true; cleanup(); reject(error);
      };
      const complete = (): void => {
        if (settled || !ended || status === 0) { return; }
        if (status !== 200) { fail(new AppError('network', status, '弹幕接口暂不可用')); return; }
        const bytes: Uint8Array = new Uint8Array(total);
        let offset: number = 0;
        for (let i: number = 0; i < chunks.length; i++) { bytes.set(chunks[i], offset); offset += chunks[i].byteLength; }
        try {
          let first: number = 0;
          if (bytes.length >= 3 && bytes[0] === 239 && bytes[1] === 187 && bytes[2] === 191) { first = 3; }
          while (first < bytes.length && (bytes[first] === 32 || bytes[first] === 10 || bytes[first] === 13 || bytes[first] === 9)) { first++; }
          if (contentType.indexOf('json') >= 0 || (first < bytes.length && bytes[first] === 123)) {
            const text: string = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes).replace(/^\uFEFF/, '');
            ensureOk<Object>(parseEnvelope<Object>(text));
            fail(new AppError('parse', -1, '弹幕接口未返回二进制数据')); return;
          }
          if (total > 0 && contentType.length > 0 && contentType.indexOf('octet-stream') < 0 &&
            contentType.indexOf('protobuf') < 0) { fail(new AppError('parse', -1, '弹幕响应类型异常')); return; }
        } catch (error) {
          fail(error instanceof AppError ? error : new AppError('parse', -1, '弹幕响应无法解析')); return;
        }
        settled = true; cleanup(); resolve(bytes.buffer as ArrayBuffer);
      };
      this.finish = fail;
      timer = setTimeout((): void => { fail(new AppError('network', -1, '弹幕请求超时')); }, 20000);
      try {
        req.on('headersReceive', (value: Object): void => {
          if (settled) { return; }
          const record: Record<string, Object> = value as Record<string, Object>;
          const keys: string[] = Object.keys(record);
          for (let i: number = 0; i < keys.length; i++) {
            const name: string = keys[i].toLowerCase();
            const field: Object = record[keys[i]];
            if (typeof field !== 'string') { continue; }
            if (name === 'content-type') { contentType = (field as string).toLowerCase(); }
            if (name === 'content-length' && Number(field) > maxBytes) {
              fail(new AppError('parse', -1, '弹幕响应超过预算')); return;
            }
          }
        });
        req.on('dataReceive', (data: ArrayBuffer): void => {
          if (settled) { return; }
          if (total + data.byteLength > maxBytes) { fail(new AppError('parse', -1, '弹幕响应超过预算')); return; }
          total += data.byteLength;
          // 持有独立副本，避免原生回调缓冲后续复用影响已收片段；总量仍受硬预算约束。
          chunks.push(new Uint8Array(data).slice());
        });
        req.on('dataEnd', (): void => { ended = true; complete(); });
        req.requestInStream(url, { method: http.RequestMethod.GET, header: headers,
          usingCache: false, maxLimit: maxBytes, connectTimeout: 10000, readTimeout: 15000 })
          .then((code: number): void => { if (!settled) { status = code; complete(); } })
          .catch((): void => { fail(new AppError('network', -1, '弹幕请求失败')); });
      } catch (_) { fail(new AppError('network', -1, '弹幕请求失败')); }
    });
  }
}
