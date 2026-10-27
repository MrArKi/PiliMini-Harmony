/**
 * 网络类型判定（P2-1 仅 Wi-Fi 下载保护）
 * 只读 getDefaultNet + getNetCapabilities，不注册监听，避免常驻开销。
 * 查询失败一律按 other 处理：宁可放行，也不误拦用户。
 */
import { connection } from '@kit.NetworkKit';
import { prefsGet } from '../storage/prefs';

export enum NetKind {
  none = 0,
  /** Wi-Fi 与以太网都按不计流量处理 */
  wifi = 1,
  cellular = 2,
  other = 3
}

export const WIFI_ONLY_KEY: string = 'setting_wifi_only';

export async function currentNetKind(): Promise<NetKind> {
  try {
    const net: connection.NetHandle = await connection.getDefaultNet();
    if (net === undefined || net === null || net.netId === 0) {
      return NetKind.none;
    }
    const caps: connection.NetCapabilities = await connection.getNetCapabilities(net);
    const types: connection.NetBearType[] = caps.bearerTypes;
    if (types.indexOf(connection.NetBearType.BEARER_WIFI) >= 0) {
      return NetKind.wifi;
    }
    if (types.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0) {
      return NetKind.wifi;
    }
    if (types.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0) {
      return NetKind.cellular;
    }
    return NetKind.other;
  } catch (e) {
    return NetKind.other;
  }
}

/** 开关打开且当前走蜂窝时才拦；默认开（新功能按保护性默认）。 */
export async function blockedByWifiOnly(): Promise<boolean> {
  const raw: string = await prefsGet(WIFI_ONLY_KEY, '1');
  if (raw === '0') {
    return false;
  }
  return (await currentNetKind()) === NetKind.cellular;
}
