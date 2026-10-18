import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { NativePlayerEvent, NativePlayerSnapshot } from 'libpilimini_player.so';
import { MpvEngine } from './mpv_engine';
import { BgAudio } from './audio_mode';
import { PlaybackHistory } from './playback_history';
import { VideoService, PlayInfo, PlayQuality } from '../../service/video_service';
import { AuthService } from '../../service/auth_service';
import { PlaybackPos } from '../storage/playback_pos';
import { prefsGet } from '../storage/prefs';
import { onAppBackground, onAppForeground } from '../event/app_events';

export interface PlaybackSource {
  bvid: string; cid: number; localPath: string;
  title: string; artist: string; cover: string;
}

export class PlaybackSnapshot {
  state: string = 'idle';
  position: number = 0;
  duration: number = 0;
  speed: number = 1;
  volume: number = 1;
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
  private hardware: boolean = true;
  private p1080: boolean = true;
  private timer: number = -1;
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
  private focusPaused: boolean = false;
  private pendingSeek: number = -1;
  private seekStarted: boolean = false;
  private seekAt: number = 0;
  private focusManager: audio.AudioSessionManager = audio.getAudioManager().getSessionManager();
  private routing: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
  private offBg: (() => void) | undefined = undefined;
  private offFg: (() => void) | undefined = undefined;
  private readonly focusListener = (event: audio.AudioSessionStateChangedEvent): void => {
    const hint: audio.AudioSessionStateChangeHint = event.stateChangeHint;
    if (hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE) {
      this.focusPaused = this.state.wanted;
      this.setWanted(false, false);
    } else if (hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_RESUME) {
      if (this.focusPaused) { this.focusPaused = false; this.setWanted(true, false); }
    } else if (hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_STOP ||
      hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_TIME_OUT_STOP) {
      this.focusPaused = false;
      this.setWanted(false, false);
    }
  };
  private readonly deviceListener = (event: audio.DeviceChangeAction): void => {
    if (event.type === audio.DeviceChangeType.DISCONNECT && this.state.wanted) { this.setWanted(false); }
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
    const volume: number = parseFloat(await prefsGet('setting_player_volume', '1'));
    if (this.disposed) { return; }
    this.state.quality = Number.isFinite(qn) && qn > 0 ? qn : 80;
    this.state.volume = Number.isFinite(volume) ? Math.max(0, Math.min(1, volume)) : 1;
    this.initialized = true;
    this.offBg = onAppBackground((): void => { this.onBackground(); });
    this.offFg = onAppForeground((): void => { this.onForeground(); });
    this.focusManager.setAudioSessionScene(audio.AudioSessionScene.AUDIO_SESSION_SCENE_MEDIA);
    this.focusManager.on('audioSessionStateChanged', this.focusListener);
    this.focusSubscribed = true;
    this.routing.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG, this.deviceListener);
    this.deviceSubscribed = true;
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
    if (this.disposed || !this.visible || this.engine === undefined ||
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
      skip: (ms: number): void => { this.seek(this.position() + ms); }
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
    BgAudio.setState(this.owner, this.state.wanted && this.state.state !== 'completed' && this.state.state !== 'error',
      this.state.position, this.state.duration, this.state.speed, this.state.state === 'loading');
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
    const previous: PlaybackSource | undefined = this.source;
    const same: boolean = preserve && previous !== undefined && previous.bvid === source.bvid &&
      previous.cid === source.cid && previous.localPath === source.localPath;
    if (this.history !== undefined) { this.history.flush(); }
    if (previous === undefined || previous.bvid !== source.bvid || previous.cid !== source.cid) {
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
      let info: PlayInfo;
      let start: number = position;
      if (source.localPath.length > 0) {
        info = { videoUrl: 'file://' + source.localPath, audioUrl: '', videoBackup: [], audioBackup: [],
          qualities: [], currentQn: 0, durationMs: 0, isDash: false };
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
      const engine: MpvEngine = new MpvEngine(this.surface, this.hardware, (event: NativePlayerEvent): void => {
        if (this.current(generation) && this.engine === engine) { this.onEvent(event); }
      });
      this.engine = engine;
      this.pendingSeek = -1; this.seekStarted = false;
      this.audioMissingAt = 0;
      this.state.loaded = false;
      this.state.position = position;
      this.prepareAt = Date.now();
      if (this.surfaceW > 0 && this.surfaceH > 0) { engine.resize(this.surfaceW, this.surfaceH); }
      engine.speed(this.state.speed); engine.volume(this.state.volume);
      engine.load(info.videoUrl, info.isDash ? info.audioUrl : '', position, !this.state.wanted);
      if (this.background && this.state.wanted) { this.startBackground(); }
      this.scheduleRefresh();
      this.emit();
    }, generation);
  }

