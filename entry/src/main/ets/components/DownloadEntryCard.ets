import { DlEntry } from '../model/download';
import { AsyncImage } from './AsyncImage';
import { qualityLabel, formatSize } from '../service/download_service';
import { formatDuration } from './VideoCard';

/** Nara DownloadPageItem/SeasonInfoItem：稳定key，进度不会销毁封面。 */
@Component
export struct DownloadEntryCard {
  @ObjectLink entry: DlEntry;
  @Prop selecting: boolean = false;
  @Prop selected: boolean = false;
  onOpen: () => void = () => {};
  onSelect: (selected: boolean) => void = () => {};
  onMenu: () => void = () => {};

  @Builder
  MoreButton() {
    if (!this.selecting) {
      Image($r('app.media.icon_more')).width(29).height(29).padding(5.5)
        .fillColor($r('app.color.text_secondary')).id('download_menu_' + this.entry.key)
        .onTouch((e: TouchEvent) => { e.stopPropagation(); }).onClick(() => { this.onMenu(); })
    }
  }

  build() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        AsyncImage({ src: this.entry.cover, w: 320, h: 200 })
        if (this.entry.tasks.length > 0) {
          Text(qualityLabel(this.entry.tasks[0].quality)).fontSize(10).fontColor(Color.White)
            .backgroundColor('#80000000').borderRadius(4).padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ top: 6, right: 6 })
          Text(this.entry.tasks.length > 1 ? this.entry.tasks.length.toString() + '个视频' : formatDuration(this.entry.tasks[0].duration))
            .fontSize(10).fontColor(Color.White).backgroundColor('#80000000').borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 }).position({ right: 6, bottom: 7 })
        }
        Stack({ alignContent: Alignment.Center }) {
          Stack({ alignContent: Alignment.Center }) {
            Circle().width(34).height(34).fill($r('app.color.card_bg')).opacity(0.8)
            Image($r('app.media.icon_done_all')).width(24).height(24).fillColor($r('app.color.brand_pink'))
          }.scale({ x: this.selecting && this.selected ? 1 : 0, y: this.selecting && this.selected ? 1 : 0 })
            .animation({ duration: 250, curve: Curve.EaseInOut })
        }.width('100%').height('100%').backgroundColor('#99000000')
          .opacity(this.selecting && this.selected ? 1 : 0).animation({ duration: 200, curve: Curve.Linear })
          .hitTestBehavior(HitTestMode.None)
      }.width(160).height(100).borderRadius(6).clip(true)
        .backgroundColor($r('app.color.btn_soft_bg'))
      Column({ space: 6 }) {
        Text(this.entry.title).fontSize(14).lineHeight(19.88).letterSpacing(0.3).fontColor($r('app.color.text_primary'))
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        if (this.entry.progress < 0) {
          Row() {
            Text(this.entry.subtitle).fontSize(12).lineHeight(19.2).fontColor($r('app.color.text_secondary')).maxLines(1)
              .layoutWeight(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            this.MoreButton()
          }.width('100%').alignItems(VerticalAlign.Bottom)
        } else {
          Row({ space: 4 }) {
            Text(this.entry.statusText).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
              .layoutWeight(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.entry.tasks.length > 0 && this.entry.tasks[0].totalSize > 0) {
              Text(formatSize(this.entry.tasks[0].receivedSize) + '/' + formatSize(this.entry.tasks[0].totalSize))
                .fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
            }
            this.MoreButton()
          }.width('100%')
          Progress({ value: this.entry.progress, total: 100, type: ProgressType.Linear })
            .height(3).width('100%').color($r('app.color.brand_pink')).backgroundColor($r('app.color.divider'))
        }
      }.layoutWeight(1).height(100).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .id('download_entry_' + this.entry.key).onClick(() => { this.onOpen(); })
  }
}
