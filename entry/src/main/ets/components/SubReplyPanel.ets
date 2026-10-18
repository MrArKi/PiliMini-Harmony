/** Nara视频内局部回复面板与外部评论详情共用内容。 */
import { router, curves } from '@kit.ArkUI';
import { CommentItemView, CommentSkeleton } from './CommentItem';
import { BasicDataSource } from '../common/list_data_source';
import { formatPlayCount } from './VideoCard';
import { CommentItem, SubReplyPage, VideoService } from '../service/video_service';

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
  private loadingMore: boolean = false;
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
    this.load(1);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
  }

  private async load(page: number): Promise<void> {
    const root: CommentItem | undefined = this.root;
    if (this.destroyed || this.loadingMore || root === undefined) {
      this.loading = false;
      if (root === undefined) {
        this.err = '评论已失效，请返回重试';
      }
      return;
    }
    this.loadingMore = true;
    this.err = '';
    try {
      const r: SubReplyPage = this.aid > 0
        ? await VideoService.subReplies(this.aid, root.rpid, page)
        : await VideoService.dynSubReplies(this.oid, this.otype, root.rpid, page);
      if (this.destroyed) {
        return;
      }
      if (page === 1) {
        this.items = r.items;
        this.ds.reload(r.items);
      } else {
        this.items = this.items.concat(r.items);
        this.ds.append(r.items);
      }
      this.page = page;
      if (r.total > 0) {
        this.total = r.total;
      }
      this.isEnd = !r.hasMore;
    } catch (e) {
      if (!this.destroyed) {
        this.err = '加载失败，点击重试';
      }
    }
    this.loadingMore = false;
    this.loading = false;
  }

  @Builder
  ReplyRow(item: CommentItem) {
    CommentItemView({
      item: item,
      upMid: this.upMid,
      hideSubEntry: false,
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
                  this.load(this.page + 1);
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
      .divider({ strokeWidth: 0.3, color: '#14000000', startMargin: 55, endMargin: 15 })
      .onReachEnd(() => {
        if (!this.isEnd) {
          this.load(this.page + 1);
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
