import { prefsGet, prefsPut } from '../storage/prefs';
import { DanmakuOptions } from '../../model/danmaku';

const KEY: string = 'setting_danmaku_v1';
const MAX_SETTINGS_LENGTH: number = 2048;

/** 本机观看偏好；开关只随用户操作保存，加载失败不改写存储。 */
export class DanmakuPreferences {
  enabled: boolean = true;
  opacity: number = 1;
  fontSize: number = 15;
  area: number = 0.5;
  scrollSpeed: number = 1;
  /** 1稀疏 / 2标准 / 3较多，仍受内嵌30、全屏60的活动预算约束。 */
  density: number = 2;
  scroll: boolean = true;
  top: boolean = true;
  bottom: boolean = true;
  white: boolean = false;
}

function validNumber(value: number, low: number, high: number, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) && value >= low && value <= high ? value : fallback;
}

function validBoolean(value: boolean, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback;
}

/** 复制并逐字段校验；数值越界或类型不符使用该项默认值，不隐式转换。 */
export function copyDanmakuPreferences(source: DanmakuPreferences): DanmakuPreferences {
  const value: DanmakuPreferences = new DanmakuPreferences();
  if (source === undefined || source === null || typeof source !== 'object' || Array.isArray(source)) { return value; }
  value.enabled = validBoolean(source.enabled, true);
  value.opacity = validNumber(source.opacity, 0.2, 1, 1);
  const fontSize: number = validNumber(source.fontSize, 12, 24, 15);
  value.fontSize = Number.isInteger(fontSize) ? fontSize : 15;
  value.area = [0.25, 0.5, 0.75, 1].includes(source.area) ? source.area : 0.5;
  value.scrollSpeed = [0.5, 0.75, 1, 1.25, 1.5].includes(source.scrollSpeed) ? source.scrollSpeed : 1;
  value.density = [1, 2, 3].includes(source.density) ? source.density : 2;
  value.scroll = validBoolean(source.scroll, true);
  value.top = validBoolean(source.top, true);
  value.bottom = validBoolean(source.bottom, true);
  value.white = validBoolean(source.white, false);
  return value;
}

export function danmakuOptions(value: DanmakuPreferences, fullscreen: boolean): DanmakuOptions {
  const prefs: DanmakuPreferences = copyDanmakuPreferences(value);
  const options: DanmakuOptions = new DanmakuOptions();
  options.area = prefs.area;
  options.opacity = prefs.opacity;
  options.fontSize = prefs.fontSize * (fullscreen ? 1.2 : 1);
  // 样式速度只改变滚动持续时间；视频倍速由单调播放时钟计算一次。
  options.scrollDuration = 7000 / prefs.scrollSpeed;
  options.fixedDuration = 4000;
  options.scroll = prefs.scroll;
  options.top = prefs.top;
  options.bottom = prefs.bottom;
  options.white = prefs.white;
  options.maxActive = (fullscreen ? 60 : 30) * (prefs.density === 1 ? 0.5 : 1);
  options.perSecond = prefs.density === 1 ? 4 : (prefs.density === 3 ? 12 : 8);
  options.strokeWidth = 1.5;
  return options;
}

export class DanmakuSettings {
  private static writes: Promise<void> = Promise.resolve();

  /** 读取不写回，兼容原已保存的false；畸形根节点与字段回默认。 */
  static async load(): Promise<DanmakuPreferences> {
    await DanmakuSettings.writes;
    const raw: string = await prefsGet(KEY, '');
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > MAX_SETTINGS_LENGTH) { return new DanmakuPreferences(); }
    try {
      return copyDanmakuPreferences(JSON.parse(raw) as DanmakuPreferences);
    } catch (_) { return new DanmakuPreferences(); }
  }

  /** 调用时复制快照，串行flush；当前写入失败上抛，后续操作仍可保存。 */
  static save(value: DanmakuPreferences): Promise<void> {
    const encoded: string = JSON.stringify(copyDanmakuPreferences(value));
    const write: Promise<void> = DanmakuSettings.writes.then((): Promise<void> => prefsPut(KEY, encoded));
    DanmakuSettings.writes = write.catch((_error: Error): void => {});
    return write;
  }
}
