import { KeyCode } from '@kit.InputKit';

/** Nara ProgressBar：基条、缓冲、已播和触点共用一条完整轨道，无系统Slider端部留白。 */
@Component
export struct PlayerProgressBar {
  @Prop value: number = 0;
  @Prop total: number = 0;
  @Prop buffered: number = 0;
  @Prop canSeek: boolean = false;
  onPreview: (value: number) => void = () => {};
  onSeek: (value: number) => void = () => {};
  @State private trackWidth: number = 0;
  @State private dragging: boolean = false;
  private pointer: number = -1;

  private fraction(): number {
    return this.total > 0 ? Math.min(1, Math.max(0, this.value / this.total)) : 0;
  }

  private timeAt(x: number): number {
    return this.trackWidth > 0 ? Math.max(0, Math.min(1, x / this.trackWidth)) * this.total : 0;
  }

  private touch(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) { this.cancel(); return; }
    if (!this.canSeek || this.total <= 0) { return; }
    if (event.type === TouchType.Down && this.pointer < 0 && event.changedTouches.length > 0) {
      this.pointer = event.changedTouches[0].id;
      this.dragging = true;
    }
    const points: TouchObject[] = event.changedTouches;
    for (let i: number = 0; i < points.length; i++) {
      if (points[i].id !== this.pointer) { continue; }
      if (event.type === TouchType.Up) {
        const value: number = this.timeAt(points[i].x);
        this.pointer = -1; this.dragging = false; this.onSeek(value); return;
      }
      this.onPreview(this.timeAt(points[i].x));
      return;
    }
  }

  private cancel(): void {
    this.pointer = -1; this.dragging = false; this.onPreview(-1);
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Rect().width('100%').height(3.5).radius(1.75).fill('#33FFFFFF')
        .hitTestBehavior(HitTestMode.None)
      Rect().width(Math.max(0, Math.min(100, this.buffered)).toString() + '%')
        .height(3.5).radius(1.75).fill('#66FB7299').hitTestBehavior(HitTestMode.None)
      Rect().width((this.fraction() * 100).toString() + '%')
        .height(3.5).radius(1.75).fill($r('app.color.brand_pink')).hitTestBehavior(HitTestMode.None)
      if (this.dragging) {
        Circle().width(50).height(50).fill('#50FB7299')
          .position({ x: this.trackWidth * this.fraction() - 25, y: -18 })
          .hitTestBehavior(HitTestMode.None)
      }
      Circle().width(14).height(14).fill($r('app.color.brand_pink'))
        .position({ x: this.trackWidth * this.fraction() - 7, y: 0 })
        .hitTestBehavior(HitTestMode.None)
    }
    .id('player-progress')
    .width('100%').height(14)
    .onAreaChange((_old: Area, area: Area): void => { this.trackWidth = Number(area.width); })
    .onTouch((event: TouchEvent): void => { this.touch(event); })
    .focusable(true)
    .accessibilityRole(AccessibilityRoleType.SLIDER)
    .accessibilityText('视频进度 ' + Math.round(this.fraction() * 100).toString() + '%')
    .onKeyEvent((event: KeyEvent): void => {
      if (!this.canSeek || event.type !== KeyType.Down) { return; }
      if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT || event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
        this.onSeek(Math.max(0, Math.min(this.total, this.value + (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT ? -5000 : 5000))));
        event.stopPropagation();
      }
    })
    .onDisAppear((): void => { this.cancel(); })
  }
}
