import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { settings } from '@kit.BasicServicesKit';
import { onAppForeground } from '../event/app_events';

class BrightnessLease {
  win: window.Window;
  original: number;
  owner: string = '';
  dirty: boolean = false;
  restoring: boolean = false;
  constructor(win: window.Window, original: number) { this.win = win; this.original = original; }
}

/** 只调整当前主窗口；每个窗口的原始值和写入顺序在播放器间共享。 */
export class PlayerBrightness {
  private static nextOwner: number = 0;
  private static leases: Map<number, BrightnessLease> = new Map<number, BrightnessLease>();
  private static queue: Promise<void> = Promise.resolve();
  private static appBackground: boolean = false;
  private static offDeferred: (() => void) | undefined = undefined;
  private readonly owner: string = 'brightness_' + (++PlayerBrightness.nextOwner).toString();
  private win: window.Window | undefined = undefined;
  private ctx: common.UIAbilityContext | undefined = undefined;
  private windowId: number = -1;
  private displayId: number = 0;
  private lease: BrightnessLease | undefined = undefined;
  private visible: boolean = true;
  private background: boolean = false;
  private disposed: boolean = false;
  private subscribed: boolean = false;
  private writing: boolean = false;
  private pending: number | undefined = undefined;
  private value: number | undefined = undefined;
  private changed: (value: number | undefined, failed: boolean) => void;
  private readonly brightnessListener = (id: number, info: display.BrightnessInfo): void => {
    if (id === this.displayId && !this.writing) { this.sync(); }
  };

  constructor(changed: (value: number | undefined, failed: boolean) => void) { this.changed = changed; }

  initialize(win: window.Window, ctx: common.UIAbilityContext): void {
    if (this.disposed || this.win !== undefined) { return; }
    this.win = win; this.ctx = ctx;
    try {
      const properties: window.WindowProperties = win.getWindowProperties();
      this.windowId = properties.id;
      this.displayId = properties.displayId ?? display.getDefaultDisplaySync().id;
      this.acquire();
      if (this.visible && !this.owns()) { this.publish(undefined, true); return; }
    } catch (_) { this.publish(undefined, true); return; }
    try { display.on('brightnessInfoChange', this.brightnessListener); this.subscribed = true; }
    catch (_) { console.warn('[PiliMini-brightness] listener unavailable'); }
    this.sync();
  }

  private acquire(): void {
    if (this.win === undefined || this.disposed || !this.visible) { return; }
    let lease: BrightnessLease | undefined = PlayerBrightness.leases.get(this.windowId);
    if (lease === undefined) {
      const original: number = this.win.getWindowProperties().brightness;
      if (original !== -1 && (!Number.isFinite(original) || original < 0 || original > 1)) { return; }
      lease = new BrightnessLease(this.win, original);
      PlayerBrightness.leases.set(this.windowId, lease);
    }
    lease.owner = this.owner; this.lease = lease;
    PlayerBrightness.clearDeferredIfIdle();
  }

  private owns(): boolean {
    return this.lease !== undefined && this.lease.owner === this.owner;
  }
  private active(): boolean {
    return !this.disposed && this.visible && !this.background && !PlayerBrightness.appBackground && this.owns();
  }
  private publish(value: number | undefined, failed: boolean): void {
    if (this.disposed) { return; }
    this.value = value; this.changed(value, failed);
  }

  /** 无异步默认值或轮询；窗口为-1时才读取真实系统亮度。 */
  sync(): void {
    if (!this.active() || this.win === undefined || this.writing) { return; }
    try {
      const value: number = this.win.getWindowProperties().brightness;
      if (Number.isFinite(value) && value >= 0 && value <= 1) { this.publish(value, false); return; }
      const info: display.BrightnessInfo = display.getBrightnessInfo(this.displayId);
      const position: number | undefined = info.brightnessPosition;
      if (position !== undefined && Number.isFinite(position) && position >= 0 && position <= 1) {
        this.publish(position, false); return;
      }
    } catch (_) {}
    if (this.ctx !== undefined) {
      try {
        const raw: string = settings.getValueSync(this.ctx, settings.display.SCREEN_BRIGHTNESS_STATUS, '');
        const system: number = raw.length > 0 ? Number(raw) : -1;
        if (Number.isFinite(system) && system >= 0 && system <= 255) { this.publish(system / 255, false); return; }
      } catch (_) {}
    }
    this.publish(undefined, true);
  }

