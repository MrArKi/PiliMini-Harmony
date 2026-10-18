/**
 * 收藏夹页（spec-07）
 *  Nara封面列表→独立内容路由（VideoCard + 分页 + 下拉刷新）
 *  未登录 → 提示去登录
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router, promptAction } from '@kit.ArkUI';
import { BasicDataSource } from '../../common/list_data_source';
import { Pager, PageData } from '../../common/paged_feed';
import { VideoCard } from '../../components/VideoCard';
import { FavFolderCard } from '../../components/FavFolderCard';
import { LoadingFooter, ErrorRetry } from '../../components/StateViews';
import { FavService, FavFolder, FavPage, FavFolderPage } from '../../service/fav_service';
import { AuthService, UserInfo } from '../../service/auth_service';
import { VideoItem } from '../../model/video_item';

@Entry
@Component
struct FavListPage {
  @State loading: boolean = true;
  @State loggedIn: boolean = false;
  @State curFolder: FavFolder | null = null;
  @State refreshing: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  private ds: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  @State pager: Pager<VideoItem> = new Pager<VideoItem>();
  private folderDs: BasicDataSource<FavFolder> = new BasicDataSource<FavFolder>();
  @State folderPager: Pager<FavFolder> = new Pager<FavFolder>();
  private mid: number = 0;
  private destroyed: boolean = false;
  private refreshRunning: boolean = false;

  aboutToAppear(): void {
    this.pager.errorDetail = true; // 收藏夹接口错误直接展示服务端/异常信息
    this.init();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.pager.cancel(); this.folderPager.cancel();
  }

  private async init(): Promise<void> {
    const u: UserInfo | null = await AuthService.fetchNav();
    if (this.destroyed) { return; }
    this.loggedIn = u !== null;
    if (!this.loggedIn) {
      this.loading = false;
      return;
    }
    this.mid = (u as UserInfo).mid;
    this.loading = false;
    // 直接内容路由无需请求全部收藏夹，返回时上一页列表和位置原样保留。
    const pm: Record<string, string> | undefined = router.getParams() as Record<string, string> | undefined;
    if (pm !== undefined) {
      const idStr: string | undefined = pm['mediaId'];
      const title: string | undefined = pm['title'];
      const id: number = idStr !== undefined ? parseInt(idStr, 10) : 0;
      if (!isNaN(id) && id > 0) {
        const f: FavFolder = { id: id, title: title !== undefined ? title : '收藏夹', mediaCount: 0 };
        await this.openFolder(f);
        return;
      }
    }
    await this.loadFolders();
  }

  private async loadFolders(): Promise<void> {
    await this.folderPager.reload(this.folderDs,
      (cursor: string): Promise<PageData<FavFolder>> => this.fetchFolders(cursor));
  }

  private async fetchFolders(cursor: string): Promise<PageData<FavFolder>> {
    const page: number = parseInt(cursor, 10);
    const result: FavFolderPage = await FavService.folderPage(this.mid, page);
    return { items: result.items, hasMore: result.hasMore, nextCursor: (page + 1).toString() };
  }

  private navigateFolder(folder: FavFolder): void {
    router.pushUrl({ url: 'pages/fav/FavListPage',
      params: { mediaId: folder.id.toString(), title: folder.title } });
  }

  private async fetchFolderItems(f: FavFolder, cursor: string): Promise<PageData<VideoItem>> {
    const page: number = parseInt(cursor, 10);
    const r: FavPage = await FavService.folderItems(f.id, page);
    const out: PageData<VideoItem> = {
      items: r.items,
      hasMore: r.hasMore,
      nextCursor: (page + 1).toString()
    };
    return out;
  }

  private async openFolder(f: FavFolder): Promise<void> {
    this.curFolder = f;
    await this.pager.reload(this.ds, (cursor: string): Promise<PageData<VideoItem>> => this.fetchFolderItems(f, cursor));
  }

  private async loadMore(): Promise<void> {
    const f: FavFolder | null = this.curFolder;
    if (f === null) {
      return;
    }
    const ok: boolean = await this.pager.loadMore(this.ds,
      (cursor: string): Promise<PageData<VideoItem>> => this.fetchFolderItems(f, cursor));
    if (!this.destroyed && !ok && this.pager.hasMore && this.pager.lastError.length > 0) {
      promptAction.showToast({ message: '加载失败：' + this.pager.lastError });
    }
  }

  private async refreshCurrent(): Promise<void> {
    const f: FavFolder | null = this.curFolder;
    if (f === null) {
      await this.loadFolders();
    } else {
      await this.openFolder(f);
    }
  }

  /** 下拉刷新（统一复位 refreshing） */
  private async refreshView(): Promise<void> {
    if (this.destroyed || this.refreshRunning) { return; }
    this.refreshRunning = true;
    this.refreshing = true;
    try { await this.refreshCurrent(); }
    finally {
      this.refreshRunning = false;
      if (!this.destroyed) { this.refreshing = false; }
    }
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
          .id('fav_back').onClick(() => { router.back(); })
        Text(this.curFolder !== null ? this.curFolder.title : '我的收藏')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
      .backgroundColor($r('app.color.card_bg'))

      if (this.loading) {
        Column() { LoadingProgress().width(40).height(40) }
          .layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (!this.loggedIn) {
        Column({ space: 12 }) {
          Text('未登录')
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
        .justifyContent(FlexAlign.Center)
      } else if (this.curFolder === null) {
        // 收藏夹列表
        if (this.folderPager.loading && !this.folderPager.firstLoaded) {
          Column() {
            LoadingProgress().width(40).height(40)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.folderPager.error.length > 0 && !this.folderPager.firstLoaded) {
          ErrorRetry({ text: this.folderPager.error, onRetry: (): void => {
            this.loadFolders();
          } })
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 2 }) {
            LazyForEach(this.folderDs, (f: FavFolder) => {
              ListItem() {
                FavFolderCard({ folder: f, onOpen: () => { this.navigateFolder(f); } })
              }
            }, (f: FavFolder) => f.id.toString())
            ListItem() {
              LoadingFooter({ text: this.folderDs.size() === 0 ? '还没有收藏夹' : this.folderPager.footerText })
                .padding({ bottom: 100 })
            }
          }
          .width('100%').height('100%').padding({ top: 7 })
          .id('fav_folder_list')
          .onReachEnd(() => {
            this.folderPager.loadMore(this.folderDs,
              (cursor: string): Promise<PageData<FavFolder>> => this.fetchFolders(cursor));
          })
          }.width('100%').layoutWeight(1).onRefreshing(() => { this.refreshView(); })
        }
      } else {
        // 收藏夹内容
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0 }) {
            LazyForEach(this.ds, (it: VideoItem) => {
              ListItem() {
                VideoCard({ model: it })
              }
            }, (it: VideoItem) => it.key)
            ListItem() {
              if (this.pager.error.length > 0) {
                Text(this.pager.error)
                  .fontSize(12)
                  .fontColor($r('app.color.brand_pink'))
                  .padding(12)
                  .onClick(() => {
                    this.refreshCurrent();
                  })
              } else if (!this.pager.hasMore) {
                LoadingFooter({ text: this.ds.size() === 0 ? '收藏夹空空如也' : '没有更多了' })
              } else {
                LoadingFooter({ text: '加载中…' })
              }
            }
          }
          .width('100%')
          .layoutWeight(1)
          .onReachEnd(() => {
            this.loadMore();
          })
        }
        .onRefreshing(() => {
          this.refreshView();
        })
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
