/** Nara视频内局部回复面板与外部评论详情共用内容。 */
import { FrameCallback } from '@ohos.arkui.UIContext';
import { router, curves } from '@kit.ArkUI';
import { CommentItemView, CommentSkeleton } from './CommentItem';
import { BasicDataSource } from '../common/list_data_source';
import { formatPlayCount } from './VideoCard';
import { CommentItem, SubReplyPage, SubReplyWindow, VideoService } from '../service/video_service';
import { AppError } from '../infra/error/app_error';

/** 单次布局后执行，回调自行检查页面是否已销毁。 */
class ReplyLayoutCallback extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(_time: number): void { this.action(); this.action = () => {}; }
}

@Component
export struct SubReplyPanel {
  @Prop embedded: boolean = false;
  onClose: () => void = () => { router.back(); };
  @State dragOffset: number = 0;
  @State panelHeight: number = 600;
  private listScroller: Scroller = new Scroller();
  @State items: CommentItem[] = [];
  @State total: number = 0;
  @State loading: boolean = true;
  @State isEnd: boolean = false;
  @State err: string = '';
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private page: number = 0;
  @State loadingMore: boolean = false;
  targetRpid: number = 0;
  @State hasPrevious: boolean = false;
  @State focusNotice: string = '';
  @State highlightRpid: number = 0;
  private windowMode: boolean = false;
  private prevOffset: string = '';
  private nextOffset: string = '';
  private failedDirection: string = 'initial';
  private pendingFocus: number = 0;
  private listHeight: number = 0;
  private firstVisible: number = 0;
  private destroyed: boolean = false;
  private ds: BasicDataSource<CommentItem> = new BasicDataSource<CommentItem>();
  // 入参快照（aboutToAppear 一次性取走，避免全局 ctx 被后续操作/返回动画干扰）
  // root 必须为 @State：作为 @ObjectLink(CommentItemView.item) 的合法数据源
  @State root: CommentItem | undefined = undefined;
  upMid: number = 0;
  aid: number = 0;
  oid: string = '';
  otype: number = 1;

  aboutToAppear(): void {
    this.total = this.root !== undefined ? this.root.rcount : 0;
    this.windowMode = this.targetRpid > 0;
    this.load();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
  }

  private positionReply(rpid: number, y: number, highlight: boolean, attempt: number = 0): void {
    this.getUIContext().postFrameCallback(new ReplyLayoutCallback(() => {
      if (this.destroyed) { return; }
      const index: number = this.items.findIndex((item: CommentItem) => item.rpid === rpid);
      if (index < 0) { return; }
      // 主评论/分隔/排序/向前入口共4项；LazyForEach目标可由scrollToIndex直接物化。
      try { this.listScroller.scrollToIndex(index + 4, false, ScrollAlign.CENTER); }
      catch (e) { this.positionFailed(rpid, y, highlight, attempt); return; }
      this.getUIContext().postFrameCallback(new ReplyLayoutCallback(() => {
        if (this.destroyed) { return; }
        try {
          const rect: RectResult = this.listScroller.getItemRect(index + 4);
          if (rect.height <= 0) { this.positionFailed(rpid, y, highlight, attempt); return; }
          this.listScroller.scrollBy(0, rect.y - y);
        } catch (e) { this.positionFailed(rpid, y, highlight, attempt); return; }
        if (highlight) {
          this.highlightRpid = rpid;
          animateTo({ delay: 800, duration: 200, curve: Curve.Linear }, () => { this.highlightRpid = 0; });
        }
      }));
    }));
  }

  private positionFailed(rpid: number, y: number, highlight: boolean, attempt: number): void {
    if (this.destroyed) { return; }
    if (attempt < 2) { this.positionReply(rpid, y, highlight, attempt + 1); }
    else if (highlight) { this.focusNotice = '暂时无法定位该回复，请重新打开详情'; }
  }

