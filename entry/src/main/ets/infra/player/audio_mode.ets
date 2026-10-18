/** 单一播放 owner 的 AVSession 与后台任务；创建/销毁串行，迟到创建必达回收。 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { wantAgent, WantAgent, common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { loadImage } from '../image/image_loader';

export interface MediaCommands {
  play: () => void;
  pause: () => void;
  seek: (ms: number) => void;
  skip?: (ms: number) => void;
}

export class BgAudio {
  private static session: avSession.AVSession | undefined = undefined;
  private static ctx: common.UIAbilityContext | undefined = undefined;
  private static owner: string = '';
  private static running: boolean = false;
  private static wantsTask: boolean = false;
  private static want: WantAgent | undefined = undefined;
  private static queue: Promise<void> = Promise.resolve();
  private static metadata: avSession.AVMetadata | undefined = undefined;
  private static cover: string = '';
  private static coverGeneration: number = 0;

  private static enqueue(work: () => Promise<void>): Promise<void> {
    const next: Promise<void> = BgAudio.queue.then(work);
    BgAudio.queue = next.catch((e: Error): void => { console.warn('[BgAudio] ' + e.message); });
    return BgAudio.queue;
  }

  static claim(ctx: common.UIAbilityContext, owner: string, title: string, assetId: string,
    commands: MediaCommands, artist: string = '', cover: string = ''): Promise<void> {
    BgAudio.owner = owner;
    BgAudio.wantsTask = false;
    return BgAudio.enqueue(async (): Promise<void> => {
      await BgAudio.teardown();
      if (BgAudio.owner !== owner) { return; }
      BgAudio.ctx = ctx;
      const s: avSession.AVSession = await avSession.createAVSession(ctx, 'pilimini', 'audio');
      BgAudio.session = s;
      if (BgAudio.owner !== owner) { await BgAudio.teardown(); return; }
      const current = (): boolean => BgAudio.owner === owner && BgAudio.session === s;
      s.on('play', (): void => { if (current()) { commands.play(); } });
      s.on('pause', (): void => { if (current()) { commands.pause(); } });
      s.on('stop', (): void => { if (current()) { commands.pause(); } });
      s.on('seek', (ms: number): void => { if (current() && Number.isFinite(ms)) { commands.seek(ms); } });
      if (commands.skip !== undefined) {
        s.on('fastForward', (): void => { if (current()) { commands.skip!(10000); } });
        s.on('rewind', (): void => { if (current()) { commands.skip!(-10000); } });
      }
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: ctx.abilityInfo.bundleName, abilityName: ctx.abilityInfo.name }],
        actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      BgAudio.want = await wantAgent.getWantAgent(info);
      if (!current()) { await BgAudio.teardown(); return; }
      await s.setLaunchAbility(BgAudio.want);
      if (!current()) { await BgAudio.teardown(); return; }
      BgAudio.metadata = { assetId: assetId, title: title, artist: artist, duration: 0,
        skipIntervals: avSession.SkipIntervals.SECONDS_10 };
      await s.setAVMetadata(BgAudio.metadata);
      if (BgAudio.owner !== owner) { await BgAudio.teardown(); return; }
      await s.activate();
      if (!current()) { await BgAudio.teardown(); return; }
      BgAudio.loadCover(owner, s, assetId, cover);
    });
  }

  static start(ctx: common.UIAbilityContext, owner: string): Promise<void> {
    if (BgAudio.owner !== owner) { return Promise.resolve(); }
    BgAudio.wantsTask = true;
    return BgAudio.enqueue(async (): Promise<void> => {
      if (BgAudio.owner !== owner || !BgAudio.wantsTask || BgAudio.running) { return; }
      if (BgAudio.want === undefined) {
        const info: wantAgent.WantAgentInfo = {
          wants: [{ bundleName: ctx.abilityInfo.bundleName, abilityName: ctx.abilityInfo.name }],
          actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        BgAudio.want = await wantAgent.getWantAgent(info);
      }
      if (BgAudio.owner !== owner || !BgAudio.wantsTask) { return; }
      await backgroundTaskManager.startBackgroundRunning(ctx, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        BgAudio.want as WantAgent);
      BgAudio.running = true;
      if (BgAudio.owner !== owner || !BgAudio.wantsTask) { await BgAudio.stopTask(); }
    });
  }

  static setState(owner: string, playing: boolean, position: number, duration: number, speed: number,
    buffering: boolean = false): Promise<void> {
    return BgAudio.enqueue(async (): Promise<void> => {
      const s: avSession.AVSession | undefined = BgAudio.session;
      if (BgAudio.owner !== owner || s === undefined) { return; }
      await s.setAVPlaybackState({
        state: buffering ? avSession.PlaybackState.PLAYBACK_STATE_BUFFERING :
          (playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE),
        position: { elapsedTime: Math.floor(position), updateTime: Date.now() },
        duration: Math.floor(duration), speed: speed
      });
    });
  }

  static updateMetadata(owner: string, title: string, assetId: string, duration: number,
    artist: string = '', cover: string = ''): Promise<void> {
    return BgAudio.enqueue(async (): Promise<void> => {
      const s: avSession.AVSession | undefined = BgAudio.session;
      if (BgAudio.owner !== owner || s === undefined) { return; }
      const previous: avSession.AVMetadata | undefined = BgAudio.metadata;
      const sameMedia: boolean = previous !== undefined && previous.assetId === assetId;
      if (sameMedia && previous!.title === title && previous!.artist === artist &&
        previous!.duration === Math.floor(duration) && BgAudio.cover === cover) { return; }
      const meta: avSession.AVMetadata = { assetId: assetId, title: title, artist: artist,
        duration: Math.max(0, Math.floor(duration)), skipIntervals: avSession.SkipIntervals.SECONDS_10 };
      if (sameMedia && BgAudio.cover === cover && previous!.mediaImage !== undefined) {
        meta.mediaImage = previous!.mediaImage;
      }
      await s.setAVMetadata(meta);
      BgAudio.metadata = meta;
      if (!sameMedia || BgAudio.cover !== cover) { BgAudio.loadCover(owner, s, assetId, cover); }
    });
  }

  /** 复用图片LRU；不独占、不release共享PixelMap；下载不阻塞会话释放。 */
  private static loadCover(owner: string, s: avSession.AVSession, assetId: string, cover: string): void {
    BgAudio.cover = cover;
    const generation: number = ++BgAudio.coverGeneration;
    if (cover.length === 0) { return; }
    loadImage(cover, 480, 270).then((pm: image.PixelMap): void => {
      BgAudio.enqueue(async (): Promise<void> => {
        const meta: avSession.AVMetadata | undefined = BgAudio.metadata;
        if (BgAudio.owner !== owner || BgAudio.session !== s || BgAudio.coverGeneration !== generation ||
          meta === undefined || meta.assetId !== assetId) { return; }
        const updated: avSession.AVMetadata = { assetId: meta.assetId, title: meta.title, artist: meta.artist,
          duration: meta.duration, skipIntervals: meta.skipIntervals, mediaImage: pm };
        await s.setAVMetadata(updated);
        BgAudio.metadata = updated;
      });
    }).catch((): void => { console.warn('[BgAudio] 媒体封面加载失败'); });
  }

  static stop(owner: string): Promise<void> {
    if (BgAudio.owner !== owner) { return Promise.resolve(); }
    BgAudio.wantsTask = false;
    return BgAudio.enqueue(async (): Promise<void> => {
      if (!BgAudio.wantsTask) { await BgAudio.stopTask(); }
    });
  }

  static release(owner: string): Promise<void> {
    if (BgAudio.owner !== owner) { return Promise.resolve(); }
    BgAudio.owner = '';
    BgAudio.wantsTask = false;
    return BgAudio.enqueue(async (): Promise<void> => { await BgAudio.teardown(); });
  }

  private static async stopTask(): Promise<void> {
    if (BgAudio.running && BgAudio.ctx !== undefined) {
      await backgroundTaskManager.stopBackgroundRunning(BgAudio.ctx);
      BgAudio.running = false;
    }
  }

  /** destroy只销毁会话；先off删除NAPI持有的回调引用，避免保留旧播放器/页面。 */
  private static removeListeners(s: avSession.AVSession): void {
    const removals: (() => void)[] = [
      () => { s.off('play'); }, () => { s.off('pause'); }, () => { s.off('stop'); },
      () => { s.off('seek'); }, () => { s.off('fastForward'); }, () => { s.off('rewind'); }
    ];
    for (let i: number = 0; i < removals.length; i++) {
      try { removals[i](); }
      catch (_) { console.warn('[BgAudio] 会话控制监听解绑失败'); }
    }
  }

  private static async teardown(): Promise<void> {
    const s: avSession.AVSession | undefined = BgAudio.session;
    BgAudio.session = undefined;
    BgAudio.metadata = undefined;
    BgAudio.cover = '';
    BgAudio.coverGeneration++;
    BgAudio.want = undefined;
    if (s !== undefined) { BgAudio.removeListeners(s); }
    try { await BgAudio.stopTask(); } finally {
      if (s !== undefined) { try { await s.deactivate(); } finally { await s.destroy(); } }
    }
  }

  static isRunning(): boolean { return BgAudio.running; }
}
