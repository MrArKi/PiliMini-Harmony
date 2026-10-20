export interface NativePlayerEvent { type: string; code: number; }
export interface NativePlayerSnapshot {
  position: number; duration: number; buffered: number;
  paused: boolean; buffering: boolean; seeking: boolean; ended: boolean; audioReady: boolean;
  width: number; height: number; videoEnabled: boolean; outputReady: boolean; decoder: string;
  avSyncMs: number; syncValid: boolean; cacheBytes: number; videoCodec: string;
}
export interface NativePlayerStats { instances: number; eventThreads: number; }
export const create: (surface: string, hardware: boolean, listener: (event: NativePlayerEvent) => void) => Promise<number>;
export const load: (handle: number, video: string, audio: string, ua: string, position: number, paused: boolean) => void;
export const command: (handle: number, args: string[]) => void;
export const set: (handle: number, key: string, value: string) => void;
export const snapshot: (handle: number, diagnostics?: boolean) => NativePlayerSnapshot;
export const dispose: (handle: number) => Promise<void>;
export const stats: () => NativePlayerStats;
