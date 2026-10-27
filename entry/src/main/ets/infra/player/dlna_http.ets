import { connection, http, socket } from '@kit.NetworkKit';
import { util, url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DlnaXml } from './dlna_xml';

const MAX_BODY: number = 262144;
const MAX_HEADERS: number = 16384;

/** 固定业务错误，禁止将网络URL/响应原文放进日志或页面。 */
export class DlnaRequestError extends Error {
  code: number;
  constructor(code: number, message: string) { super(message); this.code = code; }
}

class LanEndpoint {
  protocol: string = '';
  host: string = '';
  authority: string = '';
  path: string = '';
  port: number = 0;
}

class HttpBody {
  code: number = 0;
  bytes: Uint8Array = new Uint8Array(0);
}

/** 无Cookie、无代理的UPnP专用HTTP；普通HTTP绑定发现时的Wi-Fi网络。 */
export class DlnaHttp {
  private closed: boolean = false;
  private cancels: (() => void)[] = [];

  close(): void {
    if (this.closed) { return; }
    this.closed = true;
    const pending: (() => void)[] = this.cancels.slice();
    for (let i: number = 0; i < pending.length; i++) { pending[i](); }
    this.cancels = [];
  }

  async request(address: string, body: string = '', soapAction: string = '', netId: number = 0): Promise<string> {
    if (this.closed) { throw new DlnaRequestError(-2, '投屏请求已取消'); }
    const target: LanEndpoint = this.endpoint(address);
    if (target.protocol === 'https:' && netId > 0) {
      // 系统HTTP不接受netId，不能在发现的Wi-Fi之外静默走VPN/默认路由。
      throw new DlnaRequestError(-5, '当前设备的加密投屏地址暂不支持');
    }
    const response: HttpBody = target.protocol === 'http:' ?
      await this.tcp(target, body, soapAction, netId) : await this.secure(address, body, soapAction);
    let text: string;
    try { text = util.TextDecoder.create('utf-8').decodeToString(response.bytes).replace(/^\uFEFF/, ''); }
    catch (_) { throw new DlnaRequestError(-4, '投屏设备响应无法解析'); }
    // SOAP Fault可在500或200响应里出现；只上送协议码，不传播接收端原始错误文本。
    let fault: number = 0;
    if (text.indexOf('errorCode') >= 0) {
      try { fault = Number(DlnaXml.value(text, 'errorCode')); } catch (_) {}
    }
    if (Number.isFinite(fault) && fault > 0) { throw new DlnaRequestError(fault, '投屏设备暂不支持该操作'); }
    if (response.code < 200 || response.code >= 300) {
      throw new DlnaRequestError(response.code, '投屏设备请求失败');
    }
    return text;
  }

