/** Nara video_panel：列表/动态详情/转发引用共用，详情标题不截断。 */
import { AsyncImage } from '../AsyncImage';
import { formatPlayCount } from '../VideoCard';
import { DynArchive } from '../../service/dynamic_service';

@Component
export struct DynamicVideoCard {
  @Prop archive: DynArchive;
  @Prop detail: boolean = false;

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        AsyncImage({ src: this.archive.cover, w: 640, h: 360 })

        Row({ space: 6 }) {
          if (this.archive.durationText.length > 0) {
            Text(this.archive.durationText)
              .fontSize(11).fontColor('#FFFFFF')
              .backgroundColor('#73000000').borderRadius(4)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
          Text(formatPlayCount(this.archive.play) + '播放').fontSize(11).fontColor('#FFFFFF')
          Text(formatPlayCount(this.archive.danmaku) + '弹幕').fontSize(11).fontColor('#FFFFFF')
          Blank()
          Image($r('app.media.icon_dynamic_play')).width(50).height(50)
            .shadow({ radius: 3.5, color: '#33000000' })
        }
        .width('100%').height(70)
        .padding({ left: 10, right: 8, bottom: 8 })
        .alignItems(VerticalAlign.Bottom)
        .linearGradient({ angle: 180, colors: [['#00000000', 0.0], ['#8A000000', 1.0]] })
      }
      .width('100%').aspectRatio(16 / 9).borderRadius(6).clip(true)
      .backgroundColor($r('app.color.btn_soft_bg'))

      if (this.detail) {
        Text(this.archive.title).fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).width('100%')
      } else {
        Text(this.archive.title).fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
