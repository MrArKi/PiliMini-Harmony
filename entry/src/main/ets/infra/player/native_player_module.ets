/** 只由MpvEngine.create动态导入，避免首次路由加载同步打开播放器SO。 */
import playerNative from 'libpilimini_player.so';
import type { NativePlayerEvent, NativePlayerSnapshot, NativePlayerStats } from 'libpilimini_player.so';

export interface NativePlayerApi {
  create: (surface: string, hardware: boolean, listener: (event: NativePlayerEvent) => void) => Promise<number>;
  load: (handle: number, video: string, audio: string, ua: string, position: number, paused: boolean) => void;
  command: (handle: number, args: string[]) => void;
  set: (handle: number, key: string, value: string) => void;
  snapshotAsync: (handle: number, diagnostics?: boolean) => Promise<NativePlayerSnapshot>;
  dispose: (handle: number) => Promise<void>;
  stats: () => NativePlayerStats;
}

export function getNativePlayer(): NativePlayerApi { return playerNative; }
