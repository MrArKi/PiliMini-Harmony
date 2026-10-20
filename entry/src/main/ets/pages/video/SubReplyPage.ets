/** 外部评论详情入口；视频内使用SubReplyPanel保留播放器。 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { SubReplyPanel } from '../../components/SubReplyPanel';
import { CommentItem } from '../../service/video_service';
import { SubReplyArgs } from '../../service/sub_reply_ctx';

@Entry
@Component
struct SubReplyDetailPage {
  @State root: CommentItem | undefined = undefined;
  private upMid: number = 0;
  private aid: number = 0;
  private oid: string = '';
  private otype: number = 1;
  private targetRpid: number = 0;

  aboutToAppear(): void {
    this.root = SubReplyArgs.root; this.upMid = SubReplyArgs.upMid;
    this.aid = SubReplyArgs.aid; this.oid = SubReplyArgs.oid; this.otype = SubReplyArgs.otype;
    this.targetRpid = SubReplyArgs.targetRpid;
    SubReplyArgs.clear();
  }

  /** 与Nara默认Cupertino一致：300ms，底页1/3视差。 */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '100%' })
  }

  build() {
    Column() {
      SubReplyPanel({ root: this.root, upMid: this.upMid, aid: this.aid, oid: this.oid, otype: this.otype,
        targetRpid: this.targetRpid })
    }.width('100%').height('100%')
  }
}