  private async load(direction: string = 'initial'): Promise<void> {
    const root: CommentItem | undefined = this.root;
    if (this.destroyed || this.loadingMore || root === undefined) {
      if (root === undefined) { this.loading = false; this.err = '评论已失效，请返回重试'; }
      return;
    }
    if (direction === 'previous' && !this.hasPrevious) { return; }
    const anchorIndex: number = this.firstVisible - 4;
    const anchor: CommentItem | undefined = anchorIndex >= 0 ? this.items[anchorIndex] : undefined;
    let anchorY: number = 0;
    this.loadingMore = true;
    this.failedDirection = direction;
    this.err = '';
    try {
      if (direction === 'previous' && anchor !== undefined) {
        anchorY = this.listScroller.getItemRect(anchorIndex + 4).y;
      }
      let incoming: CommentItem[] = [];
      if (this.windowMode) {
        const offset: string = direction === 'previous' ? this.prevOffset : this.nextOffset;
        const r: SubReplyWindow = await VideoService.subReplyWindow(this.aid > 0 ? this.aid.toString() : this.oid,
          this.aid > 0 ? 1 : this.otype, root.rpid, direction === 'initial' ? this.targetRpid : 0,
          direction === 'initial' ? '' : offset);
        if (this.destroyed) { return; }
        incoming = r.items;
        if (direction !== 'next') { this.prevOffset = r.prevOffset; this.hasPrevious = r.hasPrevious; }
        if (direction !== 'previous') { this.nextOffset = r.nextOffset; this.isEnd = !r.hasMore; }
        this.total = r.total;
      } else {
        const page: number = direction === 'initial' ? 1 : this.page + 1;
        const r: SubReplyPage = this.aid > 0
          ? await VideoService.subReplies(this.aid, root.rpid, page)
          : await VideoService.dynSubReplies(this.oid, this.otype, root.rpid, page);
        if (this.destroyed) { return; }
        incoming = r.items;
        this.page = page;
        this.total = r.total;
        this.isEnd = !r.hasMore;
      }
      if (direction === 'initial') {
        this.items = incoming;
        this.ds.reload(this.items);
        if (this.windowMode) {
          if (this.items.some((item: CommentItem) => item.rpid === this.targetRpid)) {
            this.pendingFocus = this.targetRpid;
          } else {
            this.focusNotice = '该回复可能已删除或不可见';
          }
        }
      } else {
        const unique: CommentItem[] = incoming.filter((item: CommentItem) =>
          !this.items.some((existing: CommentItem) => existing.rpid === item.rpid));
        if (direction === 'previous') {
          this.items = unique.concat(this.items);
          this.ds.reload(this.items);
          if (anchor !== undefined) { this.positionReply(anchor.rpid, anchorY, false); }
        } else {
          this.items = this.items.concat(unique);
          this.ds.append(unique);
        }
      }
    } catch (e) {
      if (!this.destroyed) {
        if (this.windowMode && direction === 'initial' && e instanceof AppError && e.code === 12006) {
          this.focusNotice = '该回复可能已删除或不可见';
          this.isEnd = true;
        } else { this.err = '加载失败，点击重试'; }
      }
    } finally {
      if (!this.destroyed) {
        this.loadingMore = false;
        this.loading = false;
        if (this.pendingFocus > 0) {
          const rpid: number = this.pendingFocus;
          this.pendingFocus = 0;
          // 异步加载结束显式安排下一帧，onDidBuild只覆盖组件初次构建。
          this.getUIContext().postFrameCallback(new ReplyLayoutCallback(() => {
            if (!this.destroyed) { this.positionReply(rpid, this.listHeight * 0.25, true); }
          }));
        }
      }
    }
  }

  private showAll(): void {
    if (this.loadingMore) { return; }
    this.windowMode = false;
    this.hasPrevious = false;
    this.focusNotice = '';
    this.highlightRpid = 0;
    this.loading = true;
    this.items = [];
    this.ds.reload([]);
    this.listScroller.scrollToIndex(0);
    this.load();
  }

  @Builder
  ReplyRow(item: CommentItem) {
    CommentItemView({
      item: item,
      upMid: this.upMid,
      hideSubEntry: true,
      onOpenSub: () => {
      },
      onSubMore: () => {
      }
    })
  }

