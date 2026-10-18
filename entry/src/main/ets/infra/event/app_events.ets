/**
 * 全局事件（spec-01 任务 1.5）
 * 使用 @ohos.events.emitter：-101 触发 auth:logout；UI 监听后回登录页
 */
import { emitter } from '@kit.BasicServicesKit';

/** emitter 的 eventId 为数值；此处统一注册表 */
export const EVENT_AUTH_LOGOUT: number = 1001;
/** 应用进入后台（spec-06b：起长时任务 + 10s 后禁视频轨） */
export const EVENT_APP_BACKGROUND: number = 1002;
/** 应用回到前台（spec-06b：恢复视频轨） */
export const EVENT_APP_FOREGROUND: number = 1003;
/** 云端播放心跳成功；仅通知历史列表刷新，不携带账号或观看内容。 */
export const EVENT_HISTORY_CHANGED: number = 1004;

export function emitHistoryChanged(): void {
  emitter.emit({ eventId: EVENT_HISTORY_CHANGED });
}

export function onHistoryChanged(cb: () => void): () => void {
  emitter.on({ eventId: EVENT_HISTORY_CHANGED }, cb);
  return (): void => { emitter.off(EVENT_HISTORY_CHANGED, cb); };
}

export function emitAuthLogout(): void {
  const event: emitter.InnerEvent = {
    eventId: EVENT_AUTH_LOGOUT
  };
  emitter.emit(event);
}

/** 订阅登出事件，返回退订函数（组件 aboutToDisappear 必须调用，避免监听累积） */
export function onAuthLogout(cb: () => void): () => void {
  const event: emitter.InnerEvent = {
    eventId: EVENT_AUTH_LOGOUT
  };
  emitter.on(event, cb);
  return (): void => {
    emitter.off(EVENT_AUTH_LOGOUT, cb);
  };
}

export function emitAppBackground(): void {
  emitter.emit({ eventId: EVENT_APP_BACKGROUND });
}

export function emitAppForeground(): void {
  emitter.emit({ eventId: EVENT_APP_FOREGROUND });
}

/** 订阅进入后台，返回退订函数 */
export function onAppBackground(cb: () => void): () => void {
  emitter.on({ eventId: EVENT_APP_BACKGROUND }, cb);
  return (): void => {
    emitter.off(EVENT_APP_BACKGROUND, cb);
  };
}

/** 订阅回到前台，返回退订函数 */
export function onAppForeground(cb: () => void): () => void {
  emitter.on({ eventId: EVENT_APP_FOREGROUND }, cb);
  return (): void => {
    emitter.off(EVENT_APP_FOREGROUND, cb);
  };
}
