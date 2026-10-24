/** Nara HistoryItem：110vp横卡，原历史与服务端搜索共用。 */
import { AsyncImage } from '../AsyncImage';
import { HistoryItem } from '../../service/history_service';

function two(value: number): string { return value < 10 ? '0' + value.toString() : value.toString(); }

function historyDuration(seconds: number): string {
  const whole: number = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  const hours: number = Math.floor(whole / 3600);
  const time: string = two(Math.floor(whole / 60) % 60) + ':' + two(whole % 60);
  return hours > 0 ? two(hours) + ':' + time : time;
}

function historyTime(ts: number): string {
  if (ts <= 0) { return ''; }
  const date: Date = new Date(ts * 1000);
  const now: Date = new Date();
  const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const day: Date = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const time: string = two(date.getHours()) + ':' + two(date.getMinutes());
  if (day.getTime() === today.getTime()) { return '今天 ' + time; }
  const yesterday: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
  if (day.getTime() === yesterday.getTime()) { return '昨天 ' + time; }
  const prefix: string = now.getFullYear() === date.getFullYear() ? '' : date.getFullYear().toString() + '-';
  return prefix + two(date.getMonth() + 1) + '-' + two(date.getDate()) + ' ' + time;
}

@Component
export struct HistoryRow {
  @Prop item: HistoryItem;
  onOpen: (item: HistoryItem) => void = () => {};

  private progress(): number {
    return this.item.progress === -1 ? 100 : Math.max(0, Math.min(100, this.item.progress / this.item.duration * 100));
  }

  build() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        AsyncImage({ src: this.item.cover, w: 320, h: 200 })
        if (this.item.duration > 0) {
          Text(this.item.progress === -1 ? '已看完' : historyDuration(this.item.progress) + '/' + historyDuration(this.item.duration))
            .fontSize(11).lineHeight(11).fontWeight(FontWeight.Bold).fontColor(Color.White)
            .backgroundColor('#73000000').borderRadius(4).border({ width: 1, color: Color.Transparent })
            .padding({ left: 3, right: 3, top: 2, bottom: 2 }).margin({ right: 6, bottom: 8 })
          if (this.item.progress !== 0) {
            Stack({ alignContent: Alignment.BottomStart }) {
              Row() {
                Column().width(this.progress().toString() + '%').height(10).backgroundColor($r('app.color.brand_pink'))
                Blank()
              }.width('100%').height(10).backgroundColor($r('app.color.member_secondary_container'))
                .borderRadius({ bottomLeft: 10, bottomRight: 10 }).clip(true).position({ x: 0, y: -6 })
            }.width('100%').height(4).clip(true)
          }
        }
      }.width(160).height(100).borderRadius(10).clip(true).backgroundColor($r('app.color.btn_soft_bg'))
      Column({ space: 2 }) {
        Text(this.item.title).fontSize(14).lineHeight(20).letterSpacing(0.3)
          .fontColor($r('app.color.text_primary')).maxLines((this.item.videos || 1) > 1 ? 1 : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Blank()
        if (this.item.upName.length > 0) {
          Text(this.item.upName).fontSize(12).fontColor($r('app.color.nara_outline'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        Text(historyTime(this.item.viewAt)).fontSize(12).fontColor($r('app.color.nara_outline')).width('100%')
      }.layoutWeight(1).height(100).alignItems(HorizontalAlign.Start)
    }.width('100%').height(110).padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .alignItems(VerticalAlign.Top).onClick(() => { this.onOpen(this.item); })
  }
}
