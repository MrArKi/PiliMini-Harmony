import { CookieStore } from '../cookie/cookie_store';
import { HistoryService } from '../../service/history_service';

/** 每个BV/CID的真实播放采样；无定时器、无页面引用，退出仅补发已确认位置。 */
export class PlaybackHistory {
  private readonly bvid: string;
  private readonly cid: number;
  private readonly session: Promise<string>;
  private started: boolean = false;
  private confirmedSeconds: number = 0;
  private queuedSeconds: number = 0;
  private queuedAt: number = 0;

  constructor(bvid: string, cid: number) {
    this.bvid = bvid;
    this.cid = cid;
    this.session = CookieStore.getRaw().catch((): string => '');
  }

  observe(ms: number, playing: boolean, seeking: boolean, paused: boolean, background: boolean = false): void {
    if (seeking || !Number.isFinite(ms) || ms < 0) { return; }
    const seconds: number = Math.floor(ms / 1000);
    if (playing && seconds > 0) { this.started = true; }
    this.confirmedSeconds = seconds;
    if (!this.started || seconds <= 0) { return; }
    const now: number = Date.now();
    const interval: number = background ? 30000 : 15000;
    // 暂停seek原生确认后立即补报；正常播放同时按位置和墙钟节流。
    if (paused || (playing && (this.queuedSeconds === 0 || this.queuedSeconds === -1 ||
      (Math.abs(seconds - this.queuedSeconds) >= interval / 1000 && now - this.queuedAt >= interval)))) {
      this.send(seconds);
    }
  }

  flush(): void {
    if (this.started && this.queuedSeconds !== -1 && this.confirmedSeconds > 0) {
      this.send(this.confirmedSeconds);
    }
  }

  complete(): void {
    if (this.started) { this.send(-1); }
  }

  private send(seconds: number): void {
    if (seconds === this.queuedSeconds) { return; }
    this.queuedSeconds = seconds;
    this.queuedAt = Date.now();
    HistoryService.report(this.bvid, this.cid, seconds, this.session);
  }
}
