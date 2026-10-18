/**
 * 观看记录页（spec-02 V2）：我的页「观看记录」入口与区块标题「>」均进入本页
 *  - 列表：封面 + 进度角标 + 标题 2 行 + UP 名 + 观看时间
 *  - 分页：/x/web-interface/history/cursor（max/view_at 游标）
 *  - 点击条目 → 视频详情页
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router } from '@kit.ArkUI';
import { AsyncImage } from '../../components/AsyncImage';
import { EmptyState, LoadingFooter, ErrorRetry } from '../../components/StateViews';
import { formatDuration } from '../../components/VideoCard';
import { HistoryService, HistoryItem, HistoryPage } from '../../service/history_service';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { onHistoryChanged } from '../../infra/event/app_events';

function two(n: number): string {
  const s: string = n.toString();
  return s.length >= 2 ? s : '0' + s;
}

function fmtTime(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const d = new Date(ts * 1000);
  return two(d.getMonth() + 1) + '-' + two(d.getDate()) + ' ' + two(d.getHours()) + ':' + two(d.getMinutes());
}

@Entry
@Component
struct HistoryListPage {
  @State items: HistoryItem[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State needLogin: boolean = false;
  @State noMore: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private nextMax: number = 0;
  private nextViewAt: number = 0;
  private destroyed: boolean = false;
  private visible: boolean = false;
  private request: number = 0;
  private offHistory: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.offHistory = onHistoryChanged((): void => {
      if (this.visible) { this.reload(true); }
    });
  }

  onPageShow(): void { this.visible = true; this.reload(this.items.length > 0); }
  onPageHide(): void { this.visible = false; }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.request++;
    if (this.offHistory !== undefined) { this.offHistory(); this.offHistory = undefined; }
  }

  private async reload(silent: boolean = false): Promise<void> {
    const request: number = ++this.request;
    const logged: boolean = await CookieStore.isLogin();
    if (this.destroyed || request !== this.request) {
      return;
    }
    if (!logged) {
      this.needLogin = true;
      this.loading = false;
      return;
    }
    this.needLogin = false;
    if (!silent) { this.loading = true; }
    this.loadingMore = false;
    this.error = '';
    this.noMore = false;
    this.nextMax = 0;
    this.nextViewAt = 0;
    try {
      const r: HistoryPage = await HistoryService.page(0, 0, 20);
      if (this.destroyed || request !== this.request) {
        return;
      }
      this.items = r.items;
      this.nextMax = r.nextMax;
      this.nextViewAt = r.nextViewAt;
      this.noMore = !r.hasMore;
    } catch (e) {
      if (!this.destroyed && request === this.request) {
        this.error = '加载失败，请重试';
      }
    }
    if (request === this.request) { this.loading = false; }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || this.noMore || this.loading || this.nextMax === 0 && this.nextViewAt === 0) {
      return;
    }
    this.loadingMore = true;
    const request: number = this.request;
    try {
      const r: HistoryPage = await HistoryService.page(this.nextMax, this.nextViewAt, 20);
      if (this.destroyed || request !== this.request) {
        return;
      }
      this.items = this.items.concat(r.items);
      this.nextMax = r.nextMax;
      this.nextViewAt = r.nextViewAt;
      this.noMore = !r.hasMore;
    } catch (e) {
      if (!this.destroyed && request === this.request) {
        this.noMore = true;
      }
    }
    if (request === this.request) { this.loadingMore = false; }
  }

  private openVideo(item: HistoryItem): void {
    const params: Record<string, string> = { 'bvid': item.bvid, 'title': item.title, 'cid': item.cid.toString() };
    router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
  }

  @Builder
  HistoryRow(item: HistoryItem) {
    Row({ space: 10 }) {
      // 封面 + 进度角标
      Stack({ alignContent: Alignment.BottomStart }) {
        Column() {
          AsyncImage({ src: item.cover, w: 320, h: 180 })
        }
        .width('100%')
        .height('100%')

        Text(item.progress === -1 ? '已看完' : formatDuration(Math.max(0, item.progress)) + '/' + formatDuration(item.duration))
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor('#80000000')
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 5, bottom: 5 })
      }
      .width(150)
      .height(84)
      .borderRadius(6)
      .clip(true)
      .backgroundColor($r('app.color.btn_soft_bg'))

      Column({ space: 5 }) {
        Text(item.title)
          .fontSize(14)
          .lineHeight(19)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.upName)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(fmtTime(item.viewAt))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .onClick(() => {
      this.openVideo(item);
    })
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
      // 顶栏
      Row({ space: 8 }) {
        Image($r('app.media.icon_arrow_left'))
            .width(22).height(22)
          .fillColor($r('app.color.text_primary'))
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            router.back();
          })
        Text('观看记录')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
      .backgroundColor($r('app.color.card_bg'))

      if (this.loading) {
        Column() {
          LoadingFooter({ text: '正在加载…' })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.needLogin) {
        Column({ space: 12 }) {
          Text('登录后可查看观看记录')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Button('去登录')
            .fontSize(13)
            .backgroundColor($r('app.color.brand_pink'))
            .onClick(() => {
              router.pushUrl({ url: 'pages/login/LoginPage' });
            })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0 && this.items.length === 0) {
        Column() {
          ErrorRetry({
            text: this.error,
            onRetry: () => {
              this.reload();
            }
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        EmptyState({ text: '暂无观看记录' })
      } else {
        List() {
          ForEach(this.items, (item: HistoryItem) => {
            ListItem() {
              this.HistoryRow(item)
            }
          }, (item: HistoryItem) => item.key)

          ListItem() {
            Column() {
              Text(this.noMore ? '没有更多了' : '加载中…')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .height(80 + this.navBarH)
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 172, endMargin: 12 })
        .onReachEnd(() => {
          this.loadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
