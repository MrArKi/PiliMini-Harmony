import { common } from '@kit.AbilityKit';
import systemDateTime from '@ohos.systemDateTime';
import { audio } from '@kit.AudioKit';
import type { NativePlayerEvent, NativePlayerSnapshot } from 'libpilimini_player.so';
import { MpvEngine } from './mpv_engine';
import { BgAudio } from './audio_mode';
import { DlnaCastSession } from './dlna_session';
import { DlnaDiscovery } from './dlna_discovery';
import { CastSnapshot, DlnaDevice, DlnaMedia } from '../../model/cast';
import { PlaybackHistory } from './playback_history';
import { VideoService, PlayInfo, PlayQuality, CastUrl } from '../../service/video_service';
import { AuthService } from '../../service/auth_service';
import { PlaybackPos } from '../storage/playback_pos';
import { prefsGet } from '../storage/prefs';
import { onAppBackground, onAppForeground, onAuthLogout } from '../event/app_events';
import { CookieStore } from '../cookie/cookie_store';
import { DownloadLibraryService } from '../../service/download_library_service';

export interface PlaybackSource {
  bvid: string; cid: number; localPath: string;
  /** DASH 双文件：独立音频路径（空=单文件 MP4）。 */
  localAudioPath?: string;
  title: string; artist: string; cover: string;
  localDuration?: number;
  offlineScope?: string;
  offlineKey?: string;
}

export class PlaybackSnapshot {
  cast: CastSnapshot = new CastSnapshot();
  state: string = 'idle';
  position: number = 0;
  /** 与position同次采样的ACTIVE单调毫秒，供画面弹幕插值，不增加原生轮询。 */
  sampledAt: number = 0;
  timeRevision: number = 0;
  seeking: boolean = false;
  duration: number = 0;
  speed: number = 1;
  /** 内核增益恒1；界面音量为系统媒体级别，避免双重衰减。 */
  volume: number = 1;
  systemVolumeReady: boolean = false;
  systemVolumeLevel: number = 0;
  systemVolumeMin: number = 0;
  systemVolumeMax: number = 0;
  systemVolumeRevision: number = 0;
  systemVolumeShowUi: boolean = false;
  quality: number = 80;
  qualities: PlayQuality[] = [];
  bufferPercent: number = 0;
  width: number = 0;
  height: number = 0;
  wanted: boolean = true;
  loaded: boolean = false;
  audioOnly: boolean = false;
  background: boolean = false;
  error: string = '';
}

/** 播放源、内核、会话、后台与进度的唯一所有者；UI不参与音画同步。 */
export class PlayController {
  // 路由切换时不同视图也共享释放顺序，避免旧音频尚在退出就创建新输出。
  private static kernelQueue: Promise<void> = Promise.resolve();
  // AudioSession是应用级单例；旧页的迟到停用不能抢走新页已取得的焦点。
  private static focusQueue: Promise<void> = Promise.resolve();
  private static focusOwner: string = '';
  readonly state: PlaybackSnapshot = new PlaybackSnapshot();
  private readonly owner: string = 'mpv_' + Date.now().toString() + '_' + Math.random().toString(36).slice(2);
  private engine: MpvEngine | undefined = undefined;
  private source: PlaybackSource | undefined = undefined;
  private history: PlaybackHistory | undefined = undefined;
  private info: PlayInfo | undefined = undefined;
  private surface: string = '';
  private surfaceW: number = 0;
  private surfaceH: number = 0;
  private generation: number = 0;
  private nativeQueue: Promise<void> = Promise.resolve();
  private disposed: boolean = false;
  private visible: boolean = true;
  private background: boolean = false;
  private initialized: boolean = false;
  private initialization: Promise<void> | undefined = undefined;
  private focusSubscribed: boolean = false;
  private deviceSubscribed: boolean = false;
  private volumeSubscribed: boolean = false;
  private hardware: boolean = true;
  private p1080: boolean = true;
  private timer: number = -1;
  private refreshInFlight: boolean = false;
  private refreshAgain: boolean = false;
  private refreshRevision: number = 0;
  private backgroundTimer: number = -1;
  private restoreTimer: number = -1;
  private restoring: boolean = false;
  private restoreAttempt: number = 0;
  private prepareAt: number = 0;
  private audioMissingAt: number = 0;
  private lastSessionAt: number = 0;
  private lastDiagnosticAt: number = 0;
  private lastSaved: number = 0;
  private lastSavedAt: number = 0;
  private videoBackup: number = 0;
  private audioBackup: number = 0;
  private refreshed: boolean = false;
  private focusPausedGeneration: number = -1;
  private focusRevision: number = 0;
  private focusActivatedRevision: number = -1;
  private pendingSeek: number = -1;
  private seekStarted: boolean = false;
  private pendingEnd: boolean = false;
  private seekAt: number = 0;
  private focusManager: audio.AudioSessionManager = audio.getAudioManager().getSessionManager();
  private routing: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
  private volumeManager: audio.AudioVolumeManager = audio.getAudioManager().getVolumeManager();
  private offBg: (() => void) | undefined = undefined;
  private offFg: (() => void) | undefined = undefined;
  private offLogout: (() => void) | undefined = undefined;
  private castSession: DlnaCastSession | undefined = undefined;
  private castCleanupSession: DlnaCastSession | undefined = undefined;
  private castDiscovery: DlnaDiscovery | undefined = undefined;
  private castMedia: DlnaMedia | undefined = undefined;
  private castGeneration: number = 0;
  private startRequest: number = 0;
  private castRevision: number = -1;
  private castHeld: boolean = false;
  private castPanelVisible: boolean = false;
  private readonly focusListener = (event: audio.AudioSessionStateChangedEvent): void => {
    if (this.castHeld || this.disposed || !this.visible || this.source === undefined || PlayController.focusOwner !== this.owner) { return; }
    const hint: audio.AudioSessionStateChangeHint = event.stateChangeHint;
    console.info('[PiliMini-focus] hint=' + hint.toString() + ' wanted=' + this.state.wanted.toString());
    if (hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE) {
      // 重复PAUSE不能用已经暂停的wanted覆盖第一次保存的恢复资格。
      if (this.state.wanted && this.state.state !== 'completed' && this.state.state !== 'error') {
        this.focusPausedGeneration = this.generation;
      }
      this.setWanted(false, false);
    } else if (hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_RESUME) {
      const resume: boolean = this.focusPausedGeneration === this.generation && !this.state.wanted &&
        this.state.state !== 'completed' && this.state.state !== 'error';
      this.focusPausedGeneration = -1;
      if (resume) { this.setWanted(true, false); }
    } else if (hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_STOP ||
      hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_TIME_OUT_STOP) {
      this.clearFocusResume();
      this.setWanted(false, false);
    }
  };
  private readonly deviceListener = (event: audio.DeviceChangeAction): void => {
    if (!this.castHeld && event.type === audio.DeviceChangeType.DISCONNECT && (this.state.wanted || this.focusPausedGeneration >= 0)) {
      this.setWanted(false);
    }
    this.syncSystemVolume();
  };
  private readonly volumeListener = (event: audio.StreamVolumeEvent): void => {
    if (this.disposed || event.streamUsage !== audio.StreamUsage.STREAM_USAGE_MUSIC) { return; }
    this.readSystemVolume(event.volume, event.updateUi);
    this.emit();
  };

