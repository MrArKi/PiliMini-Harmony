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

@Component
struct DynFeedList {
  @Prop dynType: string = 'all';
  @Prop filterKind: string = ''; // 客户端过滤：如 'draw'（图文 chip 用）
  private ds: BasicDataSource<DynItem> = new BasicDataSource<DynItem>();
  @State pager: Pager<DynItem> = new Pager<DynItem>();
  @State needLogin: boolean = false;
  @State refreshing: boolean = false;

  aboutToAppear(): void {
    this.pager.initialCursor = ''; // 动态流首页 offset 为空串
    this.reload();
  }

  aboutToDisappear(): void { this.pager.cancel(); }

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
      if (ae !== undefined && ae !== null && ae.type === 'auth') {
        this.needLogin = true;
      }
      throw err;
    }
  }

  private async reload(): Promise<void> {
    this.needLogin = false;
    // 本地登录态判断（无网络开销）：未登录直接给引导，不浪费一次请求
    const logged: boolean = await CookieStore.isLogin();
    if (!logged) {
      this.needLogin = true;
      return;
    }
    await this.pager.reload(this.ds, (cursor: string): Promise<PageData<DynItem>> => this.fetchFeed(cursor));
    // 客户端过滤后首页可能为空：自动续拉（带上限防死循环）
    let guard: number = 0;
    while (this.ds.size() === 0 && this.pager.hasMore && this.pager.firstLoaded && guard < 10) {
      guard++;
      await this.pager.loadMore(this.ds, (cursor: string): Promise<PageData<DynItem>> => this.fetchFeed(cursor));
    }
  }

  private async loadMore(): Promise<void> {
    await this.pager.loadMore(this.ds, (cursor: string): Promise<PageData<DynItem>> => this.fetchFeed(cursor));
  }

  private async refresh(): Promise<void> {
    this.refreshing = true;
    await this.reload();
    this.refreshing = false;
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
            List() {
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
  /** 是否当前可见（主壳传入）：首次激活前不挂载列表，避免启动即请求 */
  @Prop @Watch('onActive') active: boolean = false;
  @State visited: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;

  onActive(): void {
    if (this.active) {
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

      if (this.active || this.visited) {
        Tabs({ index: this.mode, controller: this.feedTabs }) {
          TabContent() { DynFeedList({ dynType: 'all', filterKind: '' }) }
          TabContent() { DynFeedList({ dynType: 'video', filterKind: '' }) }
          TabContent() { DynFeedList({ dynType: 'all', filterKind: 'draw' }) }
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