  private endpoint(address: string): LanEndpoint {
    if (address.length > 4096 || /[\r\n\u0000]/.test(address)) { throw new DlnaRequestError(-4, '投屏设备地址无效'); }
    try {
      const parsed: url.URL = new url.URL(address);
      if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || parsed.username.length > 0 ||
        parsed.password.length > 0 || parsed.hostname.length === 0) { throw new Error('invalid'); }
      const target: LanEndpoint = new LanEndpoint();
      target.protocol = parsed.protocol; target.host = parsed.hostname;
      target.authority = parsed.host; target.path = (parsed.pathname || '/') + parsed.search;
      target.port = parsed.port.length > 0 ? Number(parsed.port) : (parsed.protocol === 'http:' ? 80 : 443);
      if (!Number.isInteger(target.port) || target.port < 1 || target.port > 65535) { throw new Error('invalid'); }
      return target;
    } catch (_) { throw new DlnaRequestError(-4, '投屏设备地址无效'); }
  }

  private unregister(cancel: () => void): void {
    const index: number = this.cancels.indexOf(cancel);
    if (index >= 0) { this.cancels.splice(index, 1); }
  }

  private tcp(target: LanEndpoint, body: string, action: string, netId: number): Promise<HttpBody> {
    return new Promise<HttpBody>((resolve: (response: HttpBody) => void,
      reject: (error: DlnaRequestError) => void): void => {
      const transport: socket.TCPSocket = socket.constructTCPSocketInstance();
      let settled: boolean = false;
      let received: Uint8Array = new Uint8Array(0);
      let timer: number = -1;
      let stage: number = 1;
      const cleanup = (): void => {
        clearTimeout(timer); this.unregister(cancel);
        try { transport.off('message'); transport.off('close'); transport.off('error'); } catch (_) {}
        try { transport.close().catch((): void => {}); } catch (_) {}
        received = new Uint8Array(0);
      };
      const fail = (error: DlnaRequestError): void => {
        if (settled) { return; } settled = true; cleanup(); reject(error);
      };
      const cancel = (): void => { fail(new DlnaRequestError(-2, '投屏请求已取消')); };
      const complete = (ended: boolean): void => {
        if (settled) { return; }
        try {
          const response: HttpBody | undefined = this.readResponse(received, ended);
          if (response === undefined) { return; }
          settled = true; cleanup(); resolve(response);
        } catch (error) {
          fail(error instanceof DlnaRequestError ? error : new DlnaRequestError(-4, '投屏设备响应无法解析'));
        }
      };
      this.cancels.push(cancel);
      timer = setTimeout((): void => { fail(new DlnaRequestError(-1, '投屏设备请求超时')); }, 8000);
      transport.on('message', (event: socket.SocketMessageInfo): void => {
        if (settled) { return; }
        if (received.length + event.message.byteLength > MAX_BODY + MAX_HEADERS) {
          fail(new DlnaRequestError(-4, '投屏设备响应超过限制')); return;
        }
        const merged: Uint8Array = new Uint8Array(received.length + event.message.byteLength);
        merged.set(received); merged.set(new Uint8Array(event.message), received.length); received = merged;
        complete(false);
      });
      transport.on('close', (): void => { complete(true); });
      transport.on('error', (error: BusinessError): void => {
        if (!settled) { this.traceFailure(stage, error); }
        fail(new DlnaRequestError(-3, '无法连接投屏设备'));
      });
      const send = async (): Promise<void> => {
        try {
          await transport.bind({ address: '0.0.0.0', family: 1, port: 0 });
          if (settled) { return; }
          if (netId > 0) {
            stage = 2;
            const nets: connection.NetHandle[] = await connection.getAllNets();
            if (settled) { return; }
            const net: connection.NetHandle | undefined = nets.find((item: connection.NetHandle): boolean => item.netId === netId);
            if (net === undefined) { throw new Error('network lost'); }
            stage = 3; await net.bindSocket(transport);
            if (settled) { return; }
          }
          stage = 4; await transport.connect({ address: { address: target.host, family: 1, port: target.port }, timeout: 4000 });
          if (settled) { return; }
          stage = 5;
          const payload: Uint8Array = body.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(body);
          if (payload.length > MAX_BODY || /[\r\n]/.test(action)) { throw new Error('invalid request'); }
          let head: string = (body.length > 0 ? 'POST ' : 'GET ') + target.path + ' HTTP/1.1\r\nHost: ' +
            target.authority + '\r\nConnection: close\r\nAccept: text/xml, application/xml, */*\r\nAccept-Encoding: identity\r\n';
          if (body.length > 0) {
            head += 'Content-Type: text/xml; charset="utf-8"\r\nContent-Length: ' + payload.length.toString() + '\r\n';
          }
          if (action.length > 0) { head += 'SOAPAction: "' + action + '"\r\n'; }
          stage = 6; const header: Uint8Array = new util.TextEncoder().encodeInto(head + '\r\n');
          const bytes: Uint8Array = new Uint8Array(header.length + payload.length);
          bytes.set(header); bytes.set(payload, header.length);
          stage = 7; await transport.send({ data: bytes.buffer as ArrayBuffer });
        } catch (error) {
          if (!settled) { this.traceFailure(stage, error as BusinessError); }
          fail(new DlnaRequestError(-3, '无法连接投屏设备'));
        }
      };
      send();
    });
  }

  private traceFailure(stage: number, error: BusinessError): void {
    const code: number = Number(error.code);
    hilog.warn(0x0000, 'PiliMini-DLNA', 'http stage=%{public}d code=%{public}d typeError=%{public}d',
      stage, Number.isFinite(code) ? code : 0, error instanceof TypeError ? 1 : 0);
  }

  private delimiter(bytes: Uint8Array, start: number, four: boolean): number {
    for (let i: number = start; i + (four ? 3 : 1) < bytes.length; i++) {
      if (bytes[i] === 13 && bytes[i + 1] === 10 && (!four || (bytes[i + 2] === 13 && bytes[i + 3] === 10))) { return i; }
    }
    return -1;
  }

  private readResponse(bytes: Uint8Array, ended: boolean): HttpBody | undefined {
    const boundary: number = this.delimiter(bytes, 0, true);
    if (boundary < 0) {
      if (bytes.length > MAX_HEADERS || ended) { throw new DlnaRequestError(-4, '投屏设备响应无法解析'); }
      return undefined;
    }
    if (boundary > MAX_HEADERS) { throw new DlnaRequestError(-4, '投屏设备响应超过限制'); }
    const header: string = util.TextDecoder.create('utf-8').decodeToString(bytes.subarray(0, boundary));
    const match: RegExpExecArray | null = /^HTTP\/1\.[01] ([0-9]{3})(?: |\r\n|$)/.exec(header);
    if (match === null) { throw new DlnaRequestError(-4, '投屏设备响应无法解析'); }
    const response: HttpBody = new HttpBody(); response.code = Number(match[1]);
    if (response.code === 204) { return response; }
    const encoding: RegExpExecArray | null = /^content-encoding[\t ]*:[\t ]*([^\r\n]*)$/im.exec(header);
    if (encoding !== null && encoding[1].trim().toLowerCase() !== 'identity') {
      throw new DlnaRequestError(-4, '投屏设备响应编码不支持');
    }
    const data: Uint8Array = bytes.subarray(boundary + 4);
    const transfer: RegExpExecArray | null = /^transfer-encoding\s*:\s*([^\r\n]+)$/im.exec(header);
    if (transfer !== null && transfer[1].trim().toLowerCase() !== 'chunked') {
      throw new DlnaRequestError(-4, '投屏设备响应编码不支持');
    }
    if (transfer !== null) {
      const decoded: Uint8Array | undefined = this.chunks(data);
      if (decoded === undefined) {
        if (ended) { throw new DlnaRequestError(-4, '投屏设备响应不完整'); }
        return undefined;
      }
      response.bytes = decoded; return response;
    }
    const length: RegExpExecArray | null = /^content-length\s*:\s*(\d+)\s*$/im.exec(header);
    if (length === null && /^content-length\s*:/im.test(header)) {
      throw new DlnaRequestError(-4, '投屏设备响应无法解析');
    }
    if (length !== null) {
      const count: number = Number(length[1]);
      if (!Number.isSafeInteger(count) || count > MAX_BODY) { throw new DlnaRequestError(-4, '投屏设备响应超过限制'); }
      if (data.length < count) {
        if (ended) { throw new DlnaRequestError(-4, '投屏设备响应不完整'); }
        return undefined;
      }
      response.bytes = data.slice(0, count); return response;
    }
    if (!ended) { return undefined; }
    if (data.length > MAX_BODY) { throw new DlnaRequestError(-4, '投屏设备响应超过限制'); }
    response.bytes = data.slice(); return response;
  }

  private chunks(bytes: Uint8Array): Uint8Array | undefined {
    let offset: number = 0; let total: number = 0;
    const parts: Uint8Array[] = [];
    while (offset < bytes.length) {
      const end: number = this.delimiter(bytes, offset, false);
      if (end < 0) { return undefined; }
      const line: string = util.TextDecoder.create('utf-8').decodeToString(bytes.subarray(offset, end));
      if (!/^[0-9a-fA-F]+(?:;[^\r\n]*)?$/.test(line)) { throw new DlnaRequestError(-4, '投屏设备响应无法解析'); }
      const size: number = parseInt(line.split(';')[0], 16); offset = end + 2;
      if (!Number.isSafeInteger(size) || total + size > MAX_BODY) { throw new DlnaRequestError(-4, '投屏设备响应超过限制'); }
      if (size === 0) {
        if (bytes.length < offset + 2) { return undefined; }
        // 最后零块后仍须有空行；带trailer时等到整段trailer结束才结算。
        if (!(bytes[offset] === 13 && bytes[offset + 1] === 10) && this.delimiter(bytes, offset, true) < 0) {
          return undefined;
        }
        const output: Uint8Array = new Uint8Array(total); let at: number = 0;
        for (let i: number = 0; i < parts.length; i++) { output.set(parts[i], at); at += parts[i].length; }
        return output;
      }
      if (bytes.length < offset + size + 2) { return undefined; }
      if (bytes[offset + size] !== 13 || bytes[offset + size + 1] !== 10) { throw new DlnaRequestError(-4, '投屏设备响应无法解析'); }
      parts.push(bytes.subarray(offset, offset + size)); total += size; offset += size + 2;
    }
    return undefined;
  }

  /** HTTPS描述兼容：系统TLS验证，不禁证书校验、不跟随重定向、不注入应用认证。 */
  private secure(address: string, body: string, action: string): Promise<HttpBody> {
    return new Promise<HttpBody>((resolve: (response: HttpBody) => void,
      reject: (error: DlnaRequestError) => void): void => {
      const request: http.HttpRequest = http.createHttp();
      let done: boolean = false; let timer: number = -1;
      const finish = (error: DlnaRequestError | undefined, response?: HttpBody): void => {
        if (done) { return; } done = true; clearTimeout(timer); this.unregister(cancel);
        try { request.destroy(); } catch (_) {}
        if (error !== undefined) { reject(error); } else if (response !== undefined) { resolve(response); }
      };
      const cancel = (): void => { finish(new DlnaRequestError(-2, '投屏请求已取消')); };
      this.cancels.push(cancel); timer = setTimeout((): void => { finish(new DlnaRequestError(-1, '投屏设备请求超时')); }, 8000);
      const headers: Record<string, string> = { 'Accept': 'text/xml, application/xml, */*', 'Accept-Encoding': 'identity' };
      if (body.length > 0) { headers['Content-Type'] = 'text/xml; charset="utf-8"'; }
      if (action.length > 0) { headers['SOAPAction'] = '"' + action + '"'; }
      request.request(address, { method: body.length > 0 ? http.RequestMethod.POST : http.RequestMethod.GET,
        extraData: body.length > 0 ? body : undefined, header: headers, usingProxy: false, usingCache: false,
        maxRedirects: 0, maxLimit: MAX_BODY, connectTimeout: 4000, readTimeout: 6000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER }).then((value: http.HttpResponse): void => {
          if (done) { return; }
          if (!(value.result instanceof ArrayBuffer) || value.result.byteLength > MAX_BODY) {
            finish(new DlnaRequestError(-4, '投屏设备响应超过限制')); return;
          }
          const response: HttpBody = new HttpBody(); response.code = value.responseCode;
          response.bytes = new Uint8Array(value.result); finish(undefined, response);
        }).catch((): void => { finish(new DlnaRequestError(-3, '无法连接投屏设备')); });
    });
  }
}
