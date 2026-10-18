/**
 * 动态 Tab（spec-08）：关注动态流
 *  - 顶部共用文字分类（全部 / 视频 / 图文），保留状态栏安全区
 *  - 列表：DynamicCard（视频 / 图文 / 转发 / 占位）+ 下拉刷新 + offset 游标分页
 *  - 未登录：空态引导「登录后查看关注动态」+ 去登录
 * 规格来源：docs/ui/动态页.html、docs/参考-NaraUI基准.md §5
 */
import { router } from '@kit.ArkUI';
import { BasicDataSource } from '../../common/list_data_source';
import { Pager, PageData } from '../../common/paged_feed';
import { DynamicCard } from '../../components/dynamic/DynamicCard';
import { FeedCategoryBar } from '../../components/FeedCategoryBar';
import { LoadingFooter, ErrorRetry } from '../../components/StateViews';
import { DynamicService, DynItem, DynPageResult } from '../../service/dynamic_service';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { AppError } from '../../infra/error/app_error';
import { FeedNavigation, FeedNavRequest } from '../../common/feed_navigation';

@Component
struct DynFeedList {
  @Prop dynType: string = 'all';
  @Prop filterKind: string = ''; // 客户端过滤：如 'draw'（图文 chip 用）
  @Prop selected: boolean = false;
  @Prop @Watch('onNavRequest') navRequest: FeedNavRequest = new FeedNavRequest();
  private navigation: FeedNavigation = new FeedNavigation();
  private destroyed: boolean = false;
  private reloading: boolean = false;
  private refreshRunning: boolean = false;
  private ds: BasicDataSource<DynItem> = new BasicDataSource<DynItem>();
  @State pager: Pager<DynItem> = new Pager<DynItem>();
  @State needLogin: boolean = false;
  @State refreshing: boolean = false;

  aboutToAppear(): void {
    this.pager.initialCursor = ''; // 动态流首页 offset 为空串
    this.reload();
  }

  aboutToDisappear(): void { this.destroyed = true; this.pager.cancel(); }

  private onNavRequest(): void {
    if (!this.selected || this.destroyed || this.reloading || this.refreshRunning) { return; }
    if (this.navigation.shouldRefresh(this.navRequest, this.pager.firstLoaded && !this.needLogin)) { this.refresh(); }
  }

  private async fetchFeed(cursor: string): Promise<PageData<DynItem>> {
    try {
      const r: DynPageResult = await DynamicService.feed(this.dynType, cursor);
      let items: DynItem[] = r.items;
      if (this.filterKind.length > 0) {
        items = items.filter((it: DynItem) => it.kind === this.filterKind);
      }
      const out: PageData<DynItem> = {
        items: items,
        hasMore: r.hasMore,
        nextCursor: r.offset
      };
      return out;
    } catch (e) {
      const err: Error = e as Error;
      const ae: AppError = e as AppError;
      if (!this.destroyed && ae !== undefined && ae !== null && ae.type === 'auth') {
        this.needLogin = true;
      }
      throw err;
    }
  }

  private async reload(): Promise<void> {
    if (this.destroyed || this.reloading) { return; }
    this.reloading = true;
    try {
      this.needLogin = false;
      // 本地登录态判断（无网络开销）：未登录直接给引导，不浪费一次请求
      const logged: boolean = await CookieStore.isLogin();
      if (this.destroyed) { return; }
      if (!logged) {
        this.needLogin = true;
        return;
      }
      const loaded: boolean = await this.pager.reload(this.ds,
        (cursor: string): Promise<PageData<DynItem>> => this.fetchFeed(cursor));
      if (!loaded) { return; }
      // 客户端过滤后首页可能为空：仅成功的空页续拉，失败立即停止。
      let guard: number = 0;
      while (!this.destroyed && this.ds.size() === 0 && this.pager.hasMore && guard < 10) {
        guard++;
        const more: boolean = await this.pager.loadMore(this.ds,
          (cursor: string): Promise<PageData<DynItem>> => this.fetchFeed(cursor));
        if (!more) { break; }
      }
    } finally { this.reloading = false; }
  }

  private async loadMore(): Promise<void> {
    if (this.destroyed) { return; }
    await this.pager.loadMore(this.ds, (cursor: string): Promise<PageData<DynItem>> => this.fetchFeed(cursor));
  }

  private async refresh(): Promise<void> {
    if (this.destroyed || this.reloading || this.refreshRunning) { return; }
    this.refreshRunning = true;
    console.info('[PiliMini-feed] refresh source=dynamic_' + this.dynType + '_' + this.filterKind);
    this.refreshing = true;
    try { await this.reload(); }
    finally {
      this.refreshRunning = false;
      if (!this.destroyed) { this.refreshing = false; }
    }
  }