  private ctx: common.UIAbilityContext;
  private changed: (state: PlaybackSnapshot) => void;
  constructor(ctx: common.UIAbilityContext, changed: (state: PlaybackSnapshot) => void) {
    this.ctx = ctx;
    this.changed = changed;
  }

  initialize(): Promise<void> {
    if (this.initialization === undefined) { this.initialization = this.initializeSettings(); }
    return this.initialization;
  }

  private async initializeSettings(): Promise<void> {
    if (this.initialized || this.disposed) { return; }
    this.hardware = (await prefsGet('setting_enable_ha', '1')) !== '0';
    this.p1080 = (await prefsGet('setting_p1080', '1')) !== '0';
    const qn: number = parseInt(await prefsGet('setting_default_qn', '80'), 10);
    if (this.disposed) { return; }
    this.state.quality = Number.isFinite(qn) && qn > 0 ? qn : 80;
    this.state.volume = 1;
    this.initialized = true;
    this.offBg = onAppBackground((): void => { this.onBackground(); });
    this.offFg = onAppForeground((): void => { this.onForeground(); });
    this.offLogout = onAuthLogout((): void => {
      this.invalidateCast(false);
      this.emit();
    });
    this.focusManager.on('audioSessionStateChanged', this.focusListener);
    this.focusSubscribed = true;
    this.routing.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG, this.deviceListener);
    this.deviceSubscribed = true;
    try {
      this.volumeManager.on('streamVolumeChange', audio.StreamUsage.STREAM_USAGE_MUSIC, this.volumeListener);
      this.volumeSubscribed = true;
    } catch (_) { console.warn('[PiliMini-volume] subscription unavailable'); }
    this.readSystemVolume();
    this.emit();
  }

  ready(): boolean { return this.initialized && this.surface.length > 0 && this.visible && !this.disposed; }
  attachSurface(surface: string): void { this.surface = surface; }
  resizeSurface(width: number, height: number): void {
    if (this.disposed || !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) { return; }
    const w: number = Math.round(width), h: number = Math.round(height);
    if (this.surfaceW === w && this.surfaceH === h) { return; }
    this.surfaceW = w; this.surfaceH = h;
    if (this.engine !== undefined) { this.engine.resize(w, h); }
  }
  isWanted(): boolean { return this.state.wanted; }
  private current(generation: number): boolean { return !this.disposed && this.visible && generation === this.generation; }

  private emit(): void { if (!this.disposed) { this.changed(this.state); } }
  /** 原生事件即时响应；只有播放/准备/seek需要快照，稳定暂停无定时任务。 */
  private scheduleRefresh(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (this.castHeld || this.refreshInFlight || this.disposed || !this.visible || this.engine === undefined ||
      this.state.state === 'error' || this.state.state === 'completed' ||
      (this.state.loaded && !this.state.wanted && this.pendingSeek < 0 && !this.restoring && this.audioMissingAt === 0)) { return; }
    const urgent: boolean = !this.state.loaded || this.pendingSeek >= 0 || this.restoring || this.audioMissingAt > 0;
    this.timer = setTimeout((): void => { this.timer = -1; this.refresh(); },
      urgent || !this.background ? 500 : 5000);
  }
  private setState(state: string): void {
    const changed: boolean = this.state.state !== state;
    if (changed) {
      this.state.state = state;
      console.info('[PiliMini-mpv] state=' + state + ' pos=' + Math.floor(this.state.position).toString());
      this.syncSession();
    }
    if (changed || !this.background) { this.emit(); }
  }

  private claimSession(): void {
    const source: PlaybackSource | undefined = this.source;
    if (source === undefined || !this.visible || this.disposed) { return; }
    BgAudio.claim(this.ctx, this.owner, source.title, source.bvid + ':' + source.cid.toString(), {
      play: (): void => { this.setWanted(true); }, pause: (): void => { this.setWanted(false); },
      seek: (ms: number): void => { this.seek(ms); },
      skip: (ms: number): void => { this.seek((this.castHeld ? this.state.cast.position : this.position()) + ms); }
    }, source.artist, source.cover);
  }

  setMetadata(title: string, artist: string, cover: string): void {
    if (this.source === undefined) { return; }
    if (this.source.title === title && this.source.artist === artist && this.source.cover === cover) { return; }
    this.source.title = title; this.source.artist = artist; this.source.cover = cover;
    this.syncSession();
  }

  private syncSession(): void {
    const source: PlaybackSource | undefined = this.source;
    if (source === undefined || !this.visible || this.disposed) { return; }
    this.lastSessionAt = Date.now();
    BgAudio.updateMetadata(this.owner, source.title, source.bvid + ':' + source.cid.toString(),
      this.state.duration, source.artist, source.cover);
    if (this.castHeld) {
      const cast: CastSnapshot = this.state.cast;
      BgAudio.setState(this.owner, cast.remote && cast.phase === 'playing', cast.position,
        cast.duration || this.state.duration, 1, cast.remote && cast.phase === 'connecting', true);
      return;
    }
    BgAudio.setState(this.owner, this.state.wanted && this.state.state !== 'completed' && this.state.state !== 'error',
      this.state.position, this.state.duration, this.state.speed, this.state.state === 'loading');
  }

  /** 取完整媒体源后直接发现DLNA；不依赖OEM系统设备选择器。 */
  async beginCast(): Promise<void> {
    const source: PlaybackSource | undefined = this.source;
    if (this.disposed || !this.visible || this.background || source === undefined || source.localPath.length > 0) { return; }
    if (!this.checkCastAccount()) { return; }
    if (this.state.cast.phase === 'preparing' || this.state.cast.phase === 'connecting') { return; }
    const closing: Promise<void> = this.invalidateCast(false);
    const generation: number = this.castGeneration;
    const revision: number = CookieStore.sessionRevision();
    this.castRevision = revision;
    const snapshot: CastSnapshot = new CastSnapshot();
    if (this.castHeld) {
      snapshot.deviceName = this.state.cast.deviceName;
      snapshot.position = this.state.cast.position; snapshot.duration = this.state.cast.duration;
    }
    snapshot.localHeld = this.castHeld; snapshot.selection = false; snapshot.phase = 'preparing'; snapshot.message = '正在准备投屏…';
    this.state.cast = snapshot; this.emit();
    const current = (): boolean => this.castCurrent(generation, revision, source);
    try {
      if (!this.state.loaded || this.engine === undefined) { throw new Error('请等待视频准备完成后再投屏'); }
      await closing;
      if (!current()) { this.checkCastAccount(); return; }
      const stopped: boolean = await DlnaCastSession.drainStops();
      if (!current()) { this.checkCastAccount(); return; }
      if (!stopped || (this.castCleanupSession !== undefined && !this.castCleanupSession.stopped())) {
        throw new Error('尚未确认电视停止，请重试断开');
      }
      this.castCleanupSession = undefined;
      const media: CastUrl = await VideoService.castUrl(source.bvid, source.cid);
      if (!current()) { this.checkCastAccount(); return; }
      if (this.background || !this.castPanelVisible) { this.cancelCastDiscovery(); return; }
      if (this.state.duration > 0 && Math.abs(media.durationMs - this.state.duration) > 2000) {
        throw new Error('当前视频的投屏媒体源不完整');
      }
      const item: DlnaMedia = new DlnaMedia();
      item.url = media.url; item.title = source.title; item.duration = media.durationMs;
      item.position = this.position(); this.castMedia = item;
      this.state.cast.phase = 'selecting'; this.state.cast.selection = true; this.state.cast.message = ''; this.state.cast.discovering = true;
      let discovery: DlnaDiscovery | undefined = undefined;
      discovery = new DlnaDiscovery((devices: DlnaDevice[], discovering: boolean, message: string): void => {
        if (!current() || this.castDiscovery !== discovery) { return; }
        if (!this.checkCastAccount()) { return; }
        this.state.cast.devices = devices.slice(); this.state.cast.discovering = discovering;
        this.state.cast.message = message; this.emit();
      });
      this.castDiscovery = discovery; this.emit();
      await discovery.start();
    } catch (error) {
      if (!current()) { this.checkCastAccount(); return; }
      this.stopCastDiscovery();
      this.state.cast.phase = 'error'; this.state.cast.remote = false; this.state.cast.selection = false;
      const message: string = (error as Error).message || '';
      const allowed: string[] = ['请等待视频准备完成后再投屏', '当前视频暂不支持投屏',
        '当前视频没有可投屏的完整媒体源', '当前视频的投屏媒体源不完整',
        '当前视频暂无可投屏的常规媒体源', '登录状态已变化，请重试', '尚未确认电视停止，请重试断开'];
      this.state.cast.message = allowed.indexOf(message) >= 0 ? message : '暂时无法投屏，请检查网络后重试';
      this.emit();
    }
  }

  async selectCastDevice(id: string): Promise<void> {
    const source: PlaybackSource | undefined = this.source;
    const media: DlnaMedia | undefined = this.castMedia;
    if (this.disposed || !this.visible || this.background || !this.castPanelVisible ||
      !this.state.cast.selection || source === undefined || media === undefined || !this.checkCastAccount()) { return; }
    const device: DlnaDevice | undefined = this.state.cast.devices.find((item: DlnaDevice): boolean => item.id === id);
    if (device === undefined) { return; }
    const generation: number = this.castGeneration;
    const revision: number = CookieStore.sessionRevision();
    const current = (): boolean => this.castCurrent(generation, revision, source);
    this.stopCastDiscovery(); this.state.cast.selection = false;
    this.state.cast.phase = 'connecting'; this.state.cast.message = '正在连接…'; this.emit();
    let transport: DlnaCastSession | undefined = undefined;
    transport = new DlnaCastSession(
      (): boolean => {
        if (generation === this.castGeneration && revision !== CookieStore.sessionRevision()) {
          this.checkCastAccount(); return false;
        }
        return current();
      },
      (): number => {
        if (!current()) { throw new Error('投屏已取消'); }
        const position: number = Math.floor(Math.max(0, Math.min(this.position(), Math.max(0, media.duration - 1000))));
        if (!this.castHeld) { this.setWanted(false); }
        this.castHeld = true;
        this.clearFocusResume(); this.releaseFocus();
        this.clearBackgroundTimer(); this.clearRestore(); this.invalidateSnapshot();
        this.pendingSeek = -1; this.seekStarted = false; this.pendingEnd = false; this.audioMissingAt = 0;
        this.state.seeking = false; BgAudio.setRemote(this.owner, true); this.scheduleRefresh();
        return position;
      },
      (cast: CastSnapshot): void => {
        if (!current() || this.castSession !== transport) { return; }
        cast.localHeld = this.castHeld; cast.selection = false; cast.discovering = false; cast.devices = [];
        this.state.cast = cast;
        if (this.castHeld && cast.duration <= 0) { cast.duration = media.duration; }
        if (this.castHeld && Number.isFinite(cast.position)) {
          this.state.position = Math.max(0, cast.position);
          this.state.sampledAt = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
          if (this.history !== undefined && cast.remote) {
            this.history.observe(cast.position, cast.phase === 'playing', false,
              cast.phase === 'paused' || cast.phase === 'ended', this.background);
          }
          this.savePosition(false);
        }
        if (!cast.remote && this.castHeld) {
          BgAudio.stop(this.owner); this.state.wanted = false; this.state.state = 'paused';
        }
        this.syncSession(); this.updateCastBackground(); this.emit();
      });
    this.castSession = transport;
    BgAudio.setCastCleanup(this.owner, (): Promise<void> => transport!.disconnect());
    transport.setBackground(this.background); transport.setPanelVisible(this.castPanelVisible);
    try { await transport.connect(device, media); }
    catch (_) {
      if (!current() || this.castSession !== transport) { return; }
      this.state.cast.phase = 'error'; this.state.cast.message = '投屏连接失败，请重试'; this.emit();
    }
  }

  private stopCastDiscovery(): void {
    const discovery: DlnaDiscovery | undefined = this.castDiscovery;
    this.castDiscovery = undefined;
    if (discovery !== undefined) { discovery.stop(); }
    this.state.cast.discovering = false;
  }

  private cancelCastDiscovery(): void {
    this.invalidateCast(false);
    if (!this.castHeld) { this.state.cast = new CastSnapshot(); }
    this.emit();
  }

  private castCurrent(generation: number, revision: number, source: PlaybackSource): boolean {
    return !this.disposed && this.visible && generation === this.castGeneration &&
      revision === CookieStore.sessionRevision() && this.source === source;
  }

  private checkCastAccount(): boolean {
    if (this.castRevision < 0 || this.castRevision === CookieStore.sessionRevision()) { return true; }
    this.invalidateCast(false);
    this.state.cast.phase = 'disconnected'; this.state.cast.message = '登录状态已变化，请重新投屏';
    this.emit(); return false;
  }

  castPlay(): void {
    if (!this.checkCastAccount() || this.disposed || !this.visible || this.castSession === undefined) { return; }
    this.castSession.command('play');
  }

  castPause(): void {
    if (!this.checkCastAccount() || this.disposed || !this.visible || this.castSession === undefined) { return; }
    this.castSession.command('pause');
  }

  castSeek(ms: number): void {
    if (!Number.isFinite(ms) || !this.checkCastAccount() || this.disposed || !this.visible || this.castSession === undefined) { return; }
    this.castSession.command('seek', ms);
  }

  setCastPanelVisible(visible: boolean): void {
    this.castPanelVisible = visible;
    if (!this.checkCastAccount()) { return; }
    if (!visible && (this.state.cast.phase === 'preparing' || this.state.cast.selection)) {
      this.cancelCastDiscovery(); return;
    }
    if (this.castSession !== undefined) { this.castSession.setPanelVisible(visible); }
  }

  async disconnectCast(resumeLocal: boolean): Promise<void> {
    const held: boolean = this.castHeld;
    const transport: DlnaCastSession | undefined = this.castSession || this.castCleanupSession;
    let position: number = held ? this.state.cast.position : this.position();
    // 周期读取最多滞后5秒；续播前补读一次，读取超时只退回既有快照，不阻塞断开。
    if (resumeLocal && held && this.castSession !== undefined) {
      const fresh: number = await this.readRemotePosition(this.castSession);
      if (fresh >= 0) { position = fresh; }
    }
    console.warn('[PiliMini-cast] disconnect resume=' + resumeLocal.toString() + ' held=' + held.toString() +
      ' phase=' + this.state.cast.phase + ' remote=' + Math.floor(position).toString() +
      ' local=' + Math.floor(this.state.position).toString() + ' loaded=' + this.state.loaded.toString());
    const source: PlaybackSource | undefined = this.source;
    const revision: number = CookieStore.sessionRevision();
    const closing: Promise<void> = this.invalidateCast(false);
    const generation: number = this.castGeneration;
    this.syncSession(); this.emit();
    await closing;
    if (source === undefined || !this.castCurrent(generation, revision, source)) { return; }
    if (held && transport !== undefined && !transport.stopped()) {
      this.state.cast.phase = 'error'; this.state.cast.message = '尚未确认电视停止，请重试断开或在手机继续播放';
      this.emit(); return;
    }
    if (!resumeLocal || !held) { return; }
    this.castCleanupSession = undefined;
    this.castHeld = false; BgAudio.setRemote(this.owner, false);
    this.state.cast = new CastSnapshot();
    this.resumeLocalAt(position);
    this.emit();
  }

  /** 断开前的最后进度补读；1.5秒内没结果就按既有快照处理，远端慢不能拖住本机恢复。 */
  private readRemotePosition(session: DlnaCastSession): Promise<number> {
    return new Promise<number>((resolve: (value: number) => void): void => {
      let settled: boolean = false;
      const timer: number = setTimeout((): void => {
        if (settled) { return; }
        settled = true; resolve(-1);
      }, 1500);
      session.syncPosition().then((value: number): void => {
        if (settled) { return; }
        settled = true; clearTimeout(timer); resolve(value);
      }).catch((): void => {
        if (settled) { return; }
        settled = true; clearTimeout(timer); resolve(-1);
      });
    });
  }

  /**
   * 远端确认停止后回到本机：按远端进度seek再起播。
   * 不走setWanted的完成态重播分支，也不依赖引擎一定在内存里——引擎已被回收时按同一进度重载。
   */
  private resumeLocalAt(target: number): void {
    const source: PlaybackSource | undefined = this.source;
    if (this.disposed || !this.visible || source === undefined) { return; }
    const duration: number = this.state.duration;
    const value: number = Number.isFinite(target) ? Math.max(0, target) : 0;
    const position: number = duration > 0 ? Math.min(value, Math.max(0, duration - 1000)) : value;
    console.warn('[PiliMini-cast] resume target=' + Math.floor(value).toString() +
      ' position=' + Math.floor(position).toString() + ' duration=' + Math.floor(duration).toString() +
      ' loaded=' + this.state.loaded.toString() + ' engine=' + (this.engine !== undefined).toString());
    this.state.position = position;
    this.state.sampledAt = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
    this.state.timeRevision++;
    this.state.wanted = true;
    this.pendingEnd = false;
    this.clearFocusResume();
    this.clearBackgroundTimer();
    if (this.state.audioOnly && !this.background && this.engine !== undefined) {
      this.state.audioOnly = false; this.restoring = true; this.restoreAttempt = 0;
      try { this.engine.video(true); this.waitRestore(); } catch (_) { this.restoreMedia(); }
    }
    if (this.engine !== undefined && this.state.loaded) {
      try {
        this.invalidateSnapshot();
        this.pendingSeek = position; this.seekStarted = false; this.seekAt = Date.now();
        this.state.seeking = true;
        this.engine.seek(position);
        this.setState('loading');
        this.playAfterFocus(this.engine);
        this.savePosition(true); this.syncSession(); this.scheduleRefresh();
        return;
      } catch (_) {
        this.pendingSeek = -1; this.state.seeking = false;
      }
    }
    // 引擎不可用：保留目标进度重载；完成态必须先退出，否则start按0起播。
    if (this.state.state === 'completed') { this.setState('paused'); }
    this.start(source, this.state.quality, true);
  }

  /** 同步作废投屏回调后才异步释放；不影响mpv自己的generation。 */
  private invalidateCast(reset: boolean): Promise<void> {
    this.stopCastDiscovery(); this.castMedia = undefined;
    this.state.cast.selection = false; this.state.cast.devices = [];
    const transport: DlnaCastSession | undefined = this.castSession || this.castCleanupSession;
    this.castSession = undefined; this.castGeneration++; this.castRevision = -1;
    this.castCleanupSession = reset ? undefined : transport;
    const wasRemote: boolean = this.castHeld;
    if (wasRemote && Number.isFinite(this.state.cast.position)) {
      this.state.position = Math.max(0, this.state.cast.position);
      this.state.sampledAt = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
      this.state.timeRevision++;
    }
    if (reset) { this.castHeld = false; this.state.cast = new CastSnapshot(); }
    else if (transport !== undefined || wasRemote || this.state.cast.phase !== 'idle') {
      this.state.cast.remote = false; this.state.cast.phase = 'disconnected';
      this.state.cast.message = '投屏已断开';
      this.state.cast.canPlay = false; this.state.cast.canPause = false; this.state.cast.canSeek = false;
    }
    this.state.cast.localHeld = this.castHeld;
    if (wasRemote) { BgAudio.stop(this.owner); }
    BgAudio.setRemote(this.owner, !reset && this.castHeld);
    if (wasRemote) { this.syncSession(); }
    return transport === undefined ? Promise.resolve() : transport.disconnect();
  }

  private updateCastBackground(): void {
    if (!this.castHeld) { return; }
    if (this.background && this.state.cast.remote && this.state.cast.phase === 'playing') { BgAudio.start(this.ctx, this.owner); }
    else { BgAudio.stop(this.owner); }
  }

  private enqueue(work: () => Promise<void>, generation: number = this.generation): Promise<void> {
    const result: Promise<void> = PlayController.kernelQueue.then(work);
    this.nativeQueue = result.catch((error: Error): void => {
      if (this.current(generation)) { this.fail('播放器初始化失败：' + error.message); }
    });
    PlayController.kernelQueue = this.nativeQueue;
    return this.nativeQueue;
  }

  private closeEngine(): Promise<void> {
    const old: MpvEngine | undefined = this.engine;
    this.engine = undefined;
    return old === undefined ? Promise.resolve() : old.dispose();
  }

  async start(source: PlaybackSource, quality: number, preserve: boolean = true): Promise<void> {
    if (!this.ready()) { return; }
    const request: number = ++this.startRequest;
    const castClosing: Promise<void> = this.invalidateCast(false);
    await castClosing;
    if (!this.ready() || request !== this.startRequest) { return; }
    const stopped: boolean = await DlnaCastSession.drainStops();
    if (!this.ready() || request !== this.startRequest) { return; }
    if (!stopped) {
      this.state.cast.phase = 'error'; this.state.cast.message = '尚未确认电视停止，请重试断开';
      this.state.cast.localHeld = this.castHeld;
      if (!this.castHeld) {
        this.state.wanted = false; this.state.error = '尚未确认电视停止，请重试播放';
        this.setState('error');
      }
      this.emit(); return;
    }
    this.invalidateCast(true);
    this.clearFocusResume();
    const previous: PlaybackSource | undefined = this.source;
    const same: boolean = preserve && previous !== undefined && previous.bvid === source.bvid &&
      previous.cid === source.cid && previous.localPath === source.localPath;
    this.commitPosition();
    if (this.history !== undefined) { this.history.flush(); }
    if (source.localPath.length > 0) {
      this.history = undefined;
    } else if (previous === undefined || previous.localPath.length > 0 || previous.bvid !== source.bvid || previous.cid !== source.cid) {
      this.history = new PlaybackHistory(source.bvid, source.cid);
    }
    this.savePosition(true);
    const position: number = same && this.state.state !== 'completed' ? this.position() : 0;
    const wanted: boolean = same && this.state.state !== 'error' && this.state.state !== 'completed' ? this.state.wanted : true;
    const generation: number = ++this.generation;
    this.clearBackgroundTimer(); this.clearRestore();
    this.prepareAt = Date.now();
    this.source = source;
    this.info = undefined;
    this.videoBackup = 0; this.audioBackup = 0; this.refreshed = false;
    this.state.wanted = wanted;
    this.state.position = position;
    this.state.sampledAt = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
    this.state.timeRevision++;
    this.state.seeking = false;
    this.state.loaded = false;
    this.state.audioOnly = false;
    this.state.error = '';
    this.state.bufferPercent = 0;
    if (!same) { this.state.duration = 0; this.state.width = 0; this.state.height = 0; }
    this.lastSaved = position;
    this.lastSavedAt = Date.now();
    this.claimSession();
    this.setState('loading');
    // 取流与释放可并行，创建只能在释放完成之后；旧实例不能继续发声。
    const closing: Promise<void> = this.enqueue(async (): Promise<void> => { await this.closeEngine(); });
    try {
      if (!this.current(generation)) { return; }
      let info: PlayInfo;
      let start: number = position;
      if (source.localPath.length > 0) {
        // DASH 双文件（spec-17 2026-10-27）：有独立音轨时按 isDash 交给 mpv 绑定；
        // 旧版单文件 MP4 仍走 audioUrl 空、isDash=false 的原路径。
        const localAudio: string = source.localAudioPath !== undefined ? source.localAudioPath : '';
        const hasAudio: boolean = localAudio.length > 0;
        info = { videoUrl: 'file://' + source.localPath, audioUrl: hasAudio ? 'file://' + localAudio : '',
          videoBackup: [], audioBackup: [],
          qualities: [], currentQn: 0, durationMs: (source.localDuration || 0) * 1000, isDash: hasAudio };
        if (!same) {
          const saved: number = await PlaybackPos.get(source.bvid, source.cid);
          if (!this.current(generation)) { return; }
          if (saved > 5000 && (info.durationMs <= 0 || saved < info.durationMs - 400)) { start = saved; }
        }
      } else {
        const logged: boolean = await AuthService.isLogin();
        if (!this.current(generation)) { return; }
        info = await VideoService.playUrl(source.bvid, source.cid, quality, this.p1080 && !logged);
        if (!this.current(generation)) { return; }
        if (!same) {
          const saved: number = await PlaybackPos.get(source.bvid, source.cid);
          if (!this.current(generation)) { return; }
          if (saved > 3000 && saved < info.durationMs - 5000) { start = saved; }
        }
      }
      await closing;
      if (!this.current(generation)) { return; }
      this.info = info;
      this.state.quality = info.currentQn;
      this.state.qualities = info.qualities;
      this.state.duration = info.durationMs;
      await this.open(info, start, generation);
    } catch (error) {
      if (this.current(generation)) { this.fail((error as Error).message || '取流失败'); }
    }
  }

  private open(info: PlayInfo, position: number, generation: number): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      if (!this.current(generation)) { return; }
      await this.closeEngine();
      if (!this.current(generation) || this.surface.length === 0) { return; }
      const surface: string = this.surface;
      let created: MpvEngine | undefined = undefined;
      created = await MpvEngine.create(surface, this.hardware, (event: NativePlayerEvent): void => {
        if (created !== undefined && this.current(generation) && this.engine === created) { this.onEvent(event); }
      });
      const engine: MpvEngine = created;
      // 异步初始化仍占用kernelQueue；退页/切源的迟到实例先关闭，再让下个任务或Surface销毁继续。
      if (!this.current(generation) || this.surface !== surface) { await engine.dispose(); return; }
      this.engine = engine;
      // 深诊断不参与起播判定，避开首次解码/音轨准备时额外查询。
      this.lastDiagnosticAt = Date.now();
      this.pendingSeek = -1; this.seekStarted = false;
      this.pendingEnd = false;
      this.audioMissingAt = 0;
      this.state.loaded = false;
      this.state.position = position;
      this.state.sampledAt = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
      this.state.seeking = false;
      this.prepareAt = Date.now();
      if (this.surfaceW > 0 && this.surfaceH > 0) { engine.resize(this.surfaceW, this.surfaceH); }
      engine.speed(this.state.speed); engine.volume(this.state.volume);
      // 官方要求先激活会话再起流；mpv准备阶段也不能先播放再补申请焦点。
      if (this.state.wanted) { await this.activateFocus(generation, this.focusRevision); }
      if (!this.current(generation) || this.engine !== engine) { return; }
      // 激活期间用户可暂停/续播；先以暂停载入，FILE_LOADED再按最新意图和焦点起播。
      engine.load(info.videoUrl, info.isDash ? info.audioUrl : '', position, true);
      if (this.background && this.state.wanted) { this.startBackground(); }
      this.scheduleRefresh();
      this.emit();
    }, generation);
  }

  private onEvent(event: NativePlayerEvent): void {
    if (this.castHeld) { return; }
    if (event.type === 'video-output-error') { this.fail('视频画面初始化失败，请返回后重试'); return; }
    if (event.type === 'error') { this.retry('播放失败（' + event.code.toString() + '）'); return; }
    if (event.type === 'command-error') {
      if (!this.state.loaded) { this.retry('媒体加载失败（' + event.code.toString() + '）'); }
      return;
    }
    // 事件到达时在途读取可能尚未包含该变化，丢弃旧结果并只补采一次。
    this.invalidateSnapshot();
    if (event.type === 'loaded') {
      this.state.loaded = true;
      if (this.engine !== undefined) {
        if (this.state.wanted) { this.playAfterFocus(this.engine); }
        else { this.engine.pause(); if (this.background) { this.stopBackgroundVideo(); } }
      }
    }
    if (event.type === 'seek' && this.pendingSeek >= 0) { this.seekStarted = true; }
    if (event.type === 'ended') {
      if (this.pendingSeek < 0) { this.pendingEnd = true; this.refresh(); }
      return;
    }
    this.refresh();
  }

  private refresh(): void {
    if (this.castHeld || this.disposed || !this.visible || this.engine === undefined ||
      this.state.state === 'error' || this.state.state === 'completed') { return; }
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (this.refreshInFlight) { this.refreshAgain = true; return; }
    this.refreshInFlight = true;
    this.refreshAgain = false;
    this.refreshSnapshot().finally((): void => {
      this.refreshInFlight = false;
      const again: boolean = this.refreshAgain;
      this.refreshAgain = false;
      if (again) { this.refresh(); }
      else { this.scheduleRefresh(); }
    });
  }

  private async refreshSnapshot(): Promise<void> {
    const engine: MpvEngine | undefined = this.engine;
    const generation: number = this.generation, revision: number = this.refreshRevision;
    if (engine === undefined) { return; }
    const valid = (): boolean => !this.castHeld && this.current(generation) && this.engine === engine &&
      revision === this.refreshRevision && this.state.state !== 'error' && this.state.state !== 'completed';
    try {
      if (!this.state.loaded) {
        if (Date.now() - this.prepareAt > 20000) { this.retry('播放准备超时'); }
        return;
      }
      const now: number = Date.now();
      const diagnostic: boolean = this.state.state === 'playing' && this.pendingSeek < 0 && !this.restoring &&
        now - this.lastDiagnosticAt >= (this.background ? 60000 : 30000);
      // 音轨未就绪等分支会提前返回，必须在查询前记录以免事件簇重复深诊断。
      if (diagnostic) { this.lastDiagnosticAt = now; }
      const native: NativePlayerSnapshot = await engine.snapshot(diagnostic);
      if (!valid()) { return; }
      const uptime: number = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
      const sampledAt: number = uptime - Math.min(uptime, Math.max(0, native.sampleAgeMs));
      if (this.pendingSeek >= 0 && this.seekStarted && !native.seeking &&
        Math.abs(native.position - this.pendingSeek) < 2000) { this.pendingSeek = -1; }
      // 外置音轨打开失败时mpv仍可能正常播放视频，不能仅凭FILE_LOADED判定音画齐全。
      if (this.info !== undefined && this.info.isDash && this.info.audioUrl.length > 0 && !native.audioReady && !native.ended) {
        if (this.audioMissingAt === 0) { this.audioMissingAt = Date.now(); }
        if (Date.now() - this.audioMissingAt >= 2500) { this.retry('音频加载失败', true); }
        else { this.setState('loading'); }
        return;
      }
      this.audioMissingAt = 0;
      // restart可能早于VO配置完成；快照确认出图后也必须结束恢复等待。
      if (this.restoring && native.videoEnabled && native.outputReady && !native.seeking && !native.buffering) {
        this.clearRestore();
        if (this.state.wanted && this.engine !== undefined) { this.playAfterFocus(this.engine); }
      }
      if (diagnostic) {
        const stats = MpvEngine.stats();
        console.info('[PiliMini-mpv] clock syncValid=' + native.syncValid + ' avMs=' +
          native.avSyncMs.toFixed(2) + ' output=' + native.outputReady + ' decoder=' + native.decoder +
          ' video=' + native.videoEnabled + ' codec=' + native.videoCodec +
          ' audio=' + native.audioReady +
          ' cacheBytes=' + Math.floor(native.cacheBytes).toString() +
          ' instances=' + stats.instances.toString() + ' threads=' + stats.eventThreads.toString());
      }
      if (this.pendingSeek >= 0 && Date.now() - this.seekAt > 8000) { this.pendingSeek = -1; this.retry('定位播放进度超时'); return; }
      this.state.seeking = native.seeking || this.pendingSeek >= 0;
      if (!this.state.seeking) { this.state.position = Math.max(0, native.position); this.state.sampledAt = sampledAt; }
      if (native.duration > 0) { this.state.duration = native.duration; }
      if (native.width > 0 && native.height > 0) { this.state.width = native.width; this.state.height = native.height; }
      this.state.bufferPercent = this.state.duration > 0 ? Math.min(100,
        Math.max(this.state.position, native.buffered) / this.state.duration * 100) : 0;
      if ((native.ended || this.pendingEnd) && !native.seeking && this.pendingSeek < 0) {
        this.pendingEnd = false; this.finishPlayback(!native.audioReady); return;
      }
      this.setState(!this.state.wanted ? 'paused' :
        (native.paused || native.buffering || native.seeking || this.pendingSeek >= 0 || this.restoring ? 'loading' : 'playing'));
      if (this.history !== undefined) {
        this.history.observe(native.position, this.state.state === 'playing', native.seeking || this.pendingSeek >= 0,
          this.state.state === 'paused', this.background);
      }
      this.savePosition(false);
      if (Date.now() - this.lastSessionAt >= (this.background ? 30000 : 15000)) { this.syncSession(); }
    } catch (error) { if (valid()) { this.retry('播放器状态异常'); } }
  }

  private position(): number {
    if (this.pendingSeek >= 0) { return this.pendingSeek; }
    let value: number = this.state.position;
    if (this.state.state === 'playing' && this.state.wanted && this.state.loaded && !this.state.seeking &&
      !this.restoring && this.state.sampledAt > 0) {
      // 读取/线程池异常迟到时不把长期旧快照外推到片尾；正常上限覆盖原采样周期。
      const elapsed: number = Math.max(0, systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE) - this.state.sampledAt);
      value += Math.min(elapsed, this.background ? 6000 : 1500) * this.state.speed;
    }
    return Math.max(0, this.state.duration > 0 ? Math.min(value, this.state.duration) : value);
  }

  private commitPosition(): void {
    this.state.position = this.position();
    this.state.sampledAt = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
  }

  private invalidateSnapshot(): void {
    this.refreshRevision++;
    if (this.refreshInFlight) { this.refreshAgain = true; }
  }

  toggle(): void {
    if (this.castHeld) {
      if (this.state.cast.phase === 'playing') { this.castPause(); } else { this.castPlay(); }
      return;
    }
    if (this.state.state === 'completed') { this.seek(0); this.setWanted(true); }
    else { this.setWanted(!this.state.wanted); }
  }

  setWanted(wanted: boolean, user: boolean = true): void {
    if (this.disposed || !this.visible) { return; }
    if (this.castHeld) { if (wanted) { this.castPlay(); } else { this.castPause(); } return; }
    if (user) { this.clearFocusResume(); }
    else { this.focusRevision++; }
    this.commitPosition(); this.invalidateSnapshot();
    this.state.wanted = wanted;
    if (this.engine !== undefined) {
      try {
        if (wanted) {
          if (this.state.state === 'completed') { this.seek(0); }
          if (this.state.loaded) { this.playAfterFocus(this.engine); }
        } else {
          this.engine.pause(); this.clearBackgroundTimer(); BgAudio.stop(this.owner);
          if (this.background) { this.stopBackgroundVideo(); }
        }
      } catch (error) { this.fail('播放控制失败'); return; }
    }
    if (!wanted && user) { this.releaseFocus(); }
    this.savePosition(true);
    this.setState(wanted ? 'loading' : 'paused');
    this.refresh();
    if (!wanted && this.history !== undefined) { this.history.flush(); }
  }

  seek(ms: number): void {
    if (this.castHeld) { this.castSeek(ms); return; }
    if (this.disposed || !this.visible || this.engine === undefined || !this.state.loaded || !Number.isFinite(ms)) { return; }
    const target: number = Math.max(0, Math.min(ms, Math.max(0, this.state.duration - 1000)));
    try {
      this.invalidateSnapshot();
      this.pendingEnd = false;
      this.pendingSeek = target; this.seekStarted = false; this.seekAt = Date.now();
      this.engine.seek(target);
      this.state.position = target;
      this.state.sampledAt = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
      this.state.timeRevision++; this.state.seeking = true;
      if (this.state.state === 'completed') { this.state.wanted = false; }
      this.setState(this.state.wanted ? 'loading' : 'paused');
      this.syncSession();
      this.scheduleRefresh();
    } catch (error) { this.fail('定位播放进度失败'); }
  }

  speed(value: number): void {
    if (this.castHeld || !Number.isFinite(value) || value < 0.25 || value > 5 || this.disposed) { return; }
    this.commitPosition(); this.invalidateSnapshot();
    this.state.speed = value;
    if (this.engine !== undefined) { this.engine.speed(value); }
    this.syncSession(); this.emit();
  }
  /** 真实系统音量只读入口；用户调节由前台AVVolumePanel显式完成。 */
  syncSystemVolume(): void {
    if (this.disposed) { return; }
    this.readSystemVolume(); this.emit();
  }
  private readSystemVolume(level: number = -1, showUi: boolean = false): void {
    this.state.systemVolumeRevision++;
    this.state.systemVolumeShowUi = false;
    try {
      const usage: audio.StreamUsage = audio.StreamUsage.STREAM_USAGE_MUSIC;
      const min: number = this.volumeManager.getMinVolumeByStream(usage);
      const max: number = this.volumeManager.getMaxVolumeByStream(usage);
      const current: number = level >= 0 ? level : this.volumeManager.getVolumeByStream(usage);
      if (!Number.isFinite(min) || !Number.isFinite(max) || !Number.isFinite(current) || max <= min ||
        current < min || current > max) { this.state.systemVolumeReady = false; return; }
      this.state.systemVolumeMin = min; this.state.systemVolumeMax = max;
      this.state.systemVolumeLevel = current; this.state.systemVolumeReady = true;
      this.state.systemVolumeShowUi = showUi && this.visible && !this.background;
    } catch (_) { this.state.systemVolumeReady = false; }
  }

  private retry(message: string, audioFailure: boolean = false): void {
    const info: PlayInfo | undefined = this.info;
    if (info === undefined || this.disposed || !this.visible) { return; }
    const position: number = this.state.loaded ? this.position() : this.state.position;
    const generation: number = ++this.generation;
    this.state.loaded = false; this.clearRestore();
    this.prepareAt = Date.now();
    if (audioFailure && this.audioBackup < Math.min(2, info.audioBackup.length)) { info.audioUrl = info.audioBackup[this.audioBackup++]; }
    else if (!audioFailure && this.videoBackup < Math.min(2, info.videoBackup.length)) { info.videoUrl = info.videoBackup[this.videoBackup++]; }
    else if (this.audioBackup < Math.min(2, info.audioBackup.length)) { info.audioUrl = info.audioBackup[this.audioBackup++]; }
    else {
      if (!this.refreshed && this.source !== undefined && this.source.localPath.length === 0) {
        this.refreshed = true;
        this.refreshSource(position, generation);
      } else { this.fail(message); }
      return;
    }
    this.setState('loading'); this.open(info, position, generation);
  }

  private async refreshSource(position: number, generation: number): Promise<void> {
    const source: PlaybackSource | undefined = this.source;
    if (source === undefined) { return; }
    this.setState('loading');
    await this.enqueue(async (): Promise<void> => { await this.closeEngine(); });
    try {
      const logged: boolean = await AuthService.isLogin();
      if (!this.current(generation)) { return; }
      const info: PlayInfo = await VideoService.playUrl(source.bvid, source.cid, this.state.quality, this.p1080 && !logged);
      if (!this.current(generation)) { return; }
      this.info = info; this.open(info, position, generation);
    } catch (error) { if (this.current(generation)) { this.fail('重新获取播放地址失败'); } }
  }

  private finishPlayback(audioFailure: boolean): void {
    if (this.state.duration > 0 && this.state.position < this.state.duration - 8000) {
      this.retry('媒体数据提前结束', audioFailure);
    } else { this.complete(); }
  }
  private complete(): void {
    if (this.state.state === 'completed') { return; }
    this.clearFocusResume(); this.releaseFocus();
    this.state.wanted = false;
    this.state.position = this.state.duration;
    if (this.history !== undefined) { this.history.complete(); }
    this.clearBackgroundTimer(); this.clearRestore();
    BgAudio.stop(this.owner); this.savePosition(true); this.setState('completed'); this.scheduleRefresh();
  }
  private fail(message: string): void {
    this.commitPosition();
    this.clearFocusResume(); this.releaseFocus();
    this.state.wanted = false; this.state.error = message;
    if (this.history !== undefined) { this.history.flush(); }
    this.clearBackgroundTimer(); this.clearRestore();
    if (this.engine !== undefined) { try { this.engine.pause(); } catch (error) {} }
    BgAudio.stop(this.owner); this.savePosition(true); this.setState('error'); this.scheduleRefresh();
  }

  private savePosition(force: boolean): void {
    const source: PlaybackSource | undefined = this.source;
    const ms: number = this.state.position;
    if (source === undefined || ms <= 0 || this.state.duration <= 0) { return; }
    const offline: boolean = source.localPath.length > 0;
    if (ms > this.state.duration - (offline ? 400 : 10000)) {
      if (this.lastSaved !== -1) {
        this.lastSaved = -1;
        PlaybackPos.remove(source.bvid, source.cid);
      }
      return;
    }
    if (force || Date.now() - this.lastSavedAt >= (this.background ? 30000 : 15000)) {
      this.lastSaved = ms; this.lastSavedAt = Date.now();
      if (offline && ms > 5000) {
        DownloadLibraryService.remember(source.bvid, source.cid,
          { scope: source.offlineScope || 'all', key: source.offlineKey || '' });
      }
      if (force) { PlaybackPos.flush(source.bvid, source.cid, ms); }
      else { PlaybackPos.save(source.bvid, source.cid, ms); }
    }
  }

  private clearFocusResume(): void {
    this.focusPausedGeneration = -1;
    this.focusRevision++;
  }

  private activateFocus(generation: number, revision: number): Promise<boolean> {
    const valid = (): boolean => !this.castHeld && this.current(generation) && this.state.wanted && revision === this.focusRevision;
    const work: Promise<boolean> = PlayController.focusQueue.then(async (): Promise<boolean> => {
      if (!valid()) { return false; }
      try {
        if (PlayController.focusOwner === this.owner && this.focusActivatedRevision === revision &&
          this.focusManager.isAudioSessionActivated()) { return true; }
        // PAUSE后系统停用会话；每次恢复都需重设scene/behavior，再激活。
        this.focusManager.setAudioSessionScene(audio.AudioSessionScene.AUDIO_SESSION_SCENE_MEDIA);
        this.focusManager.setAudioSessionBehavior(audio.AudioSessionBehaviorFlags.PAUSE_WHEN_INTERRUPTED);
        PlayController.focusOwner = this.owner;
        await this.focusManager.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT });
        if (!valid()) { return false; }
        this.focusActivatedRevision = revision;
        console.info('[PiliMini-focus] activated pause-when-interrupted');
        return true;
      } catch (_) {
        if (valid()) {
          console.warn('[PiliMini-focus] activation failed');
          this.clearFocusResume();
          this.setWanted(false, false);
          this.releaseFocus();
        }
        return false;
      }
    });
    PlayController.focusQueue = work.then((): void => {}, (): void => {});
    return work;
  }

  private async playAfterFocus(engine: MpvEngine): Promise<void> {
    const generation: number = this.generation, revision: number = this.focusRevision;
    // 画面恢复期间先不取焦点、不出声；clearRestore后由快照统一再起播，避免只有声音先走。
    if (this.restoring) { return; }
    if (!await this.activateFocus(generation, revision) || this.castHeld || !this.current(generation) ||
      this.restoring || revision !== this.focusRevision || !this.state.wanted || this.engine !== engine) { return; }
    try {
      this.invalidateSnapshot();
      engine.play();
      if (this.background) { this.startBackground(); }
      this.refresh();
    } catch (_) { this.fail('播放控制失败'); }
  }

  private releaseFocus(): void {
    this.focusActivatedRevision = -1;
    const work: Promise<void> = PlayController.focusQueue.then(async (): Promise<void> => {
      if (PlayController.focusOwner !== this.owner) { return; }
      PlayController.focusOwner = '';
      try { await this.focusManager.deactivateAudioSession(); }
      catch (_) { console.warn('[PiliMini-focus] deactivation failed'); }
    });
    PlayController.focusQueue = work.catch((): void => {});
  }

  private onBackground(): void {
    this.commitPosition(); this.invalidateSnapshot();
    this.background = true; this.state.background = true; this.savePosition(true);
    if (this.history !== undefined) { this.history.flush(); }
    this.checkCastAccount();
    if (this.castSession !== undefined) { this.castSession.setBackground(true); }
    if (this.castHeld) {
      this.updateCastBackground(); this.emit(); return;
    }
    if (this.visible && this.state.wanted && this.engine !== undefined) { this.startBackground(); }
    else if (this.visible && this.state.state === 'paused') { this.stopBackgroundVideo(); }
    this.scheduleRefresh();
    this.emit();
  }
  private async startBackground(): Promise<void> {
    if (this.castHeld) { this.updateCastBackground(); return; }
    const generation: number = this.generation;
    await BgAudio.start(this.ctx, this.owner);
    if (!this.current(generation) || !this.background || !this.state.wanted) { return; }
    this.clearBackgroundTimer();
    this.backgroundTimer = setTimeout((): void => {
      this.backgroundTimer = -1;
      if (!this.current(generation) || !this.background || !this.state.wanted || this.engine === undefined) { return; }
      this.stopBackgroundVideo();
    }, 10000);
  }
  private stopBackgroundVideo(): void {
    if (!this.background || this.disposed || !this.visible || this.engine === undefined ||
      !this.state.loaded || this.state.audioOnly) { return; }
    try {
      this.commitPosition(); this.invalidateSnapshot();
      this.clearRestore(); this.engine.video(false); this.state.audioOnly = true; this.emit();
      console.info('[PiliMini-mpv] audio-only paused=' + (!this.state.wanted).toString());
    } catch (error) { console.warn('[PiliMini-mpv] audio-only unavailable'); }
  }
  private onForeground(): void {
    this.commitPosition(); this.invalidateSnapshot();
    this.background = false; this.state.background = false; this.clearBackgroundTimer(); BgAudio.stop(this.owner);
    if (this.disposed || !this.visible) { return; }
    this.readSystemVolume();
    this.checkCastAccount();
    if (this.castSession !== undefined) { this.castSession.setBackground(false); }
    if (this.castHeld) { this.emit(); return; }
    if (this.state.audioOnly && this.engine !== undefined) {
      this.state.audioOnly = false; this.restoring = true; this.restoreAttempt = 0;
      try {
        // 重开视频轨时mpv会立刻出声但画面要等重新配置；先停住声音，出图后整段一起起播。
        this.engine.pause();
        this.engine.video(true);
        this.setState(this.state.wanted ? 'loading' : 'paused');
        this.waitRestore();
      } catch (error) { this.restoreMedia(); }
    }
    this.refresh(); this.emit();
  }
  private waitRestore(): void {
    const generation: number = this.generation;
    if (this.restoreTimer !== -1) { clearTimeout(this.restoreTimer); }
    this.restoreTimer = setTimeout((): void => {
      this.restoreTimer = -1;
      if (this.current(generation) && !this.background && this.restoring) { this.restoreMedia(); }
    }, 4000);
  }
  private restoreMedia(): void {
    if (this.info === undefined || this.disposed || !this.visible || this.background) { return; }
    if (this.restoreAttempt++ > 0) { this.clearRestore(); this.retry('恢复画面失败'); return; }
    const position: number = this.position();
    const generation: number = ++this.generation;
    this.restoring = true; this.setState(this.state.wanted ? 'loading' : 'paused');
    this.open(this.info, position, generation).then((): void => { if (this.current(generation)) { this.waitRestore(); } });
  }
  private clearRestore(): void {
    if (this.restoreTimer !== -1) { clearTimeout(this.restoreTimer); this.restoreTimer = -1; }
    this.restoring = false;
  }
  private clearBackgroundTimer(): void {
    if (this.backgroundTimer !== -1) { clearTimeout(this.backgroundTimer); this.backgroundTimer = -1; }
  }

  suspend(): Promise<void> {
    if (this.disposed || !this.visible) { return this.nativeQueue; }
    this.startRequest++;
    const castClosing: Promise<void> = this.invalidateCast(true);
    this.commitPosition(); this.savePosition(true);
    if (this.history !== undefined) { this.history.flush(); }
    this.clearFocusResume();
    this.visible = false; this.generation++; this.surface = '';
    this.scheduleRefresh();
    this.clearBackgroundTimer(); this.clearRestore(); this.state.loaded = false;
    const released: Promise<void> = this.enqueue(async (): Promise<void> => { await castClosing; await this.closeEngine(); });
    BgAudio.release(this.owner);
    this.releaseFocus();
    return released;
  }
  resume(): void { if (!this.disposed) { this.visible = true; this.syncSystemVolume(); } }
  resumeSource(): void {
    if (!this.ready() || this.source === undefined) { return; }
    this.start(this.source, this.state.quality);
  }

  dispose(): Promise<void> {
    if (this.disposed) { return this.nativeQueue; }
    this.startRequest++;
    const castClosing: Promise<void> = this.invalidateCast(true);
    this.commitPosition(); this.savePosition(true);
    if (this.history !== undefined) { this.history.flush(); this.history = undefined; }
    this.clearFocusResume();
    this.disposed = true; this.generation++;
    this.clearBackgroundTimer(); this.clearRestore();
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (this.offBg !== undefined) { this.offBg(); this.offBg = undefined; }
    if (this.offFg !== undefined) { this.offFg(); this.offFg = undefined; }
    if (this.offLogout !== undefined) { this.offLogout(); this.offLogout = undefined; }
    if (this.focusSubscribed) {
      this.focusManager.off('audioSessionStateChanged', this.focusListener);
      this.focusSubscribed = false;
    }
    if (this.deviceSubscribed) {
      this.routing.off('deviceChange', this.deviceListener);
      this.deviceSubscribed = false;
    }
    if (this.volumeSubscribed) {
      this.volumeManager.off('streamVolumeChange', this.volumeListener);
      this.volumeSubscribed = false;
    }
    BgAudio.release(this.owner);
    this.releaseFocus();
    return this.enqueue(async (): Promise<void> => {
      await castClosing;
      await this.closeEngine();
      const stats = MpvEngine.stats();
      console.info('[PiliMini-mpv] disposed instances=' + stats.instances.toString() + ' threads=' + stats.eventThreads.toString());
    });
  }
}
