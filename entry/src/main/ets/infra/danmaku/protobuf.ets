import { util } from '@kit.ArkTS';
import { AppError } from '../error/app_error';
import { DanmakuItem, DanmakuSegment, DANMAKU_RESPONSE_MAX, DANMAKU_SEGMENT_MS,
  DANMAKU_SEGMENT_ITEMS, DANMAKU_SEGMENT_BYTES, danmakuPayloadBytes } from '../../model/danmaku';

const UTF8: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true });

/** 有界wire reader；64位ID用逐十进制运算保留，绝不转换成不精确number。 */
class ProtoReader {
  data: Uint8Array;
  pos: number;
  end: number;
  constructor(data: Uint8Array, start: number, end: number) {
    this.data = data; this.pos = start; this.end = end;
    if (start < 0 || end > data.length || start > end) { throw new AppError('parse', -1, '弹幕消息边界异常'); }
  }
  private byte(): number {
    if (this.pos >= this.end) { throw new AppError('parse', -1, '弹幕消息意外结束'); }
    return this.data[this.pos++];
  }
  number(): number {
    let value: number = 0, factor: number = 1;
    for (let i: number = 0; i < 10; i++) {
      const valueByte: number = this.byte();
      value += (valueByte % 128) * factor;
      if (!Number.isSafeInteger(value)) { throw new AppError('parse', -1, '弹幕数值超出范围'); }
      if (valueByte < 128) { return value; }
      factor *= 128;
    }
    throw new AppError('parse', -1, '弹幕varint过长');
  }
  decimal(): string {
    const digits: number[] = [0];
    const groups: number[] = [];
    for (let i: number = 0; i < 10; i++) {
      const value: number = this.byte();
      if (i === 9 && value > 1) { throw new AppError('parse', -1, '弹幕ID超出64位范围'); }
      groups.push(value % 128);
      if (value < 128) {
        for (let group: number = groups.length - 1; group >= 0; group--) {
          let carry: number = groups[group];
          for (let digit: number = 0; digit < digits.length; digit++) {
            const next: number = digits[digit] * 128 + carry;
            digits[digit] = next % 10; carry = Math.floor(next / 10);
          }
          while (carry > 0) { digits.push(carry % 10); carry = Math.floor(carry / 10); }
        }
        return digits.reverse().join('');
      }
    }
    throw new AppError('parse', -1, '弹幕ID varint过长');
  }
  private skipVarint(): void {
    for (let i: number = 0; i < 10; i++) {
      const value: number = this.byte();
      if (i === 9 && value > 1) { throw new AppError('parse', -1, '弹幕varint溢出'); }
      if (value < 128) { return; }
    }
    throw new AppError('parse', -1, '弹幕varint过长');
  }
  length(): number {
    const length: number = this.number();
    if (length > this.end - this.pos) { throw new AppError('parse', -1, '弹幕长度越界'); }
    return length;
  }
  sub(): ProtoReader {
    const length: number = this.length();
    const next: ProtoReader = new ProtoReader(this.data, this.pos, this.pos + length);
    this.pos += length; return next;
  }
  skip(wire: number): void {
    if (wire === 0) { this.skipVarint(); return; }
    if (wire === 1) { this.pos += 8; }
    else if (wire === 2) { const length: number = this.length(); this.pos += length; }
    else if (wire === 5) { this.pos += 4; }
    else { throw new AppError('parse', -1, '弹幕wire类型异常'); }
    if (this.pos > this.end) { throw new AppError('parse', -1, '弹幕字段越界'); }
  }
  text(maxBytes: number): string {
    const length: number = this.length();
    const start: number = this.pos; this.pos += length;
    if (length > maxBytes) { return ''; }
    return UTF8.decodeToString(this.data.subarray(start, start + length));
  }
}

function textKey(text: string): string {
  let hash: number = 2166136261;
  for (let i: number = 0; i < text.length; i++) { hash = Math.imul(hash ^ text.charCodeAt(i), 16777619); }
  return (hash >>> 0).toString(16);
}

function cleanText(raw: string): string {
  let text: string = raw.replace(/[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]/g, '').trim().substring(0, 200);
  if (text.length > 0) {
    const end: number = text.charCodeAt(text.length - 1);
    if (end >= 0xD800 && end <= 0xDBFF) { text = text.substring(0, text.length - 1); }
  }
  return text;
}

function decimalId(raw: string): string {
  if (!/^[0-9]{1,20}$/.test(raw)) { return ''; }
  const value: string = raw.replace(/^0+/, '');
  // protobuf字段为正int64；异常负值/溢出值不冒充可互动的dmid。
  if (value.length === 0 || value.length > 19 ||
    (value.length === 19 && value > '9223372036854775807')) { return ''; }
  return value;
}