  /** 仅用户前台手势调用；高频目标合并为串行的最新一次窗口写入。 */
  apply(value: number): void {
    if (!this.active() || !Number.isFinite(value)) { return; }
    if (this.value === undefined) { this.sync(); if (this.value === undefined) { return; } }
    this.pending = Math.max(0, Math.min(1, value));
    if (this.writing) { return; }
    this.writing = true;
    const work: Promise<void> = PlayerBrightness.queue.then(async (): Promise<void> => {
      while (this.pending !== undefined && this.active() && this.win !== undefined && this.lease !== undefined) {
        const target: number = this.pending; this.pending = undefined;
        this.lease.dirty = true;
        try {
          await this.win.setWindowBrightness(target);
          if (this.active() && this.pending === undefined) { this.publish(target, false); }
        } catch (_) {
          this.pending = undefined;
          if (this.active()) { this.publish(this.value, true); }
          break;
        }
      }
      this.pending = undefined; this.writing = false;
    });
    PlayerBrightness.queue = work.catch((): void => { this.writing = false; this.pending = undefined; });
  }

  setVisible(visible: boolean): void {
    if (this.disposed || this.visible === visible) { return; }
    this.visible = visible; this.pending = undefined;
    if (!visible) { this.release(); }
    else { try { this.acquire(); this.sync(); } catch (_) { this.publish(undefined, true); } }
  }

  setBackground(background: boolean): void {
    if (this.disposed) { return; }
    if (this.background === background && PlayerBrightness.appBackground === background) { return; }
    this.background = background; PlayerBrightness.appBackground = background;
    if (background) { this.pending = undefined; }
    else {
      PlayerBrightness.restoreOrphans();
      this.sync();
    }
  }

  private release(): void {
    const lease: BrightnessLease | undefined = this.lease;
    if (lease === undefined || lease.owner !== this.owner) { return; }
    lease.owner = '';
    if (!lease.dirty) { PlayerBrightness.leases.delete(this.windowId); return; }
    if (!this.background && !PlayerBrightness.appBackground) { PlayerBrightness.restore(this.windowId, lease); }
    PlayerBrightness.watchDeferred();
  }

  private static restore(id: number, lease: BrightnessLease): void {
    if (lease.restoring) { return; }
    lease.restoring = true;
    const work: Promise<void> = PlayerBrightness.queue.then(async (): Promise<void> => {
      if (lease.owner.length > 0 || PlayerBrightness.appBackground || !lease.dirty) {
        lease.restoring = false; PlayerBrightness.clearDeferredIfIdle(); return;
      }
      try {
        await lease.win.setWindowBrightness(lease.original);
        lease.dirty = false;
        if (lease.owner.length === 0 && PlayerBrightness.leases.get(id) === lease) { PlayerBrightness.leases.delete(id); }
      } catch (_) { console.warn('[PiliMini-brightness] window restore deferred'); }
      lease.restoring = false;
      PlayerBrightness.clearDeferredIfIdle();
    });
    PlayerBrightness.queue = work.catch((): void => { lease.restoring = false; });
  }
  private static restoreOrphans(): void {
    PlayerBrightness.leases.forEach((lease: BrightnessLease, id: number): void => {
      if (lease.owner.length === 0 && lease.dirty) { PlayerBrightness.restore(id, lease); }
    });
  }
  private static watchDeferred(): void {
    if (PlayerBrightness.offDeferred !== undefined) { return; }
    PlayerBrightness.offDeferred = onAppForeground((): void => {
      PlayerBrightness.appBackground = false; PlayerBrightness.restoreOrphans();
      PlayerBrightness.clearDeferredIfIdle();
    });
  }
  private static clearDeferredIfIdle(): void {
    let orphan: boolean = false;
    PlayerBrightness.leases.forEach((lease: BrightnessLease): void => {
      if (lease.owner.length === 0 && lease.dirty) { orphan = true; }
    });
    if (!orphan && PlayerBrightness.offDeferred !== undefined) {
      PlayerBrightness.offDeferred(); PlayerBrightness.offDeferred = undefined;
    }
  }

  dispose(): void {
    if (this.disposed) { return; }
    this.pending = undefined; this.release();
    this.disposed = true;
    if (this.subscribed) { display.off('brightnessInfoChange', this.brightnessListener); this.subscribed = false; }
    this.ctx = undefined;
  }
}
