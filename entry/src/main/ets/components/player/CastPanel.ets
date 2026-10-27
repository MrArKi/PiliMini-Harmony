/** DLNA投屏面板内容；宿主负责bindSheet、发现与会话生命周期。 */
import { CastSnapshot, DlnaDevice } from '../../model/cast';

function castTime(ms: number): string {
  const seconds: number = Number.isFinite(ms) ? Math.max(0, Math.floor(ms / 1000)) : 0;
  const minutes: number = Math.floor(seconds / 60);
  const remain: string = (seconds % 60).toString();
  const minuteText: string = (minutes % 60).toString();
  const tail: string = (minuteText.length < 2 ? '0' : '') + minuteText + ':' + (remain.length < 2 ? '0' : '') + remain;
  return minutes >= 60 ? Math.floor(minutes / 60).toString() + ':' + tail : tail;
}

@Component
export struct CastPanel {
  @Prop @Watch('onSnapshotChanged') snapshot: CastSnapshot = new CastSnapshot();
  onSelect: () => void = () => {};
  onSelectDevice: (id: string) => void = () => {};
  onPlay: () => void = () => {};
  onPause: () => void = () => {};
  onSeek: (ms: number) => void = () => {};
  onDisconnect: () => void = () => {};
  onResumeLocal: () => void = () => {};
  onClose: () => void = () => {};

  @State private draftPosition: number = 0;
  @State private dragging: boolean = false;
  private previousPhase: string = 'idle';

  aboutToAppear(): void { this.onSnapshotChanged(); }

  private busy(): boolean {
    return this.snapshot.phase === 'idle' || this.snapshot.phase === 'preparing' || this.snapshot.phase === 'connecting';
  }

  private onSnapshotChanged(): void {
    if (!this.snapshot.remote || !this.snapshot.canSeek || this.previousPhase !== this.snapshot.phase) {
      this.dragging = false;
    }
    if (!this.dragging) { this.draftPosition = this.clampPosition(this.snapshot.position); }
    this.previousPhase = this.snapshot.phase;
  }

  private clampPosition(value: number): number {
    const position: number = Number.isFinite(value) ? Math.max(0, value) : 0;
    return this.snapshot.duration > 0 ? Math.min(position, this.snapshot.duration) : position;
  }

  private statusText(): string {
    if (this.snapshot.phase === 'idle' || this.snapshot.phase === 'preparing') { return '正在准备投屏…'; }
    if (this.snapshot.phase === 'selecting') { return '请选择播放设备'; }
    if (this.snapshot.phase === 'connecting') { return '正在连接…'; }
    if (this.snapshot.phase === 'playing') { return '正在播放'; }
    if (this.snapshot.phase === 'paused') { return '已暂停'; }
    if (this.snapshot.phase === 'ended') { return '已播放完毕'; }
    if (this.snapshot.phase === 'disconnected') { return '已断开连接'; }
    if (this.snapshot.phase === 'error') { return '投屏未成功'; }
    return '请选择播放设备';
  }

  private messageText(): string {
    if (this.snapshot.message === this.statusText()) { return ''; }
    if (this.snapshot.message.length > 0) { return this.snapshot.message; }
    if (this.snapshot.phase === 'idle') { return ''; }
    if (this.snapshot.phase === 'disconnected') { return this.canResumeLocal() ? '手机已暂停，可继续观看' : ''; }
    if (this.snapshot.phase === 'error') { return '请重试或选择其他设备'; }
    return '';
  }

  private showPlayback(): boolean {
    return this.snapshot.remote && (this.snapshot.phase === 'playing' || this.snapshot.phase === 'paused' ||
      this.snapshot.phase === 'ended');
  }

  private canResumeLocal(): boolean {
    return this.snapshot.localHeld || this.snapshot.remote;
  }

  private visibleDevices(): DlnaDevice[] { return this.snapshot.devices.slice(0, 32); }

  private selectDevice(id: string): void {
    if (!this.snapshot.selection || this.snapshot.phase === 'connecting' || this.snapshot.phase === 'preparing') { return; }
    // 只回传本次快照仍存在的运行时ID，地址及网络参数不从UI提交。
    if (this.snapshot.devices.some((device: DlnaDevice): boolean => device.id === id)) { this.onSelectDevice(id); }
  }

  private selectText(): string {
    return this.snapshot.phase === 'error' ? '重试' : (this.snapshot.remote ? '更换设备' : '选择设备');
  }

