/** Nara布局/手势视图；单内核播放状态由PlayController管理。 */
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { AsyncImage } from '../AsyncImage';
import { PlayQuality } from '../../service/video_service';
import { prefsPut } from '../../infra/storage/prefs';
import { PlayController, PlaybackSnapshot, PlaybackSource } from '../../infra/player/play_controller';
import { PlayerScreen } from '../../infra/player/screen_awake';
import { VideoQuality } from '../../model/video_quality';
import { PlayerProgressBar } from './PlayerProgressBar';
import { PlayPauseIcon } from './PlayPauseIcon';

function two(n: number): string { const s: string = Math.floor(n).toString(); return s.length >= 2 ? s : '0' + s; }
function fmtMs(ms: number): string {
  if (ms <= 0) { return '00:00'; }
  const total: number = Math.floor(ms / 1000);
  const h: number = Math.floor(total / 3600), m: number = Math.floor((total % 3600) / 60), s: number = total % 60;
  return h > 0 ? h.toString() + ':' + two(m) + ':' + two(s) : two(m) + ':' + two(s);
}
const SPEEDS: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];
const LONG_PRESS_SPEED: number = 3;

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
  private exiting: boolean = false;

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
  private panStartX: number = 0;
  private curBright: number = 0.5;
  private curVolume: number = 1;
  private brightStart: number = 0.5;
  private volStart: number = 1;
  private fsTriggered: boolean = false;
  private mainWin: window.Window | undefined = undefined;
  private originalBrightness: number = -1;

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
      this.mainWin = win; this.originalBrightness = win.getWindowProperties().brightness;
      if (this.originalBrightness >= 0) { this.curBright = this.originalBrightness; }
      this.updateScreenOn();
    }).catch(() => {});
  }

  private receive(snapshot: PlaybackSnapshot): void {
    if (this.destroyed) { return; }
    const changed: boolean = this.state !== snapshot.state;
    this.state = snapshot.state; this.posMs = snapshot.position; this.durMs = snapshot.duration;
    this.speed = snapshot.speed; this.speedText = this.speed.toString() + 'X';
    this.qn = snapshot.quality; this.qualities = snapshot.qualities; this.bufferPercent = snapshot.bufferPercent;
    this.curVolume = snapshot.volume; this.wanted = snapshot.wanted; this.started = snapshot.loaded;
    this.errorText = snapshot.error; this.appInBackground = snapshot.background;
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
      this.routeSuspended = false; this.controller.resumeSource();
    } else if (this.settingsLoaded && this.autoPlay && (this.state === 'idle' || this.state === 'error')) { this.start(this.qn); }
  }

  private onVisibleChange(): void {
    if (this.destroyed || this.exiting || this.controller === undefined) { return; }
    const generation: number = ++this.visibilityGeneration;
    if (!this.visible) {
      if (!this.wanted) { this.capturePausedFrame(); }
      this.showPausedFrame = !this.wanted && this.pausedFrame !== undefined;
      this.routeSuspended = this.state !== 'idle'; this.ready = false;
      this.surfaceRelease = this.controller.suspend();
      this.surfaceRelease.then((): void => {
        if (!this.destroyed && !this.visible && generation === this.visibilityGeneration) { this.surfaceMounted = false; }
      });
      if (this.mainWin !== undefined) { this.mainWin.setWindowBrightness(this.originalBrightness).catch(() => {}); }
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
    if (this.destroyed || this.localPath.length > 0) { return; }
    this.actualRatio = 0; this.pausedFrame = undefined; this.showPausedFrame = false; this.controlsVisible = true;
    if (this.ready && this.settingsLoaded && this.visible) { this.start(this.qn, false); }
  }

  private onLocalSourceChange(): void {
    if (!this.localSource || this.destroyed) { return; }
    this.actualRatio = 0; this.pausedFrame = undefined; this.showPausedFrame = false; this.controlsVisible = true;
    if (this.ready && this.settingsLoaded && this.visible) { this.start(this.qn, false); }
  }

  private start(quality: number, preserve: boolean = true): void {
    if (this.controller === undefined || !this.controller.ready() || this.destroyed || !this.visible) { return; }
    if (preserve && !this.wanted) { this.capturePausedFrame(); this.showPausedFrame = this.pausedFrame !== undefined; }
    const source: PlaybackSource = this.localSource || { bvid: this.bvid, cid: this.cid, localPath: this.localPath,
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
      const source = this.localSource;
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
    this.toast = text;
    if (this.toastTimer !== -1) { clearTimeout(this.toastTimer); }
    this.toastTimer = setTimeout((): void => { this.toastTimer = -1; if (!this.destroyed) { this.toast = ''; } }, 1600);
  }
  private armControls(): void {
    if (this.controlTimer !== -1) { clearTimeout(this.controlTimer); }
    this.controlTimer = setTimeout((): void => {
      this.controlTimer = -1;
      if (!this.destroyed && this.state === 'playing' && !this.locked && !this.longPressActive && !this.panSeeking && this.seekPreviewMs < 0 &&
        !this.speedMenuVisible && !this.qualityMenuVisible) {
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
    if (this.mainWin !== undefined) {
      this.mainWin.setWindowBrightness(this.originalBrightness).catch(() => {});
      PlayerScreen.update(this.mainWin, this.surfaceBase, false);
    }
  }

  private onSingleTap(): void {
    if (!this.isFullscreen && this.collapseRatio > 0 && this.state !== 'playing') { this.togglePlay(); return; }
    if (this.locked) {
      return;
    }
    this.doSingleTap();
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
    if (this.locked) {
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
    if (this.locked) {
      return;
    }
    this.panMode = 'none';
    this.fsTriggered = false;
    this.panSeeking = false;
    this.panStartPos = this.posMs;
    this.panStartX = startX;
  }

  private onPanUpdate(dx: number, dy: number): void {
    if (this.locked) {
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
          this.panMode = 'bright';
          this.brightStart = this.curBright;
        } else if (this.panStartX < w * 2 / 3) {
          this.panMode = 'fs';
        } else {
          this.panMode = 'volume';
          this.volStart = this.curVolume;
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
      const v: number = Math.max(0, Math.min(this.volStart - dy / (h * 0.5), 1));
      this.applyVolume(v);
      this.showToast('音量 ' + Math.round(v * 100) + '%');
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
    this.curBright = v;
    const win: window.Window | undefined = this.mainWin;
    if (win !== undefined) {
      try {
        win.setWindowBrightness(v).catch(() => {
          // 忽略
        });
      } catch (e) {
        // 忽略
      }
    }
  }

  /** 应用内音量由单内核管理。 */
  private applyVolume(v: number): void {
    this.curVolume = v;
    if (this.controller !== undefined) { this.controller.volume(v); }
  }

  private onPanEnd(): void {
    if (this.panMode === 'seek' && this.panSeeking && this.seekPreviewMs >= 0) {
      this.seekTo(this.seekPreviewMs);
      this.showToast('已定位到 ' + fmtMs(this.seekPreviewMs));
    }
    if (this.panMode === 'volume') {
      prefsPut('setting_player_volume', this.curVolume.toString());
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
    .padding({ left: 10, right: 10, top: 12, bottom: 12 })
    .linearGradient({
      angle: 0,
      colors: [['#00000000', 0.0], ['#8A000000', 1.0]]
    })
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

      }
      .width('100%').height(this.canvasH())
      .scale({ x: this.canvasScale(), y: this.canvasScale() })
      .position({ left: 0, top: (this.viewportH() - this.canvasH()) / 2 })
      .hitTestBehavior(HitTestMode.None)

      // 画布独占手势；上层菜单、进度条与按钮保持独立命中。
      Column().width('100%').height('100%')
    .gesture(
      GestureGroup(GestureMode.Parallel,
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction(() => { this.onDoubleTap(); }),
          TapGesture({ count: 1 }).onAction(() => { this.onSingleTap(); })
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
    .onAreaChange((oldV: Area, newV: Area) => {
      // 手势分区与灵敏度按播放器实际尺寸计算
      this.playerW = Number(newV.width);
      this.playerH = Number(newV.height);
      this.areaWidth = this.playerW;
    })

  }
}
