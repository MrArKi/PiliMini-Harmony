/** Nara follow_item：头像45、昵称14、签名13，行内动作不冒泡至空间。 */
import { FollowItem } from '../../model/follow';
import { AsyncImage } from '../AsyncImage';
import { openMember } from '../../common/member_route';

@Component
export struct FollowItemView {
  @Prop item: FollowItem;
  @Prop owner: boolean = false;
  @Prop busy: boolean = false;
  onRelation: (item: FollowItem) => void = () => {};

  build() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() { AsyncImage({ src: this.item.face, w: 135, h: 135 }) }
          .width(45).height(45).borderRadius(23).clip(true).backgroundColor($r('app.color.btn_soft_bg'))
        if (this.item.officialType >= 0) {
          Image($r('app.media.icon_follow_verified')).fillColor(this.item.officialType === 0 ? '#FFCC00' : '#40C4FF')
            .width(14).height(14).borderRadius(7).backgroundColor($r('app.color.bg_page'))
        }
      }.width(45).height(45)
      Column({ space: 3 }) {
        Text(this.item.name || '用户').fontSize(14).fontColor($r('app.color.text_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (this.item.sign.length > 0) {
          Text(this.item.sign).fontSize(13).fontColor($r('app.color.text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.owner) {
        Button(this.busy ? '处理中' : '已关注').fontSize(12).height(32).padding({ left: 15, right: 15 })
          .fontColor($r('app.color.text_secondary')).backgroundColor($r('app.color.btn_soft_bg'))
          .enabled(!this.busy).id('follow_action_' + this.item.mid.toString())
          .onClick((): void => { this.onRelation(this.item); })
      }
    }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .id('follow_item_' + this.item.mid.toString()).onClick((): void => { openMember(this.item.mid); })
  }
}