  private changePosition(value: number, mode: SliderChangeMode): void {
    if (!this.showPlayback() || !this.snapshot.canSeek || this.snapshot.duration <= 0) { return; }
    this.draftPosition = this.clampPosition(value);
    if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
      this.dragging = true;
    } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.dragging = false;
      // 只在松手/点击提交一次，不随拖动持续请求远端。
      this.onSeek(Math.floor(this.draftPosition));
    }
  }

  @Builder
  DeviceSelection() {
    Column() {
      if (this.snapshot.devices.length > 0) {
        ForEach(this.visibleDevices(), (device: DlnaDevice) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 3 }) {
              Text(device.name.length > 0 ? device.name : '播放设备')
                .fontSize(16).fontColor($r('app.color.text_primary')).width('100%')
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(device.host).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 12 }).alignItems(HorizontalAlign.Start)
          }.width('100%').constraintSize({ minHeight: 72 }).padding(0).borderRadius(0)
            .backgroundColor(Color.Transparent).id('cast_device_' + device.id)
            .accessibilityText(device.name + '，' + device.host)
            .onClick((): void => { this.selectDevice(device.id); })
        }, (device: DlnaDevice): string => device.id)
      } else if (this.snapshot.discovering) {
        Text('正在搜索设备…').fontSize(14).fontColor($r('app.color.text_secondary'))
          .width('100%').textAlign(TextAlign.Center).padding({ top: 30, bottom: 30 }).id('cast_searching')
      } else {
        Column({ space: 16 }) {
          Text('没有设备').fontSize(14).fontColor($r('app.color.text_secondary')).id('cast_empty')
          Button('点击重试', { type: ButtonType.Normal })
            .fontSize(14).fontColor($r('app.color.brand_pink')).height(40).padding({ left: 22, right: 22 })
            .backgroundColor($r('app.color.comment_top_bg')).borderRadius(20)
            .id('cast_retry').onClick((): void => { this.onSelect(); })
        }.width('100%').height(210).justifyContent(FlexAlign.Center)
      }
    }.width('100%').id('cast_device_list')
  }

  @Builder
  DeviceStatus() {
    Row({ space: 14 }) {
      Row() {
        Image($r('app.media.icon_cast')).width(28).height(28).fillColor($r('app.color.brand_pink'))
      }
      .width(44).height(44).justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.comment_top_bg')).borderRadius(12)

      Column({ space: 3 }) {
        Text(this.snapshot.deviceName.length > 0 ? this.snapshot.deviceName : '投屏到电视')
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          .id('cast_device_name')
        Text(this.statusText()).fontSize(13).fontColor($r('app.color.text_secondary'))
          .width('100%').id('cast_status')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Center)
  }

  @Builder
  PlaybackControls() {
    Column() {
      Row() {
        Text(castTime(this.draftPosition)).fontSize(12).fontFamily('monospace')
          .fontColor($r('app.color.text_secondary')).id('cast_position')
        Blank()
        Text(castTime(this.snapshot.duration)).fontSize(12).fontFamily('monospace')
          .fontColor($r('app.color.text_secondary')).id('cast_duration')
      }.width('100%')
      if (this.snapshot.canSeek && this.snapshot.duration > 0) {
        Slider({ value: this.draftPosition, min: 0, max: this.snapshot.duration, step: 1000, style: SliderStyle.OutSet })
          .selectedColor($r('app.color.brand_pink')).trackColor($r('app.color.divider'))
          .blockColor($r('app.color.brand_pink')).trackThickness(3.5).blockSize({ width: 14, height: 14 })
          .height(34).width('100%').id('cast_seek').accessibilityText('投屏进度')
          .onChange((value: number, mode: SliderChangeMode): void => { this.changePosition(value, mode); })
      }
      if (this.snapshot.phase === 'playing' && this.snapshot.canPause) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Image($r('app.media.icon_pause')).width(19).height(19).fillColor($r('app.color.brand_pink'))
            Text('暂停').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.brand_pink'))
          }.justifyContent(FlexAlign.Center)
        }
        .width(132).height(42).padding(0).borderRadius(21).backgroundColor($r('app.color.comment_top_bg'))
        .margin({ top: 10 }).id('cast_pause').accessibilityText('暂停投屏')
        .onClick((): void => { this.onPause(); })
      } else if ((this.snapshot.phase === 'paused' || this.snapshot.phase === 'ended') && this.snapshot.canPlay) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Image(this.snapshot.phase === 'ended' ? $r('app.media.icon_replay') : $r('app.media.icon_player_play_rounded'))
              .width(19).height(19).fillColor($r('app.color.brand_pink'))
            Text(this.snapshot.phase === 'ended' ? '重新播放' : '继续播放')
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.brand_pink'))
          }.justifyContent(FlexAlign.Center)
        }
        .width(132).height(42).padding(0).borderRadius(21).backgroundColor($r('app.color.comment_top_bg'))
        .margin({ top: 10 }).id('cast_play').accessibilityText(this.snapshot.phase === 'ended' ? '重新投屏播放' : '继续投屏播放')
        .onClick((): void => { this.onPlay(); })
      }
    }.width('100%').margin({ top: 20 })
  }

  @Builder
  Actions() {
    Column({ space: 10 }) {
      if (!this.snapshot.selection && !this.busy()) {
        Button(this.selectText(), { type: ButtonType.Normal })
          .width('100%').height(44).padding({ left: 16, right: 16 }).borderRadius(22)
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.snapshot.remote || this.canResumeLocal() ? $r('app.color.text_primary') : Color.White)
          .backgroundColor(this.snapshot.remote || this.canResumeLocal() ? $r('app.color.btn_soft_bg') : $r('app.color.brand_pink'))
          .id('cast_select').onClick((): void => { this.onSelect(); })
      }
      if (this.snapshot.remote) {
        Button('断开连接', { type: ButtonType.Normal })
          .width('100%').height(44).padding({ left: 16, right: 16 }).borderRadius(22)
          .fontSize(14).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.btn_soft_bg'))
          .id('cast_disconnect').onClick((): void => { this.onDisconnect(); })
      }
      if (this.canResumeLocal()) {
        Button('在手机继续播放', { type: ButtonType.Normal })
          .width('100%').height(44).padding({ left: 16, right: 16 }).borderRadius(22)
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.snapshot.remote ? $r('app.color.text_primary') : Color.White)
          .backgroundColor(this.snapshot.remote ? $r('app.color.btn_soft_bg') : $r('app.color.brand_pink'))
          .id('cast_resume_local').onClick((): void => { this.onResumeLocal(); })
      }
    }.width('100%').margin({ top: 20 })
  }

  build() {
    Column() {
      Row() {
        Text('投屏').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        if (this.snapshot.selection) {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.icon_refresh')).width(20).height(20).fillColor($r('app.color.text_primary'))
          }.width(40).height(40).padding(0).backgroundColor(Color.Transparent).borderRadius(20)
            .enabled(this.snapshot.phase !== 'preparing' && this.snapshot.phase !== 'connecting')
            .id('cast_refresh').accessibilityText('重新搜索设备').onClick((): void => { this.onSelect(); })
        }
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.icon_clear')).width(20).height(20).fillColor($r('app.color.text_secondary'))
        }.width(40).height(40).padding(0).backgroundColor(Color.Transparent).borderRadius(20)
          .id('cast_close').accessibilityText('关闭投屏面板').onClick((): void => { this.onClose(); })
      }.width('100%').height(48).padding({ left: 20, right: 10 })
      if (this.busy() || this.snapshot.discovering) {
        // 原生扫描动效，无应用计时器；仅表达等待，不伪造取源/连接百分比。
        Progress({ value: 100, total: 100, type: ProgressType.Linear })
          .color($r('app.color.brand_pink')).backgroundColor($r('app.color.comment_top_bg'))
          .style({ strokeWidth: 2, enableScanEffect: true }).height(2).width('100%')
          .id('cast_loading').accessibilityText('正在等待投屏')
      } else {
        Blank().height(2)
      }
      Scroll() {
        Column() {
          if (this.snapshot.selection) {
            this.DeviceSelection()
          } else {
            Column() {
              this.DeviceStatus()
              if (this.showPlayback()) { this.PlaybackControls() }
            }.width('100%').padding({ left: 20, right: 20, top: 22 })
          }
          if (this.messageText().length > 0) {
            Text(this.messageText()).fontSize(13).fontColor($r('app.color.text_secondary'))
              .width('100%').padding({ left: 20, right: 20 }).margin({ top: 18 }).id('cast_message')
          }
          Column() { this.Actions() }.width('100%').padding({ left: 20, right: 20, bottom: 24 })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
    }.id('cast_panel').width('100%').height('100%').backgroundColor($r('app.color.card_bg'))
  }
}
