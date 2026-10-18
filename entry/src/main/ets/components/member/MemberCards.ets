import { router } from '@kit.ArkUI';
import { AsyncImage } from '../AsyncImage';
import { VideoItem } from '../../model/video_item';
import { formatDuration, formatPlayCount } from '../VideoCard';
import { naraDate } from '../../common/nara_date';
import { MemberOpus, MemberCollection, MemberFolder, memberUrl } from '../../service/member_service';

@Component
export struct MemberOpusCard {
  @Prop model: MemberOpus;
  @Prop cardWidth: number = 180;
  build() {
    Column() {
      if (this.model.cover?.url) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Column() { AsyncImage({ src: memberUrl(this.model.cover.url), w: 480, h: 2048 }) }
            .width(this.cardWidth).height(this.cardWidth * this.model.cover.height / Math.max(1, this.model.cover.width))
          Row({ space: 4 }) {
            Image($r('app.media.icon_thumbup')).width(13).height(13).fillColor(Color.White)
            Text(this.model.stat?.like || '0').fontSize(12).fontColor(Color.White)
          }.width('100%').height(45).alignItems(VerticalAlign.Bottom).padding({ left: 8, bottom: 4 })
            .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#80000000', 1]] })
        }.width(this.cardWidth)
      }
      Text(this.model.content || '').fontSize(14).lineHeight(20).fontColor($r('app.color.text_primary'))
        .maxLines(this.model.cover?.url ? 4 : 6).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').padding({ left: 8, right: 8, top: 10, bottom: 10 })
      if (!this.model.cover?.url) {
        Row({ space: 4 }) {
          Image($r('app.media.icon_thumbup')).width(13).height(13).fillColor($r('app.color.text_secondary'))
          Text(this.model.stat?.like || '0').fontSize(12).fontColor($r('app.color.text_secondary'))
        }.width('100%').padding({ left: 8, right: 8, bottom: 8 })
      }
    }.width(this.cardWidth).alignItems(HorizontalAlign.Start).borderRadius(6).clip(true)
      .backgroundColor($r('app.color.card_bg'))
      .onClick(() => { router.pushUrl({ url: 'pages/dynamic/DynDetailPage',
        params: { 'id': this.model.opus_id, 'opus': '1' } }); })
  }
}

/** Nara MemberHome专用卡：封面+两行标题，无首页推荐卡的统计/更多行。 */
@Component
export struct MemberHomeVideoCard {
  @Prop model: VideoItem;
  @Prop cardWidth: number = 180;
  build() {
    Column() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        AsyncImage({ src: this.model.cover, w: 400, h: 250 })
        Text(formatDuration(this.model.duration)).fontSize(10).fontColor(Color.White)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 }).backgroundColor('#80000000')
          .borderRadius(4).margin({ right: 7, bottom: 6 })
      }.width(this.cardWidth).height(this.cardWidth / 1.6)
      Text(this.model.title + '\n').fontSize(14).lineHeight(19.32).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        .width('100%').height(55).padding({ left: 6, right: 6, top: 5, bottom: 5 })
    }.width(this.cardWidth).borderRadius(6).clip(true).backgroundColor($r('app.color.card_bg'))
      .onClick(() => { router.pushUrl({ url: 'pages/video/VideoDetailPage', params: { 'bvid': this.model.bvid } }); })
  }
}

@Component
export struct MemberCollectionCard {
  @Prop model: MemberCollection;
  @Prop mid: number = 0;
  build() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        AsyncImage({ src: this.model.cover, w: 320, h: 200 })
        Text((this.model.kind === 'season' ? '合集' : '列表') + ': ' + this.model.count.toString())
          .fontSize(10).fontColor(Color.White).padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .backgroundColor('#80000000').borderRadius(4).margin({ right: 6, bottom: 6 })
      }.width(160).height(100).borderRadius(6).clip(true).backgroundColor($r('app.color.btn_soft_bg'))
      Column() {
        Text(this.model.title).fontSize(14).lineHeight(20).letterSpacing(0.3).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Blank()
        Text(naraDate(this.model.ptime)).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
        Blank()
      }.height(100).layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .onClick(() => { router.pushUrl({ url: 'pages/member/MemberListPage', params: {
        'mid': this.mid.toString(), 'id': this.model.id.toString(), 'kind': this.model.kind, 'title': this.model.title
      } }); })
  }
}

@Component
export struct MemberFolderCard {
  @Prop model: MemberFolder;
  private subtitle(): string {
    const count: string = this.model.media_count.toString();
    if (this.model.type === 21) {
      return '创建者: ' + (this.model.upper?.name || '') + '\n' + count + '个视频 · '
        + formatPlayCount(this.model.view_count || 0) + '播放';
    }
    if (this.model.type === 11) { return count + '个内容 · ' + (this.model.upper?.name || ''); }
    return count + '个内容 · ' + (((this.model.attr || 0) & 1) === 1 ? '私密' : '公开');
  }
  build() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (this.model.cover) { AsyncImage({ src: memberUrl(this.model.cover), w: 320, h: 200 }) }
        else { Row() { Image($r('app.media.icon_folder')).width(32).height(32).fillColor($r('app.color.text_secondary')) }
          .width('100%').height('100%').justifyContent(FlexAlign.Center) }
        if (this.model.type === 11 || this.model.type === 21) {
          Text(this.model.type === 21 ? '合集' : '收藏夹').fontSize(10).fontColor(Color.White)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 }).borderRadius(4)
            .backgroundColor($r('app.color.brand_pink')).margin({ top: 6, right: 6 })
        }
      }.width(160).height(100).borderRadius(6).clip(true).backgroundColor($r('app.color.btn_soft_bg'))
      Column() {
        Text(this.model.title).fontSize(14).lineHeight(20).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.subtitle())
          .fontSize(12).fontColor($r('app.color.text_secondary'))
      }.height(100).layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .onClick(() => { if (this.model.state === 1) { return; } router.pushUrl({ url: 'pages/member/MemberListPage',
        params: { 'kind': this.model.type === 21 ? 'subscription' : 'favorite', 'id': this.model.id.toString(), 'title': this.model.title } }); })
  }
}