  private onEvent(event: NativePlayerEvent): void {
    if (event.type === 'video-output-error') { this.fail('视频画面初始化失败，请返回后重试'); return; }
    if (event.type === 'error') { this.retry('播放失败（' + event.code.toString() + '）'); return; }
    if (event.type === 'command-error') {
      if (!this.state.loaded) { this.retry('媒体加载失败（' + event.code.toString() + '）'); }
      return;
    }
    if (event.type === 'loaded') {
      this.state.loaded = true;
      if (this.engine !== undefined) {
        if (this.state.wanted) { this.engine.play(); this.activateFocus(); }
        else { this.engine.pause(); if (this.background) { this.stopBackgroundVideo(); } }
      }
    }
    if (event.type === 'seek' && this.pendingSeek >= 0) { this.seekStarted = true; }
    if (event.type === 'restart' && this.pendingSeek >= 0 && this.seekStarted && this.engine !== undefined) {
      const native: NativePlayerSnapshot = this.engine.snapshot();
      if (!native.seeking && Math.abs(native.position - this.pendingSeek) < 2000) { this.pendingSeek = -1; }
    }
    if (event.type === 'ended') {
      if (this.pendingSeek < 0) { this.finishPlayback(this.audioMissingAt > 0); }
      return;
    }
    this.refresh();
    if (this.restoring && event.type === 'restart' && this.engine !== undefined &&
      this.engine.snapshot().outputReady) { this.clearRestore(); this.refresh(); }
  }

