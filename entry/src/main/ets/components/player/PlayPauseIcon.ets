/** Nara AnimatedIcons.play_pause：同一Material关键帧、200ms线性可中断形变。 */
import { AnimatorResult } from '@kit.ArkUI';
import { playPauseCoordinates, playPauseOpacity } from './play_pause_frames';

@Component
export struct PlayPauseIcon {
  @Prop @Watch('updatePlaying') playing: boolean = false;
  @State progress: number = 0;
  private iconAnimator: AnimatorResult | undefined = undefined;
  private destroyed: boolean = false;
  private ready: boolean = false;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));

  aboutToAppear(): void { this.progress = this.playing ? 1 : 0; }
  aboutToDisappear(): void {
    this.destroyed = true;
    if (this.iconAnimator !== undefined) { this.iconAnimator.cancel(); this.iconAnimator = undefined; }
  }
  private updatePlaying(): void {
    if (this.destroyed) { return; }
    const from: number = this.progress;
    const target: number = this.playing ? 1 : 0;
    if (this.iconAnimator !== undefined) { this.iconAnimator.cancel(); }
    this.iconAnimator = this.getUIContext().createAnimator({ duration: Math.max(1, Math.round(200 * Math.abs(target - from))),
      easing: 'linear', delay: 0, fill: 'forwards', direction: 'normal', iterations: 1, begin: from, end: target });
    this.iconAnimator.onFrame = (value: number) => { if (!this.destroyed) { this.progress = value; this.draw(); } };
    this.iconAnimator.play();
  }
  private draw(): void {
    if (!this.ready || this.destroyed) { return; }
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.clearRect(0, 0, 20, 20);
    ctx.fillStyle = '#FFFFFF';
    for (let path: number = 0; path < 3; path++) {
      const points: number[] = playPauseCoordinates(path, this.progress);
      ctx.globalAlpha = playPauseOpacity(path, this.progress);
      ctx.beginPath();
      ctx.moveTo(points[0], points[1]);
      for (let i: number = 2; i < points.length; i += 6) {
        ctx.bezierCurveTo(points[i], points[i + 1], points[i + 2], points[i + 3], points[i + 4], points[i + 5]);
      }
      ctx.closePath();
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }
  build() {
    Canvas(this.context).width(20).height(20).hitTestBehavior(HitTestMode.None)
      .onReady(() => { this.ready = true; this.draw(); })
  }
}