  build() {
    Column() {
      if (this.embedded) {
        Row() {
          Text('评论详情').fontSize(14).fontColor($r('app.color.text_primary'))
          Blank()
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.icon_clear')).width(20).height(20).fillColor($r('app.color.text_primary'))
          }.width(42).height(45).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('关闭评论详情').onClick(this.onClose)
        }
        .width('100%').height(45).padding({ left: 12, right: 2 })
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: { bottom: 0.3 }, color: $r('app.color.divider') })
        .gesture(PanGesture({ direction: PanDirection.Vertical, distance: 6 })
          .onActionUpdate((e: GestureEvent) => { this.dragOffset = Math.max(0, e.offsetY); })
          .onActionEnd((e: GestureEvent) => {
            if (e.velocityY > 700 || this.dragOffset > this.panelHeight * 0.5) { this.onClose(); }
            else { animateTo({ duration: 200, curve: curves.cubicBezierCurve(0.4, 0, 0.2, 1) }, () => { this.dragOffset = 0; }); }
          })
          .onActionCancel(() => { this.dragOffset = 0; }))
      } else {
        Row({ space: 8 }) {
          Image($r('app.media.icon_arrow_left')).width(22).height(22)
            .fillColor($r('app.color.text_primary')).padding({ left: 6, right: 6 }).onClick(this.onClose)
          Text('评论详情').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Blank()
        }.width('100%').padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
        .backgroundColor($r('app.color.card_bg'))
      }

      List({ scroller: this.listScroller }) {
        // 主评论（不带「共N条回复」入口）
        ListItem() {
          if (this.root !== undefined) {
            CommentItemView({
              item: this.root,
              upMid: this.upMid,
              hideSubEntry: true,
              onOpenSub: () => {
              },
              onSubMore: () => {
              }
            })
          }
        }
        .width('100%')

        // 6 厚分隔块（Nara: Divider height 20 / thickness 6 / alpha 0.1）
        ListItem() {
          Column()
            .width('100%')
.height(6).margin({ top: 7, bottom: 7 })
            .backgroundColor($r('app.color.divider'))
        }
        .width('100%')

        // 排序头：相关回复共N条 ｜ 按时间
        ListItem() {
          Row() {
            Text('相关回复共' + formatPlayCount(this.total) + '条')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Row({ space: 4 }) {
              Image($r('app.media.icon_sort'))
                .width(16)
                .height(16)
                .fillColor($r('app.color.text_secondary'))
              Text('按时间')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }
        .width('100%')

        ListItem() {
          Column({ space: 6 }) {
            if (this.focusNotice.length > 0) {
              Text(this.focusNotice).fontSize(12).fontColor($r('app.color.text_secondary'))
              Text('查看全部回复').fontSize(12).fontColor($r('app.color.brand_pink'))
                .id('sub_reply_show_all').onClick(() => { this.showAll(); })
            } else if (this.hasPrevious) {
              Text(this.loadingMore ? '加载中…' : '加载更早回复').fontSize(12)
                .fontColor($r('app.color.brand_pink')).id('sub_reply_previous')
                .onClick(() => { this.load('previous'); })
            }
          }.width('100%').padding({ top: this.hasPrevious || this.focusNotice.length > 0 ? 12 : 0,
            bottom: this.hasPrevious || this.focusNotice.length > 0 ? 12 : 0 })
        }.width('100%')

        if (this.loading) {
          ForEach([0, 1, 2, 3], (i: number) => {
            ListItem() {
              CommentSkeleton({ variant: i })
            }
            .width('100%')
          }, (i: number) => 'srsk_' + i.toString())
        } else {
          LazyForEach(this.ds, (item: CommentItem) => {
            ListItem() {
              this.ReplyRow(item)
            }
            .width('100%')
            .id('sub_reply_' + item.rpid.toString())
            .backgroundColor(this.highlightRpid === item.rpid ? $r('app.color.comment_focus_bg') : $r('app.color.bg_page'))
          }, (item: CommentItem) => 'sr_' + item.rpid.toString())
        }

        // 页脚
        ListItem() {
          Column() {
            if (this.err.length > 0) {
              Text(this.err)
                .fontSize(12)
                .fontColor($r('app.color.brand_pink'))
                .onClick(() => {
                  this.load(this.failedDirection);
                })
            } else {
              Text(this.isEnd ? '没有更多了' : '加载中...')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .width('100%')
          .height(100 + this.navBarH)
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .id('sub_reply_list')
      .onAreaChange((_old: Area, area: Area) => { this.listHeight = Number(area.height); })
      .onScrollIndex((start: number) => { this.firstVisible = start; })
      .divider({ strokeWidth: 0.3, color: '#14000000', startMargin: 55, endMargin: 15 })
      .onReachEnd(() => {
        if (!this.loading && !this.isEnd && this.err.length === 0) {
          this.load('next');
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .translate({ y: this.dragOffset })
    .onAreaChange((_old: Area, area: Area) => { this.panelHeight = Number(area.height); })
  }
}
