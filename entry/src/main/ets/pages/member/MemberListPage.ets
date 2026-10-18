import { router } from '@kit.ArkUI';
import { MemberFeed } from '../../components/member/MemberFeed';
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
@Entry
@Component
struct MemberListPage {
  @State mid: number = 0;
  @State resourceId: number = 0;
  @State kind: string = '';
  @State title: string = '';
  @StorageProp('statusBarHeight') statusH: number = 0;
  aboutToAppear(): void {
    const p = router.getParams() as Record<string, string>;
    this.mid = Number(p['mid'] || 0); this.resourceId = Number(p['id'] || 0);
    this.kind = p['kind'] || ''; this.title = p['title'] || '视频列表';
  }
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
  }
  build() {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.icon_arrow_left')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .onClick(() => { router.back(); }).accessibilityText('返回')
        Text(this.title).fontSize(18).fontColor($r('app.color.text_primary')).maxLines(1).layoutWeight(1)
      }.height(56 + this.statusH).width('100%').padding({ top: this.statusH, right: 12 })
      if (this.resourceId > 0 || this.mid > 0) { MemberFeed({ mid: this.mid, resourceId: this.resourceId, kind: this.kind }).layoutWeight(1) }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