  private refresh(): void {
    if (this.disposed || !this.visible || this.engine === undefined ||
      this.state.state === 'error' || this.state.state === 'completed') { return; }
    try {
      if (!this.state.loaded) {
        if (Date.now() - this.prepareAt > 20000) { this.retry('播放准备超时'); }
        return;
      }
      const diagnostic: boolean = Date.now() - this.lastDiagnosticAt >= (this.background ? 60000 : 30000);
      const native: NativePlayerSnapshot = this.engine.snapshot(diagnostic);
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
      }
      if (diagnostic) {
        this.lastDiagnosticAt = Date.now();
        const stats = MpvEngine.stats();
        console.info('[PiliMini-mpv] clock syncValid=' + native.syncValid + ' avMs=' +
          native.avSyncMs.toFixed(2) + ' output=' + native.outputReady + ' decoder=' + native.decoder +
          ' video=' + native.videoEnabled + ' codec=' + native.videoCodec +
          ' audio=' + native.audioReady +
          ' cacheBytes=' + Math.floor(native.cacheBytes).toString() +
          ' instances=' + stats.instances.toString() + ' threads=' + stats.eventThreads.toString());
      }
      if (this.pendingSeek >= 0 && Date.now() - this.seekAt > 8000) { this.pendingSeek = -1; this.retry('定位播放进度超时'); return; }
      if (!native.seeking && this.pendingSeek < 0) { this.state.position = Math.max(0, native.position); }
      if (native.duration > 0) { this.state.duration = native.duration; }
      if (native.width > 0 && native.height > 0) { this.state.width = native.width; this.state.height = native.height; }
      this.state.bufferPercent = this.state.duration > 0 ? Math.min(100,
        Math.max(this.state.position, native.buffered) / this.state.duration * 100) : 0;
      if (native.ended && !native.seeking && this.pendingSeek < 0) { this.finishPlayback(!native.audioReady); return; }
      this.setState(!this.state.wanted ? 'paused' :
        (native.buffering || native.seeking || this.pendingSeek >= 0 || this.restoring ? 'loading' : 'playing'));
      if (this.history !== undefined) {
        this.history.observe(native.position, this.state.state === 'playing', native.seeking || this.pendingSeek >= 0,
          this.state.state === 'paused', this.background);
      }
      this.savePosition(false);
      if (Date.now() - this.lastSessionAt >= (this.background ? 30000 : 15000)) { this.syncSession(); }
    } catch (error) { this.retry('播放器状态异常'); }
    finally { this.scheduleRefresh(); }
  }

  private position(): number {
    if (this.pendingSeek >= 0) { return this.pendingSeek; }
    if (this.engine !== undefined && this.state.loaded) {
      try { const native: NativePlayerSnapshot = this.engine.snapshot();
        if (!native.seeking && native.position >= 0) { return native.position; }
      } catch (error) {}
    }
    return this.state.position;
  }

  toggle(): void {
    if (this.state.state === 'completed') { this.seek(0); this.setWanted(true); }
    else { this.setWanted(!this.state.wanted); }
  }

  setWanted(wanted: boolean, user: boolean = true): void {
    if (this.disposed || !this.visible) { return; }
    if (user) { this.focusPaused = false; }
    this.state.wanted = wanted;
    this.state.position = this.position();
    if (this.engine !== undefined) {
      try {
        if (wanted) {
          if (this.state.state === 'completed') { this.seek(0); }
          this.engine.play(); this.activateFocus();
          if (this.background) { this.startBackground(); }
        } else {
          this.engine.pause(); this.clearBackgroundTimer(); BgAudio.stop(this.owner);
          if (this.background) { this.stopBackgroundVideo(); }
        }
      } catch (error) { this.fail('播放控制失败'); return; }
    }
    this.savePosition(true);
    this.setState(wanted ? 'loading' : 'paused');
    this.refresh();
    if (!wanted && this.history !== undefined) { this.history.flush(); }
  }

  seek(ms: number): void {
    if (this.disposed || !this.visible || this.engine === undefined || !this.state.loaded || !Number.isFinite(ms)) { return; }
    const target: number = Math.max(0, Math.min(ms, Math.max(0, this.state.duration - 1000)));
    try {
      this.pendingSeek = target; this.seekStarted = false; this.seekAt = Date.now();
      this.engine.seek(target);
      this.state.position = target;
      if (this.state.state === 'completed') { this.state.wanted = false; }
      this.setState(this.state.wanted ? 'loading' : 'paused');
      this.syncSession();
      this.scheduleRefresh();
    } catch (error) { this.fail('定位播放进度失败'); }
  }

  speed(value: number): void {
    if (!Number.isFinite(value) || value < 0.25 || value > 5 || this.disposed) { return; }
    this.state.speed = value;
    if (this.engine !== undefined) { this.engine.speed(value); }
    this.syncSession(); this.emit();
  }
  volume(value: number): void {
    if (!Number.isFinite(value) || this.disposed) { return; }
    this.state.volume = Math.max(0, Math.min(1, value));
    if (this.engine !== undefined) { this.engine.volume(this.state.volume); }
    this.emit();
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
    this.state.wanted = false;
    this.state.position = this.state.duration;
    if (this.history !== undefined) { this.history.complete(); }
    this.clearBackgroundTimer(); this.clearRestore();
    BgAudio.stop(this.owner); this.savePosition(true); this.setState('completed'); this.scheduleRefresh();
  }
  private fail(message: string): void {
    this.state.wanted = false; this.state.error = message;
    if (this.history !== undefined) { this.history.flush(); }
    this.clearBackgroundTimer(); this.clearRestore();
    if (this.engine !== undefined) { try { this.engine.pause(); } catch (error) {} }
    BgAudio.stop(this.owner); this.savePosition(true); this.setState('error'); this.scheduleRefresh();
  }

  private savePosition(force: boolean): void {
    const source: PlaybackSource | undefined = this.source;
    const ms: number = this.state.position;
    if (source === undefined || source.localPath.length > 0 || ms <= 0 || this.state.duration <= 0) { return; }
    if (ms > this.state.duration - 10000) {
      if (this.lastSaved !== -1) {
        this.lastSaved = -1;
        PlaybackPos.clearIfFinished(source.bvid, source.cid, ms, this.state.duration);
      }
      return;
    }
    if (force || Date.now() - this.lastSavedAt >= (this.background ? 30000 : 15000)) {
      this.lastSaved = ms; this.lastSavedAt = Date.now();
      if (force) { PlaybackPos.flush(source.bvid, source.cid, ms); }
      else { PlaybackPos.save(source.bvid, source.cid, ms); }
    }
  }

  private activateFocus(): void {
    const generation: number = this.generation;
    this.focusManager.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT })
      .catch((): void => { if (this.current(generation)) { this.setWanted(false, false); } });
  }

  private onBackground(): void {
    this.background = true; this.state.background = true; this.savePosition(true);
    if (this.history !== undefined) { this.history.flush(); }
    if (this.visible && this.state.wanted && this.engine !== undefined) { this.startBackground(); }
    else if (this.visible && this.state.state === 'paused') { this.stopBackgroundVideo(); }
    this.scheduleRefresh();
    this.emit();
  }
  private async startBackground(): Promise<void> {
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
      this.clearRestore(); this.engine.video(false); this.state.audioOnly = true; this.emit();
      console.info('[PiliMini-mpv] audio-only paused=' + (!this.state.wanted).toString());
    } catch (error) { console.warn('[PiliMini-mpv] audio-only unavailable'); }
  }
  private onForeground(): void {
    this.background = false; this.state.background = false; this.clearBackgroundTimer(); BgAudio.stop(this.owner);
    if (this.disposed || !this.visible) { return; }
    if (this.state.audioOnly && this.engine !== undefined) {
      this.state.audioOnly = false; this.restoring = true; this.restoreAttempt = 0;
      try { this.engine.video(true); this.waitRestore(); }
      catch (error) { this.restoreMedia(); }
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
    this.state.position = this.position(); this.savePosition(true);
    if (this.history !== undefined) { this.history.flush(); }
    this.visible = false; this.generation++; this.surface = '';
    this.scheduleRefresh();
    this.clearBackgroundTimer(); this.clearRestore(); this.state.loaded = false;
    const released: Promise<void> = this.enqueue(async (): Promise<void> => { await this.closeEngine(); });
    BgAudio.release(this.owner);
    this.focusManager.deactivateAudioSession().catch(() => {});
    return released;
  }
  resume(): void { if (!this.disposed) { this.visible = true; } }
  resumeSource(): void {
    if (!this.ready() || this.source === undefined) { return; }
    this.start(this.source, this.state.quality);
  }

  dispose(): Promise<void> {
    if (this.disposed) { return this.nativeQueue; }
    this.state.position = this.position(); this.savePosition(true);
    if (this.history !== undefined) { this.history.flush(); this.history = undefined; }
    this.disposed = true; this.generation++;
    this.clearBackgroundTimer(); this.clearRestore();
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (this.offBg !== undefined) { this.offBg(); this.offBg = undefined; }
    if (this.offFg !== undefined) { this.offFg(); this.offFg = undefined; }
    if (this.focusSubscribed) {
      this.focusManager.off('audioSessionStateChanged', this.focusListener);
      this.focusSubscribed = false;
    }
    if (this.deviceSubscribed) {
      this.routing.off('deviceChange', this.deviceListener);
      this.deviceSubscribed = false;
    }
    BgAudio.release(this.owner);
    this.focusManager.deactivateAudioSession().catch(() => {});
    return this.enqueue(async (): Promise<void> => {
      await this.closeEngine();
      const stats = MpvEngine.stats();
      console.info('[PiliMini-mpv] disposed instances=' + stats.instances.toString() + ' threads=' + stats.eventThreads.toString());
    });
  }
}
