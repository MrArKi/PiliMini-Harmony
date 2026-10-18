/** 改编自Nara FavVideoItem / FavFolderItem：完整封面行、我的横向叠层预览。 */
import { AsyncImage } from './AsyncImage';
import { FavFolder } from '../service/fav_service';

export function folderPrivacy(folder: FavFolder): string {
  return folder.attr === undefined || folder.attr < 0 ? '' : ((folder.attr & 1) === 0 ? '公开' : '私密');
}

@Component
export struct FavFolderCard {
  @Prop folder: FavFolder;
  @Prop preview: boolean = false;
  onOpen: () => void = () => {};

  @Builder
  Cover() {
    Stack() {
      if ((this.folder.cover || '').length > 0) {
        AsyncImage({ src: this.folder.cover || '', w: 360, h: 220 })
      } else {
        Image($r('app.media.icon_star')).width(28).height(28)
          .fillColor($r('app.color.text_secondary')).opacity(0.6)
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.btn_soft_bg')).borderRadius(6).clip(true)
  }

  build() {
    Column() {
      if (this.preview) {
        Stack() {
          Column().width(180).height(110).borderRadius(12)
            .backgroundColor($r('app.color.btn_soft_bg')).opacity(0.4).translate({ x: 6, y: -8 })
          this.Cover()
        }.width(180).height(110)
        Text(' ' + this.folder.title).fontSize(14).fontColor($r('app.color.text_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').margin({ top: 8 })
        Text(' 共' + this.folder.mediaCount.toString() + '条视频' +
          (folderPrivacy(this.folder) ? ' · ' + folderPrivacy(this.folder) : ''))
          .fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      } else {
        Row({ space: 10 }) {
          Stack() { this.Cover() }.width(160).height(100)
          Column({ space: 3 }) {
            Text(this.folder.title).fontSize(14).letterSpacing(0.3).fontColor($r('app.color.text_primary'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            if ((this.folder.intro || '').length > 0) {
              Text(this.folder.intro || '').fontSize(12).fontColor($r('app.color.text_secondary'))
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            }
            Text(this.folder.mediaCount.toString() + '个内容').fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(folderPrivacy(this.folder)).fontSize(12).fontColor($r('app.color.text_secondary'))
          }.layoutWeight(1).height(100).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ left: 12, right: 12, top: 5, bottom: 5 })
      }
    }.width(this.preview ? 180 : '100%').alignItems(HorizontalAlign.Start)
      .id('fav_folder_' + this.folder.id.toString()).onClick(() => { this.onOpen(); })
  }
}