  // ===== 未登录引导（spec-08 验收 6） =====
  @Builder
  LoginGuide() {
    Column({ space: 10 }) {
      Image($r('app.media.icon_lightning'))
        .width(44)
        .height(44)
        .fillColor($r('app.color.text_secondary'))
        .opacity(0.5)
      Text('登录后查看关注动态')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
      Text('关注 UP 的视频 / 图文 / 转发会在这里按时间倒序展示')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
      Button('去登录')
        .fontSize(14)
        .width(160)
        .height(38)
        .backgroundColor($r('app.color.brand_pink'))
        .margin({ top: 6 })
        .onClick(() => {
          router.replaceUrl({ url: 'pages/login/LoginPage' });
        })
    }
    .width('100%')
    .padding({ left: 32, right: 32, bottom: 120 })
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        if (this.needLogin) {
          Column() {
            this.LoginGuide()
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.pager.loading && !this.pager.firstLoaded) {
          Column() {
            LoadingFooter({ text: '正在加载…' })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.pager.error.length > 0 && !this.pager.firstLoaded) {
          Column() {
            ErrorRetry({
              text: this.pager.error,
              onRetry: () => {
                this.reload();
              }
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
            List({ scroller: this.navigation.scroller }) {
              LazyForEach(this.ds, (item: DynItem) => {
                ListItem() {
                  DynamicCard({
                    model: item
                  })
                }
                .width('100%')
              }, (item: DynItem) => item.id)

              ListItem() {
                if (this.pager.footerText.length > 0) {
                  Text(this.pager.footerText)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 20, bottom: 110 })
                } else {
                  LoadingFooter({ text: '加载中…' })
                }
              }
            }
            .cachedCount(3)
            .width('100%')
            .height('100%')
            .id('dynamic_feed_' + this.dynType + '_' + this.filterKind)
            .onAreaChange((_old: Area, area: Area): void => { this.navigation.viewportHeight = Number(area.height); })
            .onScrollStop((): void => { this.navigation.onScrollStop(); })
            // 卡片间 0.5px 分隔线（左右缩进 12，10% alpha）
            .divider({ strokeWidth: 0.5, color: '#1A000000', startMargin: 12, endMargin: 12 })
            .onReachEnd(() => {
              this.loadMore();
            })
          }
          .onRefreshing(() => {
            this.refresh();
          })
          .layoutWeight(1)
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')

    }
    .width('100%')
    .height('100%')
  }
}

@Component
export struct DynamicTab {
  @State mode: number = 0; // 0=全部 1=视频 2=图文
  @State categoryProgress: number = 0;
  private feedTabs: TabsController = new TabsController();
  @Prop @Watch('onNavRequest') navRequest: FeedNavRequest = new FeedNavRequest();
  @State feedNavRequests: FeedNavRequest[] = [new FeedNavRequest(), new FeedNavRequest(), new FeedNavRequest()];
  /** 是否当前可见（主壳传入）：首次激活前不挂载列表，避免启动即请求 */
  @Prop @Watch('onActive') active: boolean = false;
  @State visited: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;

  aboutToAppear(): void { this.onActive(); }

  private onNavRequest(): void {
    const requests: FeedNavRequest[] = this.feedNavRequests.slice();
    requests[this.mode] = this.navRequest;
    this.feedNavRequests = requests;
  }

  onActive(): void {
    if (this.active && !this.visited) {
      this.visited = true;
    }
  }

  build() {
    Column() {
      Column().width('100%').height(this.statusBarH)

      Column() {
        FeedCategoryBar({ labels: ['全部', '视频', '图文'], selected: this.mode, progress: this.categoryProgress,
          onSelect: (index: number): void => { this.feedTabs.changeIndex(index); } })
      }
      .width('100%').height(44).padding({ top: 6, bottom: 6 })

      if (this.visited) {
        Tabs({ index: this.mode, controller: this.feedTabs }) {
          TabContent() { DynFeedList({ dynType: 'all', filterKind: '', selected: this.mode === 0, navRequest: this.feedNavRequests[0] }) }
          TabContent() { DynFeedList({ dynType: 'video', filterKind: '', selected: this.mode === 1, navRequest: this.feedNavRequests[1] }) }
          TabContent() { DynFeedList({ dynType: 'all', filterKind: 'draw', selected: this.mode === 2, navRequest: this.feedNavRequests[2] }) }
        }
        .barHeight(0).layoutWeight(1).width('100%').animationDuration(300)
        .onContentDidScroll((_selected: number, index: number, position: number): void => {
          this.categoryProgress = Math.max(0, Math.min(2, index - position));
        })
        .onAnimationEnd((index: number): void => { this.categoryProgress = index; })
        .onChange((index: number): void => { this.mode = index; })
      }
    }
    .width('100%')
    .height('100%')
  }
}
