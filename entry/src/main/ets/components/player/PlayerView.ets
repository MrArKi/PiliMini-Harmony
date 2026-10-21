/** Nara布局/手势视图；单内核播放状态由PlayController管理。 */
import { common } from '@kit.AbilityKit';
import { window, uiMaterial } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { AVVolumePanel } from '@kit.AudioKit';
import { AsyncImage } from '../AsyncImage';
import { PlayQuality } from '../../service/video_service';
import { PlayController, PlaybackSnapshot, PlaybackSource } from '../../infra/player/play_controller';
import { PlayerScreen } from '../../infra/player/screen_awake';
import { PlayerBrightness } from '../../infra/player/player_brightness';
import { VideoQuality } from '../../model/video_quality';
import { PlayerProgressBar } from './PlayerProgressBar';
import { PlayPauseIcon } from './PlayPauseIcon';
import { DanmakuLayer } from './DanmakuLayer';
import { DanmakuPanel } from './DanmakuPanel';
import { DanmakuSelectionMenu } from './DanmakuSelectionMenu';
import { DanmakuItem } from '../../model/danmaku';
import { DanmakuPlaybackFeed, DanmakuLayerHandle } from '../../infra/danmaku/playback_feed';
import { DanmakuPreferences, copyDanmakuPreferences } from '../../infra/danmaku/settings';
import { DanmakuRule, DanmakuRuleStore } from '../../infra/danmaku/rules';

function two(n: number): string { const s: string = Math.floor(n).toString(); return s.length >= 2 ? s : '0' + s; }
function fmtMs(ms: number): string {
  if (ms <= 0) { return '00:00'; }
  const total: number = Math.floor(ms / 1000);
  const h: number = Math.floor(total / 3600), m: number = Math.floor((total % 3600) / 60), s: number = total % 60;
  return h > 0 ? h.toString() + ':' + two(m) + ':' + two(s) : two(m) + ':' + two(s);
}
const SPEEDS: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];
const LONG_PRESS_SPEED: number = 3;
interface DanmakuPopupState { isVisible: boolean; }

class PlayerSurfaceController extends XComponentController {
  created: (surface: string) => void = () => {};
  removed: () => void = () => {};
  resized: (rect: SurfaceRect) => void = () => {};
  onSurfaceCreated(surface: string): void { this.created(surface); }
  onSurfaceChanged(surface: string, rect: SurfaceRect): void { this.resized(rect); }
  onSurfaceDestroyed(surface: string): void { this.removed(); }
}