function parseItem(reader: ProtoReader, segmentIndex: number): DanmakuItem | undefined {
  let time: number = 0, mode: number = 1, fontSize: number = 25, color: number = 16777215, weight: number = 0;
  let text: string = '', numericId: string = '', stringId: string = '', midHash: string = '';
  let fields: number = 0;
  while (reader.pos < reader.end) {
    const tag: number = reader.number(), field: number = Math.floor(tag / 8), wire: number = tag % 8;
    fields++;
    if (field === 0 || field > 536870911 || fields > 256) { throw new AppError('parse', -1, '弹幕字段标签或数量异常'); }
    if (field === 1) {
      if (wire !== 0) { throw new AppError('parse', -1, '弹幕ID wire异常'); }
      numericId = decimalId(reader.decimal());
    } else if (field === 2 || field === 3 || field === 4 || field === 5 || field === 9) {
      if (wire !== 0) { throw new AppError('parse', -1, '弹幕数值wire异常'); }
      const value: number = reader.number();
      if (field === 2) { time = value; }
      else if (field === 3) { mode = value; }
      else if (field === 4) { fontSize = value; }
      else if (field === 5) { color = value; }
      else { weight = value; }
    } else if (field === 6 || field === 7 || field === 12) {
      if (wire !== 2) { throw new AppError('parse', -1, '弹幕文本wire异常'); }
      const value: string = reader.text(field === 7 ? 800 : 64);
      if (field === 7) { text = cleanText(value); }
      else if (field === 12) { stringId = decimalId(value); }
      else if (/^[0-9a-fA-F]{1,16}$/.test(value)) { midHash = value.toLowerCase(); }
    } else { reader.skip(wire); }
  }
  if ((mode !== 1 && mode !== 4 && mode !== 5) || text.length === 0 ||
    time < (segmentIndex - 1) * DANMAKU_SEGMENT_MS || time >= segmentIndex * DANMAKU_SEGMENT_MS ||
    !Number.isFinite(time) || color < 0 || color > 0xFFFFFF) { return undefined; }
  // 双字段不一致时不暴露可互动ID，内部key仍允许稳定去重。
  const dmid: string = stringId.length > 0 && numericId.length > 0 && stringId !== numericId ? '' :
    (stringId.length > 0 ? stringId : numericId);
  const key: string = dmid.length > 0 ? dmid :
    time.toString() + ':' + mode.toString() + ':' + midHash + ':' + textKey(text);
  return { key: key, dmid: dmid, midHash: midHash, time: time, mode: mode, fontSize: Math.max(12, Math.min(36, fontSize)),
    color: color, text: text, weight: Math.max(0, Math.min(10, weight)) };
}

function yieldToUI(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
}

/** 两遍有界解析：先数消息，再均匀选记录；每128条让出UI，取消后不继续扫/排序。 */
export async function parseDanmakuSegment(data: ArrayBuffer, index: number,
  cancelled: () => boolean): Promise<DanmakuSegment> {
  if (data.byteLength > DANMAKU_RESPONSE_MAX || !Number.isSafeInteger(index) || index <= 0) {
    throw new AppError('parse', -1, '弹幕响应超过预算');
  }
  const bytes: Uint8Array = new Uint8Array(data);
  if (cancelled()) { throw new AppError('network', -2, '弹幕解析已取消'); }
  let reader: ProtoReader = new ProtoReader(bytes, 0, bytes.length);
  let count: number = 0, scanned: number = 0, closed: boolean = false;
  while (reader.pos < reader.end) {
    const tag: number = reader.number(), field: number = Math.floor(tag / 8), wire: number = tag % 8;
    if (field === 0 || field > 536870911) { throw new AppError('parse', -1, '弹幕字段标签异常'); }
    if ((field === 1 && wire !== 2) || (field === 2 && wire !== 0)) { throw new AppError('parse', -1, '弹幕消息wire异常'); }
    if (field === 1 && wire === 2) {
      reader.skip(wire); count++;
      if (count > 50000) { throw new AppError('parse', -1, '弹幕条目超过解析预算'); }
    } else if (field === 2 && wire === 0) { closed = reader.number() === 1; }
    else { reader.skip(wire); }
    scanned++;
    if (scanned % 128 === 0) { await yieldToUI(); if (cancelled()) { throw new AppError('network', -2, '弹幕解析已取消'); } }
  }
  if (cancelled()) { throw new AppError('network', -2, '弹幕解析已取消'); }
  let stride: number = Math.max(1, Math.ceil(count / DANMAKU_SEGMENT_ITEMS));
  const items: DanmakuItem[] = [];
  const ordinals: number[] = [];
  const keys: Set<string> = new Set<string>();
  let ordinal: number = 0, payload: number = 0, unsupported: number = 0, sampled: boolean = stride > 1;
  scanned = 0;
  reader = new ProtoReader(bytes, 0, bytes.length);
  while (reader.pos < reader.end) {
    const tag: number = reader.number(), field: number = Math.floor(tag / 8), wire: number = tag % 8;
    if (field === 1 && wire === 2) {
      const sub: ProtoReader = reader.sub();
      if (ordinal % stride === 0) {
        const item: DanmakuItem | undefined = parseItem(sub, index);
        if (item === undefined) { unsupported++; }
        else if (!keys.has(item.key)) {
          const size: number = danmakuPayloadBytes(item);
          // 字节预算触发时将整段采样步长翻倍，并同步抽稀已保留项，不能只截取段首。
          while (payload + size > DANMAKU_SEGMENT_BYTES && stride <= count) {
            stride *= 2; sampled = true;
            for (let i: number = items.length - 1; i >= 0; i--) {
              if (ordinals[i] % stride !== 0) {
                payload -= danmakuPayloadBytes(items[i]); keys.delete(items[i].key);
                items.splice(i, 1); ordinals.splice(i, 1);
              }
            }
          }
          if (ordinal % stride === 0) { items.push(item); ordinals.push(ordinal); keys.add(item.key); payload += size; }
        }
      }
      ordinal++;
    } else { reader.skip(wire); }
    scanned++;
    if (scanned % 128 === 0) { await yieldToUI(); if (cancelled()) { throw new AppError('network', -2, '弹幕解析已取消'); } }
  }
  if (cancelled()) { throw new AppError('network', -2, '弹幕解析已取消'); }
  items.sort((a: DanmakuItem, b: DanmakuItem): number => a.time - b.time || a.key.localeCompare(b.key));
  return { index: index, items: items, payloadBytes: payload, sourceCount: count,
    unsupportedCount: unsupported, sampled: sampled, closed: closed };
}
