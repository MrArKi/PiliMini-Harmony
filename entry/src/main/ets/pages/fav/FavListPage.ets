/**
 * 收藏夹页（spec-07）
 *  两级结构：收藏夹列表（名称+数量）→ 点进内容（VideoCard 列表 + 分页 + 下拉刷新）
 *  未登录 → 提示去登录
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router, promptAction } from '@kit.ArkUI';
import { BasicDataSource } from '../../common/list_data_source';
import { Pager, PageData } from '../../common/paged_feed';
import { VideoCard } from '../../components/VideoCard';
import { LoadingFooter, ErrorRetry, EmptyState } from '../../components/StateViews';
import { FavService, FavFolder, FavPage } from '../../service/fav_service';
import { AuthService, UserInfo } from '../../service/auth_service';
import { VideoItem } from '../../model/video_item';

@Entry
@Component
struct FavListPage {
  @State loading: boolean = true;
  @State err: string = '';
  @State loggedIn: boolean = false;
  @State folders: FavFolder[] = [];
  @State curFolder: FavFolder | null = null;
  @State refreshing: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  private ds: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  @State pager: Pager<VideoItem> = new Pager<VideoItem>();
  private mid: number = 0;

  aboutToAppear(): void {
    this.pager.errorDetail = true; // 收藏夹接口错误直接展示服务端/异常信息
    this.init();
  }

  private async init(): Promise<void> {
    const u: UserInfo | null = await AuthService.fetchNav();
    this.loggedIn = u !== null;
    if (!this.loggedIn) {
      this.loading = false;
      return;
    }
    this.mid = (u as UserInfo).mid;
    await this.loadFolders();
    // 从「我的页 → 收藏夹网格」进入：直接打开指定收藏夹（参数 mediaId/title）
    const pm: Record<string, string> | undefined = router.getParams() as Record<string, string> | undefined;
    if (pm !== undefined) {
      const idStr: string | undefined = pm['mediaId'];
      const title: string | undefined = pm['title'];
      const id: number = idStr !== undefined ? parseInt(idStr, 10) : 0;
      if (!isNaN(id) && id > 0) {
        for (let i = 0; i < this.folders.length; i++) {
          if (this.folders[i].id === id) {
            await this.openFolder(this.folders[i]);
            return;
          }
        }
        // 接口未返回该夹（如私密夹）时用参数兜底
        const f: FavFolder = { id: id, title: title !== undefined ? title : '收藏夹', mediaCount: 0 };
        await this.openFolder(f);
      }
    }
  }

  private async loadFolders(): Promise<void> {
    this.loading = true;
    this.err = '';
    try {
      this.folders = await FavService.folders(this.mid);
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loading = false;
    }
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
    this.ds.reload([]);
    this.pager.firstLoaded = false;
    await this.pager.reload(this.ds, (cursor: string): Promise<PageData<VideoItem>> => this.fetchFolderItems(f, cursor));
  }

  private async loadMore(): Promise<void> {
    const f: FavFolder | null = this.curFolder;
    if (f === null) {
      return;
    }
    const ok: boolean = await this.pager.loadMore(this.ds,
      (cursor: string): Promise<PageData<VideoItem>> => this.fetchFolderItems(f, cursor));
    if (!ok && this.pager.hasMore) {
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
    this.refreshing = true;
    await this.refreshCurrent();
    this.refreshing = false;
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
            if (this.curFolder !== null) {
              this.curFolder = null;
              this.ds.reload([]);
            } else {
              router.back();
            }
          })
        Text(this.curFolder !== null ? this.curFolder.title : '收藏夹')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
      .backgroundColor($r('app.color.card_bg'))

      if (!this.loggedIn && !this.loading) {
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
        if (this.loading) {
          Column() {
            LoadingProgress().width(40).height(40)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.err.length > 0) {
          ErrorRetry({ text: this.err, onRetry: (): void => {
            this.loadFolders();
          } })
        } else if (this.folders.length === 0) {
          EmptyState({ text: '还没有收藏夹' })
        } else {
          List() {
            ForEach(this.folders, (f: FavFolder) => {
              ListItem() {
                Row() {
                  Text(f.title)
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                  Text(f.mediaCount.toString() + ' >')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 15, bottom: 15 })
                .onClick(() => {
                  this.openFolder(f);
                })
              }
            }, (f: FavFolder) => f.id.toString())
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 16 })
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
