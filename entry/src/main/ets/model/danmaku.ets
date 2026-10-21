/** 普通弹幕观看数据；内容、dmid与发送者hash只保留在有界内存，不写弹幕磁盘缓存。 */
export interface DanmakuItem {
  /** 仅作本段去重/排轨身份；无可靠dmid时可使用派生key，不能用它调用账号API。 */
  key: string;
  /** protobuf int64/id_str的精确十进制字符串；缺失/非正值为''，绝不转换为number。 */
  dmid: string;
  /** 发送者CRC32标识，不是UID；仅用于本机弹幕屏蔽。 */
  midHash: string;
  time: number;
  mode: number;
  fontSize: number;
  color: number;
  text: string;
  weight: number;
}

export interface DanmakuSegment {
  index: number;
  items: DanmakuItem[];
  /** 精简负载估算，不代表ArkTS实际堆。 */
  payloadBytes: number;
  sourceCount: number;
  unsupportedCount: number;
  sampled: boolean;
  closed: boolean;
}

export class DanmakuOptions {
  area: number = 0.5;
  opacity: number = 1;
  fontSize: number = 15;
  scrollDuration: number = 7000;
  fixedDuration: number = 4000;
  scroll: boolean = true;
  top: boolean = true;
  bottom: boolean = true;
  white: boolean = false;
  maxActive: number = 30;
  /** 每视频秒最多投放量；拒绝的条目不排队补发。 */
  perSecond: number = 8;
  strokeWidth: number = 1.5;
  lineHeight: number = 1.6;
}

export type DanmakuStreamState = 'idle' | 'loading' | 'ready' | 'empty' | 'closed' | 'error';

export interface DanmakuStreamStats {
  segments: number;
  items: number;
  payloadBytes: number;
  activeRequests: number;
  failedSegments: number;
  sampledSegments: number;
}

export interface ActiveDanmaku {
  item: DanmakuItem;
  start: number;
  end: number;
  lane: number;
  x: number;
  y: number;
  width: number;
  fontSize: number;
  velocity: number;
}

export const DANMAKU_SEGMENT_MS: number = 360000;
export const DANMAKU_PREFETCH_MS: number = 30000;
export const DANMAKU_RESPONSE_MAX: number = 2 * 1024 * 1024;
export const DANMAKU_CACHE_MAX: number = 4 * 1024 * 1024;
export const DANMAKU_SEGMENT_ITEMS: number = 4000;
export const DANMAKU_SEGMENT_BYTES: number = Math.floor(DANMAKU_CACHE_MAX / 3);

export function danmakuPayloadBytes(item: DanmakuItem): number {
  return 80 + (item.text.length + item.key.length + item.dmid.length + item.midHash.length) * 2;
}