@Component
export struct PlayerView {
  @Prop bvid: string = '';
  @Prop @Watch('onVisibleChange') visible: boolean = true;
  @Prop @Watch('onCidChange') cid: number = 0;
  /** 选集跨BV/分P一次提交源，避免分别更新bvid/cid造成混合取流。 */
  @Prop @Watch('onPlaybackSourceChange') playbackSource: PlaybackSource | undefined = undefined;
  @Prop cover: string = '';
  @Prop sourceWidth: number = 0;
  @Prop sourceHeight: number = 0;
  onVideoSize: (w: number, h: number) => void = () => {};
  registerRelease: (release: () => Promise<void>) => void = () => {};
  @State actualRatio: number = 0;
  @Prop title: string = '';
  @Prop artist: string = '';
  @Prop partText: string = '';
  @Prop danmakuCount: number = 0;
  @Prop danmakuPreferences: DanmakuPreferences = new DanmakuPreferences();
  @Prop danmakuReady: boolean = false;
  onDanmakuChange: (value: DanmakuPreferences) => void = () => {};
  private danmakuFeed: DanmakuPlaybackFeed = new DanmakuPlaybackFeed();
  private danmakuHandle: DanmakuLayerHandle = new DanmakuLayerHandle();
  @State danmakuStatus: string = '';
  @State danmakuPanelShown: boolean = false;
  @State danmakuInitialTab: number = 0;
  @State nearbyDanmaku: DanmakuItem[] = [];
  @State selectedDanmaku: DanmakuItem | undefined = undefined;
  @State danmakuSelected: boolean = false;
  @State danmakuMenuX: number = 0;
  @State danmakuMenuY: number = 0;
  private danmakuActionBusy: boolean = false;
  private danmakuMenuMaterial: uiMaterial.ImmersiveMaterial | undefined = uiMaterial.isImmersiveMaterialSupported() &&
    uiMaterial.getGlobalMaterialLevel() !== uiMaterial.MaterialLevel.SMOOTH ?
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: '#B3000000', colorInvert: false, interactive: true, lightEffect: {} }) : undefined;
  @Prop isFullscreen: boolean = false;
  /** 进入即起播（详情页场景，用户决策 2026-10-11） */
  @Prop autoPlay: boolean = false;
  /** 本地文件路径（非空 = 离线播放：跳取流，直接播该文件；与在线播放同一套 UI/手势） */
  @Prop localPath: string = '';
  @Prop @Watch('onLocalSourceChange') localSource: PlaybackSource | undefined = undefined;
  @Prop localDuration: number = 0;
  @Prop offlineScope: string = 'all';
  @Prop offlineKey: string = '';
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  /** 详情页「继续播放」等外部控制：自增即触发一次播放（idle → 起播；paused → 续播） */
  @Prop @Watch('onResumeTick') resumeTick: number = 0;
  /** 详情页收窄比例（0~1）：>0 且非播放中时显示 56 高收窄条（Nara _buildOverlayToolBar） */
  @Prop collapseRatio: number = 0;
  /** 收窄条「回主页」回调（页面注入，Nara onCloseAll） */
  onGoHome: () => void = () => {
  };
  /** 播放状态回调（idle/loading/playing/paused/error），供详情页驱动收窄逻辑 */
  onStateChange: (state: string) => void = () => {
  };
  /** 每次状态变化时通知宿主 */
  private notifyState(): void {
    if (!this.destroyed) {
      this.onStateChange(this.state);
    }
  }

  private onResumeTick(): void {
    if (this.resumeTick <= 0 || this.destroyed) {
      return;
    }
    if (this.state !== 'playing' && this.state !== 'loading') {
      this.togglePlay();
    }
  }
  /** 返回（全屏时先退出全屏） */
  onExit: () => void = () => {
  };
  /** 切换全屏 */
  onToggleFullscreen: () => void = () => {
  };
  /** 播放器高度（由父组件控制：普通 = 16:9，全屏 = 100%） */
  @Prop viewHeight: string = '100%';
  /** Surface保留原尺寸，合成层按可见容器做contain缩放，复刻Nara动态头部约束。 */
  @Prop canvasHeight: number = 0;
  /** 宿主与全屏状态一起提交尺寸，视频不能比控制层晚一个onAreaChange。 */
  @Prop canvasWidth: number = 0;
  @Prop viewportHeight: number = 0;

  @State state: string = 'idle'; // idle | loading | playing | paused | error
  @State controlsVisible: boolean = true;
  @State posMs: number = 0;
  @State durMs: number = 0;
  @State speed: number = 1.0;
  @State speedText: string = '倍速';
  @State qn: number = 80;
  @State qualities: PlayQuality[] = [];
  @State qualityMenuVisible: boolean = false;
  @State speedMenuVisible: boolean = false;
  @State seekPreviewMs: number = -1;
  @State locked: boolean = false;
  @State toast: string = '';
  @State errorText: string = '';
  @State ready: boolean = false;
  @State surfaceMounted: boolean = true;
  private surfaceRelease: Promise<void> = Promise.resolve();
  private visibilityGeneration: number = 0;
  @State exiting: boolean = false;

  private controller: PlayController | undefined = undefined;
  private surfaceId: string = 'pm_surface_' + Date.now().toString();
  private surfaceBase: string = this.surfaceId;
  private surfaceGeneration: number = 0;
  private xcController: PlayerSurfaceController = new PlayerSurfaceController();
  @State pausedFrame: image.PixelMap | undefined = undefined;
  @State showPausedFrame: boolean = false;
  @State bufferPercent: number = 0;
  @State playerW: number = 360;
  @State playerH: number = 200;
  private destroyed: boolean = false;
  private started: boolean = false;
  private wanted: boolean = true;
  private settingsLoaded: boolean = false;
  private pendingAutoStart: boolean = false;
  private routeSuspended: boolean = false;
  private appInBackground: boolean = false;
  private toastTimer: number = -1;
  private controlTimer: number = -1;
  private longPressActive: boolean = false;
  private speedLocked: boolean = false;
  private speedBeforePress: number = 1;
  private panSeeking: boolean = false;
  private panStartPos: number = 0;
  private areaWidth: number = 360;
  private panMode: string = 'none';
  private panConsumed: boolean = false;
  private panStartX: number = 0;
  private curBright: number | undefined = undefined;
  private curVolume: number = 1;
  private brightStart: number = 0;
  private volumeTarget: number = 0;
  private volumeLastDy: number = 0;
  private volumeRequests: number[] = [];
  private systemVolumeReady: boolean = false;
  private systemVolumeMin: number = 0;
  private systemVolumeMax: number = 0;
  private systemVolumeRevision: number = -1;
  @State requestedSystemLevel: number = -1;
  private fsTriggered: boolean = false;
  private mainWin: window.Window | undefined = undefined;
  private brightnessControl: PlayerBrightness = new PlayerBrightness((value: number | undefined, failed: boolean): void => {
    if (this.destroyed) { return; }
    this.curBright = value;
    if (failed && this.visible && !this.appInBackground) { this.showToast('亮度调节暂不可用'); }
  });

  private videoRatio(): number {
    return this.actualRatio > 0 ? this.actualRatio :
      (this.sourceWidth > 0 && this.sourceHeight > 0 ? this.sourceWidth / this.sourceHeight : 16 / 9);
  }
  private canvasW(): number { return this.canvasWidth > 0 ? this.canvasWidth : this.playerW; }
  private canvasH(): number { return this.canvasHeight > 0 ? this.canvasHeight : this.playerH; }
  private surfaceWidth(): number { return Math.min(this.canvasW(), this.canvasH() * this.videoRatio()); }
  private surfaceHeight(): number { return Math.min(this.canvasH(), this.canvasW() / this.videoRatio()); }
  private viewportH(): number { return this.isFullscreen ? this.canvasH() : (this.viewportHeight > 0 ? this.viewportHeight : this.playerH); }
  private canvasScale(): number { return Math.min(1, this.viewportH() / Math.max(1, this.surfaceHeight())); }

  aboutToAppear(): void {
    this.controller = new PlayController(getContext(this) as common.UIAbilityContext,
      (snapshot: PlaybackSnapshot): void => { this.receive(snapshot); });
    this.registerRelease((): Promise<void> => {
      this.exiting = true; this.visibilityGeneration++;
      this.danmakuSelected = false; this.danmakuPanelShown = false;
      this.requestedSystemLevel = -1; this.brightnessControl.setVisible(false);
      if (this.controller === undefined) { return this.surfaceRelease; }
      this.ready = false;
      this.surfaceRelease = this.controller.suspend();
      return this.surfaceRelease;
    });
    this.xcController.created = (surface: string): void => { this.surfaceReady(surface); };
    this.xcController.resized = (rect: SurfaceRect): void => {
      if (!this.destroyed && this.controller !== undefined) { this.controller.resizeSurface(rect.surfaceWidth, rect.surfaceHeight); }
    };
    this.xcController.removed = (): void => {
      this.ready = false;
      if (!this.destroyed && this.visible && this.controller !== undefined) {
        this.routeSuspended = true; this.controller.suspend();
      }
    };
    this.controller.initialize().then((): void => {
      if (this.destroyed) { return; }
      this.settingsLoaded = true;
      if (this.ready && this.visible && this.autoPlay) { this.start(this.qn); }
    }).catch((): void => { if (!this.destroyed) { this.errorText = '播放器设置初始化失败'; this.state = 'error'; this.notifyState(); } });
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      if (this.destroyed) { return; }
      this.mainWin = win;
      this.brightnessControl.setVisible(this.visible); this.brightnessControl.setBackground(this.appInBackground);
      this.brightnessControl.initialize(win, getContext(this) as common.UIAbilityContext);
      this.updateScreenOn();
    }).catch(() => {});
  }

  private receive(snapshot: PlaybackSnapshot): void {
    if (this.destroyed) { return; }
    const changed: boolean = this.state !== snapshot.state;
    this.state = snapshot.state; this.posMs = snapshot.position; this.durMs = snapshot.duration;
    this.speed = snapshot.speed; this.speedText = this.speed.toString() + 'X';
    this.qn = snapshot.quality; this.qualities = snapshot.qualities; this.bufferPercent = snapshot.bufferPercent;
    this.wanted = snapshot.wanted; this.started = snapshot.loaded;
    this.errorText = snapshot.error; this.appInBackground = snapshot.background;
    this.brightnessControl.setBackground(snapshot.background);
    if (snapshot.background) { this.requestedSystemLevel = -1; this.volumeRequests = []; }
    this.receiveSystemVolume(snapshot);
    const source: PlaybackSource | undefined = this.playbackSource || this.localSource;
    this.danmakuFeed.publish({ cid: (source ? source.localPath : this.localPath).length > 0 ? 0 : (source ? source.cid : this.cid),
      duration: snapshot.duration, position: snapshot.position, speed: snapshot.speed,
      running: snapshot.state === 'playing' && snapshot.loaded && !snapshot.background && !snapshot.seeking,
      timeRevision: snapshot.timeRevision, sampledAt: snapshot.sampledAt, seeking: snapshot.seeking || !snapshot.loaded });
    if (snapshot.background) { this.danmakuPanelShown = false; this.danmakuSelected = false; }
    if (snapshot.width > 0 && snapshot.height > 0) {
      const ratio: number = snapshot.width / snapshot.height;
      if (Math.abs(ratio - this.actualRatio) > 0.0001) { this.actualRatio = ratio; this.onVideoSize(snapshot.width, snapshot.height); }
      if (snapshot.loaded && snapshot.state !== 'loading') { this.showPausedFrame = false; this.pausedFrame = undefined; }
    }
    this.syncSession(); this.updateScreenOn();
    if (changed) {
      if (this.state === 'playing') { this.armControls(); }
      else if (this.state === 'paused' || this.state === 'completed' || this.state === 'error') { this.controlsVisible = true; }
      this.notifyState();
    }
  }

  private surfaceReady(surface: string): void {
    if (this.destroyed || this.exiting || !this.visible || this.controller === undefined) { return; }
    this.ready = true; this.controller.resume(); this.controller.attachSurface(surface);
    const rect: SurfaceRect = this.xcController.getXComponentSurfaceRect();
    this.controller.resizeSurface(rect.surfaceWidth, rect.surfaceHeight);
    if (this.routeSuspended) {
      this.routeSuspended = false; this.start(this.qn);
    } else if (this.settingsLoaded && this.autoPlay && (this.state === 'idle' || this.state === 'error')) { this.start(this.qn); }
  }

  private onVisibleChange(): void {
    if (this.destroyed || this.exiting || this.controller === undefined) { return; }
    this.brightnessControl.setVisible(this.visible);
    const generation: number = ++this.visibilityGeneration;
    if (!this.visible) {
      this.requestedSystemLevel = -1; this.volumeRequests = [];
      this.danmakuPanelShown = false; this.danmakuSelected = false;
      if (!this.wanted) { this.capturePausedFrame(); }
      this.showPausedFrame = !this.wanted && this.pausedFrame !== undefined;
      this.routeSuspended = this.state !== 'idle'; this.ready = false;
      this.surfaceRelease = this.controller.suspend();
      this.surfaceRelease.then((): void => {
        if (!this.destroyed && !this.visible && generation === this.visibilityGeneration) { this.surfaceMounted = false; }
      });
    } else {
      this.surfaceRelease.then((): void => {
        if (this.destroyed || !this.visible || generation !== this.visibilityGeneration || this.controller === undefined) { return; }
        this.controller.resume();
        if (this.surfaceMounted) {
          this.surfaceReady(this.xcController.getXComponentSurfaceId());
        } else {
          this.surfaceId = this.surfaceBase + '_r' + (++this.surfaceGeneration).toString();
          this.surfaceMounted = true;
        }
      });
    }
    this.updateScreenOn();
  }

  onCidChange(): void {
    if (this.destroyed || this.localPath.length > 0 || this.playbackSource !== undefined) { return; }
    this.danmakuPanelShown = false; this.danmakuSelected = false;
    this.actualRatio = 0; this.pausedFrame = undefined; this.showPausedFrame = false; this.controlsVisible = true;
    if (this.ready && this.settingsLoaded && this.visible) { this.start(this.qn, false); }
  }

  private onLocalSourceChange(): void {
    if (!this.localSource || this.destroyed) { return; }
    this.danmakuSelected = false; this.danmakuPanelShown = false;
    this.actualRatio = 0; this.pausedFrame = undefined; this.showPausedFrame = false; this.controlsVisible = true;
    if (this.ready && this.settingsLoaded && this.visible) { this.start(this.qn, false); }
  }

  private onPlaybackSourceChange(): void {
    if (!this.playbackSource || this.destroyed) { return; }
    this.danmakuPanelShown = false; this.danmakuSelected = false;
    this.actualRatio = 0; this.pausedFrame = undefined; this.showPausedFrame = false; this.controlsVisible = true;
    if (this.ready && this.settingsLoaded && this.visible) { this.start(this.qn, false); }
  }

  private start(quality: number, preserve: boolean = true): void {
    if (this.controller === undefined || !this.controller.ready() || this.destroyed || !this.visible) { return; }
    if (preserve && !this.wanted) { this.capturePausedFrame(); this.showPausedFrame = this.pausedFrame !== undefined; }
    const source: PlaybackSource = this.playbackSource || this.localSource || { bvid: this.bvid, cid: this.cid, localPath: this.localPath,
      title: this.partText || this.title, artist: this.artist, cover: this.cover,
      localDuration: this.localDuration, offlineScope: this.offlineScope, offlineKey: this.offlineKey };
    this.controller.start(source, quality, preserve);
  }
  private togglePlay(): void {
    if (this.controller === undefined) { return; }
    if (this.state === 'idle' || this.state === 'error') { this.start(this.qn); return; }
    if (!this.wanted || this.state === 'completed') { this.pausedFrame = undefined; this.showPausedFrame = false; }
    this.controller.toggle();
  }
  private seekTo(ms: number): void { if (this.controller !== undefined) { this.controller.seek(ms); } }
  private applySpeed(value: number): void { if (this.controller !== undefined) { this.controller.speed(value); } }
  private syncSession(): void {
    if (this.controller !== undefined) {
      const source = this.playbackSource || this.localSource;
      this.controller.setMetadata(source ? source.title : this.partText || this.title,
        source ? source.artist : this.artist, source ? source.cover : this.cover);
    }
  }
  private updateScreenOn(): void {
    if (this.mainWin !== undefined) {
      const wanted: boolean = !this.destroyed && this.visible && !this.appInBackground && this.state === 'playing';
      PlayerScreen.update(this.mainWin, this.surfaceBase, wanted);
    }
  }
  private capturePausedFrame(): void {
    if (!this.started || !this.ready || this.destroyed) { return; }
    try {
      const frame: image.PixelMap = image.createPixelMapFromSurfaceSync(this.xcController.getXComponentSurfaceId());
      const info: image.ImageInfo = frame.getImageInfoSync();
      const scale: number = Math.min(1, 1280 / Math.max(info.size.width, info.size.height));
      if (scale < 1) { frame.scaleSync(scale, scale); }
      this.pausedFrame = frame;
    }
    catch (error) { this.pausedFrame = undefined; }
  }
  private showToast(text: string): void {
    if (!text.startsWith('音量 ')) { this.requestedSystemLevel = -1; }
    this.toast = text;
    if (this.toastTimer !== -1) { clearTimeout(this.toastTimer); }
    this.toastTimer = setTimeout((): void => {
      this.toastTimer = -1;
      if (!this.destroyed) { this.toast = ''; this.requestedSystemLevel = -1; }
    }, 1600);
  }
  private armControls(): void {
    if (this.controlTimer !== -1) { clearTimeout(this.controlTimer); }
    this.controlTimer = setTimeout((): void => {
      this.controlTimer = -1;
      if (!this.destroyed && this.state === 'playing' && !this.locked && !this.longPressActive && !this.panSeeking && this.seekPreviewMs < 0 &&
        !this.speedMenuVisible && !this.qualityMenuVisible && !this.danmakuPanelShown && !this.danmakuSelected) {
        this.controlsVisible = false;
      }
    }, 3000);
  }
  aboutToDisappear(): void {
    this.destroyed = true; this.pausedFrame = undefined; this.showPausedFrame = false;
    this.visibilityGeneration++;
    this.registerRelease((): Promise<void> => Promise.resolve());
    if (this.toastTimer !== -1) { clearTimeout(this.toastTimer); }
    if (this.controlTimer !== -1) { clearTimeout(this.controlTimer); }
    this.xcController.created = () => {}; this.xcController.removed = () => {}; this.xcController.resized = () => {};
    if (this.controller !== undefined) { this.controller.dispose(); this.controller = undefined; }
    this.danmakuFeed.clear();
    this.requestedSystemLevel = -1; this.brightnessControl.dispose();
    if (this.mainWin !== undefined) {
      PlayerScreen.update(this.mainWin, this.surfaceBase, false);
    }
  }

  private onSingleTap(event: GestureEvent): void {
    if (this.panConsumed) { return; }
    if (!this.isFullscreen && this.collapseRatio > 0 && this.state !== 'playing') { this.togglePlay(); return; }
    if (this.locked) {
      return;
    }
    if (this.danmakuReady && this.danmakuPreferences.enabled && this.collapseRatio <= 0 && event.fingerList.length > 0) {
      const finger: FingerInfo = event.fingerList[0];
      const scale: number = this.canvasScale();
      const x: number = (finger.localX - this.canvasW() / 2) / scale + this.surfaceWidth() / 2;
      const y: number = (finger.localY - this.viewportH() / 2) / scale + this.surfaceHeight() / 2;
      const item: DanmakuItem | undefined = this.danmakuHandle.hitTest(x, y);
      if (item !== undefined) {
        this.selectedDanmaku = item; this.danmakuMenuX = Math.max(8, Math.min(this.playerW - 8, finger.localX));
        this.danmakuMenuY = Math.max(8, Math.min(this.playerH - 8, finger.localY));
        this.danmakuSelected = true; return;
      }
    }
    this.doSingleTap();
  }

  private openDanmakuPanel(tab: number = 0): void {
    this.danmakuSelected = false; this.danmakuInitialTab = tab;
    this.nearbyDanmaku = this.danmakuHandle.nearby(); this.danmakuPanelShown = true;
  }

  private toggleDanmaku(): void {
    const value: DanmakuPreferences = copyDanmakuPreferences(this.danmakuPreferences);
    value.enabled = !value.enabled; this.onDanmakuChange(value); this.armControls();
  }

  private async copyDanmaku(item: DanmakuItem): Promise<void> {
    this.danmakuSelected = false;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.text));
      if (!this.destroyed) { this.showToast('已复制弹幕'); }
    } catch (_) { if (!this.destroyed) { this.showToast('复制失败，请重试'); } }
  }

  private async blockDanmakuSender(item: DanmakuItem): Promise<void> {
    if (this.danmakuActionBusy || item.midHash.length === 0) { return; }
    this.danmakuActionBusy = true;
    try {
      const rules: DanmakuRule[] = await DanmakuRuleStore.load();
      const existing: DanmakuRule | undefined = rules.find((rule: DanmakuRule): boolean =>
        rule.kind === 'sender' && rule.value === item.midHash.toLowerCase());
      if (existing === undefined) {
        await DanmakuRuleStore.save(DanmakuRuleStore.add(rules, 'sender', item.midHash));
      } else if (!existing.enabled) {
        await DanmakuRuleStore.save(DanmakuRuleStore.toggle(rules, existing.id));
      }
      if (!this.destroyed) {
        this.danmakuHandle.refreshRules(); this.danmakuSelected = false; this.showToast('已在本机屏蔽该发送者的弹幕');
      }
    } catch (error) { if (!this.destroyed) { this.showToast((error as Error).message || '屏蔽失败，请重试'); } }
    finally { this.danmakuActionBusy = false; }
  }

  @Builder
  DanmakuSelection() {
    WithTheme({ colorMode: ThemeColorMode.DARK }) {
      if (this.selectedDanmaku !== undefined) {
        DanmakuSelectionMenu({ item: this.selectedDanmaku,
          maxHeight: this.isFullscreen ? Math.min(400, Math.max(80, this.canvasH() - 64)) : 400,
          onClose: (): void => { this.danmakuSelected = false; },
          onCopy: (item: DanmakuItem): void => { this.copyDanmaku(item); },
          onHide: (item: DanmakuItem): void => {
            try {
              this.danmakuHandle.hide(item.key); this.danmakuSelected = false; this.showToast('已隐藏，可在弹幕设置恢复');
            } catch (error) { this.showToast((error as Error).message); }
          },
          onKeyword: (_item: DanmakuItem): void => { this.openDanmakuPanel(2); },
          onSender: (item: DanmakuItem): void => { this.blockDanmakuSender(item); }
        })
      }
    }
  }

  @Builder
  DanmakuCover() {
    Stack({ alignContent: this.isFullscreen && this.canvasW() > this.canvasH() ? Alignment.End : Alignment.Bottom }) {
      Column().width('100%').height('100%').backgroundColor('#55000000')
        .onClick((): void => { this.danmakuPanelShown = false; })
      DanmakuPanel({ preferences: this.danmakuPreferences,
        status: this.localPath.length > 0 ? '离线视频暂不支持弹幕' : this.danmakuStatus,
        nearby: this.nearbyDanmaku, initialTab: this.danmakuInitialTab,
        onChange: (value: DanmakuPreferences): void => { this.onDanmakuChange(value); },
        onClose: (): void => { this.danmakuPanelShown = false; this.armControls(); },
        onRetry: (): void => { this.danmakuHandle.retry(); this.nearbyDanmaku = this.danmakuHandle.nearby(); },
        onRefreshNearby: (): void => { this.nearbyDanmaku = this.danmakuHandle.nearby(); },
        onSelect: (item: DanmakuItem): void => {
          this.danmakuPanelShown = false; this.selectedDanmaku = item;
          this.danmakuMenuX = this.playerW / 2; this.danmakuMenuY = this.playerH / 2;
          this.danmakuSelected = true;
        },
        onRulesChanged: (): void => { this.danmakuHandle.refreshRules(); },
        onRestoreHidden: (): void => {
          this.danmakuHandle.restoreHidden(); this.nearbyDanmaku = this.danmakuHandle.nearby();
          this.showToast('已恢复本视频隐藏的弹幕');
        }
      }).width(this.isFullscreen && this.canvasW() > this.canvasH() ? '50%' : '100%')
        .height(this.isFullscreen && this.canvasW() > this.canvasH() ? '100%' : '70%').constraintSize({ maxWidth: 512 })
    }.width('100%').height('100%')
  }

  /** 双击由ArkUI互斥识别器优先处理，单击不再自行计时。 */
  private doSingleTap(): void {
    if (this.state === 'idle' || this.state === 'error') {
      this.start(this.qn);
      return;
    }
    this.controlsVisible = !this.controlsVisible;
    if (this.controlsVisible) { this.armControls(); }
  }

  private onDoubleTap(): void {
    if (this.locked || this.panConsumed) {
      return;
    }
    this.togglePlay();
    this.showToast(this.state === 'playing' ? '继续播放' : '已暂停');
  }

  private onLongPressStart(): void {
    if (this.locked || this.state === 'idle' || this.state === 'error') {
      return;
    }
    if (!this.speedLocked) { this.speedBeforePress = this.speed; }
    this.longPressActive = true;
    this.applySpeed(LONG_PRESS_SPEED);
    this.showToast('3x 倍速中（上滑锁定）');
  }

  private onLongPressEnd(): void {
    if (!this.longPressActive) {
      return;
    }
    this.longPressActive = false;
    if (this.speedLocked) {
      return;
    }
    this.applySpeed(this.speedBeforePress);
    this.showToast(`已恢复原速`);
  }

  private onPanStart(startX: number): void {
    if (this.locked || !this.visible || this.appInBackground || this.exiting) {
      return;
    }
    this.panMode = 'none';
    this.panConsumed = true;
    this.requestedSystemLevel = -1;
    this.fsTriggered = false;
    this.panSeeking = false;
    this.panStartPos = this.posMs;
    this.panStartX = startX;
    this.brightnessControl.sync();
    this.controller?.syncSystemVolume();
  }

  private onPanUpdate(dx: number, dy: number): void {
    if (this.locked || !this.visible || this.appInBackground || this.exiting) {
      return;
    }
    // 长按期间垂直滑动 → 锁定/解除锁定倍速
    if (this.longPressActive) {
      if (!this.speedLocked && dy < -40) {
        this.speedLocked = true;
        this.showToast('已锁定 3x 倍速（长按下滑退出）');
      } else if (this.speedLocked && dy > 40) {
        this.speedLocked = false;
        // 保持本次长按占有手势直到松手，避免剩余Pan误触发退出全屏。
        this.applySpeed(this.speedBeforePress);
        this.showToast('已退出倍速');
      }
      return;
    }
    if (this.state !== 'playing' && this.state !== 'paused') {
      return;
    }
    // 首次显著位移判定手势类型（Nara：横 > 3*竖 = seek；竖 > 3*横 = 三分区）
    if (this.panMode === 'none') {
      const adx: number = Math.abs(dx);
      const ady: number = Math.abs(dy);
      if (adx < 10 && ady < 10) {
        return;
      }
      if (adx > 3 * ady) {
        this.panMode = 'seek';
      } else if (ady > 3 * adx) {
        // 分区按按压起点 X：左 1/3 亮度 / 中 1/3 全屏 / 右 1/3 音量
        const w: number = this.playerW > 0 ? this.playerW : 360;
        if (this.panStartX < w / 3) {
          if (this.curBright === undefined) { this.showToast('暂时无法读取亮度'); return; }
          this.panMode = 'bright';
          this.brightStart = this.curBright;
        } else if (this.panStartX < w * 2 / 3) {
          this.panMode = 'fs';
        } else {
          if (!this.systemVolumeReady) { this.showToast('暂时无法读取系统音量'); return; }
          this.panMode = 'volume';
          this.volumeTarget = this.curVolume; this.volumeLastDy = 0; this.volumeRequests = [];
        }
      } else {
        return;
      }
    }

    if (this.panMode === 'seek') {
      this.panSeeking = true;
      if (this.durMs > 0) {
        const delta: number = dx / this.areaWidth * this.durMs;
        this.seekPreviewMs = Math.max(0, Math.min(this.panStartPos + delta, this.durMs - 1000));
      }
    } else if (this.panMode === 'bright') {
      const h: number = this.playerH > 0 ? this.playerH : 400;
      const v: number = Math.max(0, Math.min(this.brightStart - dy / (h * 3), 1));
      this.applyBrightness(v);
      this.showToast('亮度 ' + Math.round(v * 100) + '%');
    } else if (this.panMode === 'volume') {
      const h: number = this.playerH > 0 ? this.playerH : 400;
      const v: number = Math.max(0, Math.min(this.volumeTarget - (dy - this.volumeLastDy) / (h * 0.5), 1));
      this.volumeTarget = v; this.volumeLastDy = dy;
      this.applyVolume(v);
    } else if (this.panMode === 'fs') {
      // 中间上划进全屏 / 下滑退全屏（Nara 默认方向）
      if (!this.fsTriggered && dy < -15 && !this.isFullscreen) {
        this.fsTriggered = true;
        this.onToggleFullscreen();
      } else if (!this.fsTriggered && dy > 15 && this.isFullscreen) {
        this.fsTriggered = true;
        this.onToggleFullscreen();
      }
    }
  }

  /** 亮度：窗口级亮度（0~1，退出页面后恢复系统亮度） */
  private applyBrightness(v: number): void {
    this.brightnessControl.apply(v);
  }

  private receiveSystemVolume(snapshot: PlaybackSnapshot): void {
    if (snapshot.systemVolumeRevision === this.systemVolumeRevision) { return; }
    this.systemVolumeRevision = snapshot.systemVolumeRevision;
    this.systemVolumeReady = snapshot.systemVolumeReady;
    this.systemVolumeMin = snapshot.systemVolumeMin; this.systemVolumeMax = snapshot.systemVolumeMax;
    if (!this.systemVolumeReady) { this.requestedSystemLevel = -1; return; }
    this.curVolume = (snapshot.systemVolumeLevel - this.systemVolumeMin) / (this.systemVolumeMax - this.systemVolumeMin);
    const own: number = this.volumeRequests.indexOf(snapshot.systemVolumeLevel);
    if (own >= 0) { this.volumeRequests.splice(0, own + 1); }
    else if (this.panMode === 'volume') { this.volumeTarget = this.curVolume; this.volumeRequests = []; }
    if (snapshot.systemVolumeShowUi && this.visible && !this.appInBackground && !this.exiting) {
      if (this.panMode !== 'volume') { this.requestedSystemLevel = -1; }
      this.showToast('音量 ' + Math.round(this.curVolume * 100) + '%');
    }
  }

  /** 仅前台用户手势更新AVVolumePanel；普通快照不写系统音量。 */
  private applyVolume(v: number): void {
    if (!this.systemVolumeReady || !this.visible || this.appInBackground || this.exiting || this.panMode !== 'volume') { return; }
    const level: number = Math.round(this.systemVolumeMin + v * (this.systemVolumeMax - this.systemVolumeMin));
    this.showToast('音量 ' + Math.round((level - this.systemVolumeMin) / (this.systemVolumeMax - this.systemVolumeMin) * 100) + '%');
    if (this.requestedSystemLevel !== level) {
      this.volumeRequests.push(level);
      if (this.volumeRequests.length > 32) { this.volumeRequests.shift(); }
      this.requestedSystemLevel = level;
    }
  }

  private onPanEnd(): void {
    if (this.panMode === 'seek' && this.panSeeking && this.seekPreviewMs >= 0) {
      this.seekTo(this.seekPreviewMs);
      this.showToast('已定位到 ' + fmtMs(this.seekPreviewMs));
    }
    if (this.panMode === 'volume') {
      this.controller?.syncSystemVolume();
    }
    this.panMode = 'none';
    this.fsTriggered = false;
    this.panSeeking = false;
    this.seekPreviewMs = -1;
  }

  // ===== 控制层 =====
  @Builder
  LockOverlay() {
    Column() {
      Image($r('app.media.icon_lock'))
        .width(15)
        .height(15)
        .fillColor('#FFFFFF')
    }
    .width(34)
    .height(34)
    .borderRadius(8)
    .backgroundColor('#45000000')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.locked = false;
      this.controlsVisible = true;
    })
  }

  @Builder
  SpeedMenu() {
    Column() {
      ForEach(SPEEDS, (v: number) => {
        Text(v.toString() + 'X')
          .fontSize(13)
          .fontColor(this.speed === v ? $r('app.color.brand_pink') : '#FFFFFF')
          .width(80)
          .textAlign(TextAlign.Start)
          .height(35)
          .padding({ left: 15, right: 10 })
          .onClick(() => {
            this.speedMenuVisible = false;
            this.applySpeed(v);
          })
      }, (v: number) => 'sp_' + v.toString())
    }
    .width(80)
  }

  @Builder
  QualityMenu() {
    Column() {
      ForEach(this.qualities, (q: PlayQuality) => {
        Text(q.label)
          .fontSize(13)
          .fontColor(this.qn === q.qn ? $r('app.color.brand_pink') : '#FFFFFF')
          .width(96)
          .textAlign(TextAlign.Start)
          .height(35)
          .padding({ left: 15, right: 10 })
          .onClick(() => {
            this.qualityMenuVisible = false;
            if (q.qn !== this.qn) {
              this.showToast('切换到 ' + q.label);
              this.start(q.qn);
            }
          })
      }, (q: PlayQuality) => 'q_' + q.qn.toString())
    }
    .width(96)
  }

  @Builder
  TopBar() {
    Row({ space: 8 }) {
      Image($r('app.media.icon_arrow_left'))
        .width(20)
        .height(20)
        .fillColor('#FFFFFF')
        .onClick(() => {
          this.onExit();
        })
      Column({ space: 2 }) {
        Text(this.partText.length > 0 ? this.partText : this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .width('100%')
        if (this.localPath.length === 0) {
          Text(this.danmakuCount.toString() + '条弹幕')
            .fontSize(11)
            .fontColor('#CCFFFFFF')
        } else {
          Text('本地播放')
            .fontSize(11)
            .fontColor('#CCFFFFFF')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Row() {
        if (this.isFullscreen) {
          Button({ type: ButtonType.Normal }) {
            Image(this.danmakuPreferences.enabled ? $r('app.media.icon_dm_on') : $r('app.media.icon_dm_off'))
              .width(20).height(20).fillColor('#FFFFFF')
          }.width(40).height(34).padding(0).backgroundColor(Color.Transparent).enabled(this.danmakuReady)
            .id('danmaku_fullscreen_toggle')
            .accessibilityText(this.danmakuPreferences.enabled ? '关闭弹幕' : '开启弹幕')
            .onClick((): void => { this.toggleDanmaku(); })
        }
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.icon_dm_settings')).width(20).height(20).fillColor('#FFFFFF')
        }.width(40).height(34).padding(0).backgroundColor(Color.Transparent).enabled(this.danmakuReady)
          .id('danmaku_settings').accessibilityText('弹幕设置')
          .onClick((): void => { this.openDanmakuPanel(); })
      }

      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.icon_unlock')).width(15).height(15).fillColor('#FFFFFF')
      }.width(34).height(34).padding(0).borderRadius(8).backgroundColor('#45000000')
        .accessibilityText('锁定控制层')
        .onClick(() => {
          this.locked = true;
          this.showToast('已锁定控制层');
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .linearGradient({
      angle: 180,
      colors: [['#8A000000', 0.0], ['#00000000', 1.0]]
    })
  }

  @Builder
  BottomBar() {
    Column() {
      PlayerProgressBar({
        value: this.seekPreviewMs >= 0 ? this.seekPreviewMs : this.posMs,
        total: this.durMs, buffered: this.bufferPercent, canSeek: this.started,
        onPreview: (value: number): void => { this.seekPreviewMs = value; },
        onSeek: (value: number): void => {
          this.seekTo(value); this.seekPreviewMs = -1; this.syncSession(); this.armControls();
        }
      })
      .height(21)
      .width('100%')
      .padding({ left: 10, right: 10, bottom: 7 })

      Row({ space: 14 }) {
        Button({ type: ButtonType.Normal }) {
          PlayPauseIcon({ playing: this.state === 'playing' })
        }.width(42).height(34).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(this.wanted ? '暂停' : '播放')
          .onClick(() => { this.togglePlay(); })

        Text(fmtMs(this.seekPreviewMs >= 0 ? this.seekPreviewMs : this.posMs) + ' / ' + fmtMs(this.durMs))
          .fontSize(10).fontFamily('monospace')
          .fontColor('#FFFFFF')

        Blank()

        // 倍速
        Text(this.speedText)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .onClick(() => { this.speedMenuVisible = true; })
          .bindMenu(this.speedMenuVisible, this.SpeedMenu(), {
            backgroundColor: '#CC000000', backgroundBlurStyle: BlurStyle.NONE,
            onDisappear: () => {
              this.speedMenuVisible = false;
              if (!this.destroyed && this.state === 'playing') { this.armControls(); }
            }
          })

        // 清晰度（离线播放不支持切换）
        if (this.localPath.length === 0) {
          Text(this.qnLabel())
            .fontSize(13)
            .fontColor('#FFFFFF')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .onClick(() => { this.qualityMenuVisible = true; })
            .bindMenu(this.qualityMenuVisible, this.QualityMenu(), {
              backgroundColor: '#CC000000', backgroundBlurStyle: BlurStyle.NONE,
              onDisappear: () => {
                this.qualityMenuVisible = false;
                if (!this.destroyed && this.state === 'playing') { this.armControls(); }
              }
            })
        }

        // 全屏
        Button({ type: ButtonType.Normal }) {
          Image(this.isFullscreen ? $r('app.media.icon_fullscreen_exit') : $r('app.media.icon_fullscreen'))
            .width(24).height(24).fillColor('#FFFFFF')
        }.width(this.isFullscreen && this.playerW > this.playerH ? 42 : 35).height(30)
          .padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(this.isFullscreen ? '退出全屏' : '全屏')
          .onClick(() => { this.onToggleFullscreen(); })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
    .linearGradient({
      angle: 0,
      colors: [['#00000000', 0.0], ['#8A000000', 1.0]]
    })
  }

  /** Nara底缘轨道：3.5vp条中心位于底缘上0.3vp，裁去下侧1.45vp；不参与手势。 */
  @Builder
  EdgeProgress() {
    Stack({ alignContent: Alignment.TopStart }) {
      Rect().width('100%').height(3.5).radius(1.75).fill('#33FFFFFF')
        .hitTestBehavior(HitTestMode.None)
      Rect().width(Math.max(0, Math.min(100, this.bufferPercent)).toString() + '%')
        .height(3.5).radius(1.75).fill('#66FB7299').hitTestBehavior(HitTestMode.None)
      Rect().width((this.durMs > 0 ? Math.max(0, Math.min(100, this.posMs / this.durMs * 100)) : 0).toString() + '%')
        .height(3.5).radius(1.75).fill($r('app.color.brand_pink')).hitTestBehavior(HitTestMode.None)
    }
    .id('player-edge-progress')
    .width('100%').height(2.05)
    .clip(true)
    .position({ left: 0, bottom: 0 })
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }

  private qnLabel(): string {
    for (let i = 0; i < this.qualities.length; i++) {
      if (this.qualities[i].qn === this.qn) {
        return this.qualities[i].label;
      }
    }
    // 兜底：Nara 同款 qn→描述表（Bug1：原裸 "80P"）
    return VideoQuality.label(this.qn);
  }

  /** Nara图标15vp与42×34点击区分离；未实现设置菜单，按用户要求省略更多。 */
  @Builder
  CollapseBar() {
    Column() {

      Row() {
        // 左：返回 / 回主页（固定 92 宽）
        Row() {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.icon_arrow_left')).fillColor($r('app.color.text_primary')).width(15).height(15)
          }.width(42).height(34).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('返回').onClick(() => { this.onExit(); })
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.icon_home')).fillColor($r('app.color.text_primary')).width(15).height(15)
          }.width(42).height(34).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('返回主页').onClick(() => { this.onGoHome(); })
        }
        .width(92)
        .justifyContent(FlexAlign.Start)

        // 中：继续播放 / 重新播放（占比居中）
        Row({ space: 3 }) {
          Image(this.state === 'paused' ? $r('app.media.icon_play') : $r('app.media.icon_replay'))
            .width(18).height(18).fillColor($r('app.color.brand_pink'))
          Text(this.state === 'paused' ? '继续播放' : '重新播放')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand_pink'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        // 右：等宽空位保证中间居中。
        Blank().width(92)
      }
      .width('100%')
      .height(56)
      .padding({ left: 8, right: 8 })
    }
    .width('100%')
    .height('100%')
    .position({ left: 0, top: 0 })
    .backgroundColor($r('app.color.card_bg'))
    .opacity(this.collapseRatio)
    .onClick(() => { this.togglePlay(); })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // ① 视频面
      Stack({ alignContent: Alignment.Center }) {
        if (this.surfaceMounted) {
          XComponent({ id: this.surfaceId, type: XComponentType.SURFACE, controller: this.xcController })
            .id(this.surfaceId)
            .width(this.surfaceWidth())
            .height(this.surfaceHeight())
        }

        if (this.showPausedFrame && this.pausedFrame !== undefined && !this.wanted &&
          (this.state === 'paused' || this.state === 'loading')) {
          Image(this.pausedFrame)
            .width(this.surfaceWidth())
            .height(this.surfaceHeight())
            .objectFit(ImageFit.Contain)
            .hitTestBehavior(HitTestMode.None)
        }

        if (this.danmakuReady) {
          DanmakuLayer({ cid: this.playbackSource ? this.playbackSource.cid : (this.localPath.length > 0 ? 0 : this.cid),
            preferences: this.danmakuPreferences, fullscreen: this.isFullscreen,
            visible: this.visible && !this.exiting && (this.isFullscreen || this.collapseRatio < 1) &&
              this.localPath.length === 0,
            feed: this.danmakuFeed, handle: this.danmakuHandle,
            onStatus: (message: string): void => { if (!this.destroyed) { this.danmakuStatus = message; } }
          }).width(this.surfaceWidth()).height(this.surfaceHeight())
        }

      }
      .width('100%').height(this.canvasH())
      .scale({ x: this.canvasScale(), y: this.canvasScale() })
      .position({ left: 0, top: (this.viewportH() - this.canvasH()) / 2 })
      .hitTestBehavior(HitTestMode.None)

      // 画布独占手势；上层菜单、进度条与按钮保持独立命中。
      Column().width('100%').height('100%')
        .onTouch((event: TouchEvent): void => { if (event.type === TouchType.Down) { this.panConsumed = false; } })
    .gesture(
      GestureGroup(GestureMode.Parallel,
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction(() => { this.onDoubleTap(); }),
          TapGesture({ count: 1 }).onAction((event: GestureEvent): void => { this.onSingleTap(event); })
        ),
        LongPressGesture({ repeat: false, duration: 400 })
          .onAction(() => {
            this.onLongPressStart();
          })
          .onActionEnd(() => {
            this.onLongPressEnd();
          })
          .onActionCancel(() => { this.onLongPressEnd(); }),
        PanGesture({ direction: PanDirection.All, distance: 6 })
          .onActionStart((e: GestureEvent) => {
            const x: number = e.fingerList.length > 0 ? e.fingerList[0].localX : 0;
            this.onPanStart(x);
          })
          .onActionUpdate((e: GestureEvent) => {
            this.onPanUpdate(e.offsetX, e.offsetY);
          })
          .onActionEnd(() => {
            this.onPanEnd();
          })
          .onActionCancel(() => {
            this.onPanEnd();
          })
      )
    )
      WithTheme({ colorMode: ThemeColorMode.DARK }) {
        Column().width(1).height(1).position({ x: this.danmakuMenuX, y: this.danmakuMenuY })
          .bindPopup(this.danmakuSelected, { builder: this.DanmakuSelection, placement: Placement.Bottom,
            enableArrow: true, radius: 12, colorMode: AnchoredColorMode.FOLLOW_TARGET,
            popupColor: this.danmakuMenuMaterial !== undefined ? Color.Transparent : '#242424',
            backgroundBlurStyle: BlurStyle.NONE, systemMaterial: this.danmakuMenuMaterial,
            onStateChange: (event: DanmakuPopupState): void => {
              if (!event.isVisible) { this.danmakuSelected = false; this.armControls(); }
            } })
      }

      // ② 封面遮罩（未起播）
      if (this.state === 'idle') {
        Stack({ alignContent: Alignment.Center }) {
          AsyncImage({ src: this.cover, w: 640, h: 640, fit: ImageFit.Contain })
          Column() {
            Image($r('app.media.icon_play'))
              .width(30)
              .height(30)
              .fillColor('#FFFFFF')
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor('#66000000')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.start(this.qn);
        })
      }

      // ③ 加载 / 错误
      if (this.state === 'loading') {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color('#FFFFFF')
          Text('取流中…')
            .fontSize(12)
            .fontColor('#FFFFFF')
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
        .justifyContent(FlexAlign.Center)
      } else if (this.state === 'error') {
        Column({ space: 10 }) {
          Text('播放失败')
            .fontSize(14)
            .fontColor('#FFFFFF')
          Text(this.errorText)
            .fontSize(11)
            .fontColor('#DDDDDD')
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20 })
          Button('重试')
            .fontSize(13)
            .height(32)
            .backgroundColor($r('app.color.brand_pink'))
            .onClick(() => {
              this.start(this.qn);
            })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .justifyContent(FlexAlign.Center)
      }

      // ④ 控制层
      if (this.controlsVisible && !this.locked && this.state !== 'idle') {
        Column() {
          this.TopBar()
          Blank().hitTestBehavior(HitTestMode.None)
          this.BottomBar()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }

      // ⑤ 非全屏控件隐藏时，底缘只保留同一份播放快照的微进度。
      if (!this.isFullscreen && !this.controlsVisible && this.collapseRatio <= 0 &&
        this.state !== 'idle' && this.state !== 'error') {
        this.EdgeProgress()
      }

      // ⑥ 锁定态：仅保留锁按钮
      if (this.locked) {
        Column() {
          this.LockOverlay()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12 })
      }

      // ⑧ 收窄条（暂停 + 详情页上滑）：必须在播放器子树内（页面层覆盖层收不到表面触摸）
      if (!this.isFullscreen && this.collapseRatio > 0 && this.state !== 'playing' && this.state !== 'loading' && !this.locked) {
        this.CollapseBar()
      }

      // ⑦ toast / 拖动时间提示
      if (this.requestedSystemLevel >= 0 && this.toast.startsWith('音量 ') &&
        this.visible && !this.appInBackground && !this.exiting) {
        AVVolumePanel({ volumeLevel: this.requestedSystemLevel, volumeParameter: { position: { x: -1, y: -1 } } })
          .width(1).height(1).hitTestBehavior(HitTestMode.None)
      }
      if (this.toast.length > 0 || this.seekPreviewMs >= 0) {
        Text(this.seekPreviewMs >= 0
          ? (fmtMs(this.seekPreviewMs) + ' / ' + fmtMs(this.durMs))
          : this.toast)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#8A000000')
          .borderRadius(4)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      }
    }
    .width('100%')
    .height(this.viewHeight)
    .backgroundColor('#000000')
    .bindContentCover(this.danmakuPanelShown, this.DanmakuCover(), {
      modalTransition: ModalTransition.NONE, backgroundColor: Color.Transparent,
      onDisappear: (): void => { this.danmakuPanelShown = false; this.armControls(); }
    })
    .onAreaChange((oldV: Area, newV: Area) => {
      // 手势分区与灵敏度按播放器实际尺寸计算
      this.playerW = Number(newV.width);
      this.playerH = Number(newV.height);
      this.areaWidth = this.playerW;
    })

  }
}
