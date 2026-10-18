/**
 * 我的 Tab（spec-02 V2，对齐 Nara 实拍 40）
 *  顶右设置｜头像 + 昵称 + LV/硬币/经验条｜关注·粉丝｜4 入口（离线缓存/观看记录/我的收藏/稍后再看）
 *  观看记录横滑卡片（带进度）｜我的收藏横向预览｜退出登录
 * 规格：docs/specs/spec-02-UI基座与我的页.md §7、docs/ui/我的页.html
 */
import { promptAction, router } from '@kit.ArkUI';
import { AsyncImage } from '../../components/AsyncImage';
import { AuthService, UserInfo, RelStat } from '../../service/auth_service';
import { HistoryService, HistoryItem } from '../../service/history_service';
import { FavService, FavFolder, FavFolderPage } from '../../service/fav_service';
import { FavFolderCard } from '../../components/FavFolderCard';
import { onAuthLogout, onHistoryChanged } from '../../infra/event/app_events';
import { formatPlayCount, formatDuration } from '../../components/VideoCard';
import { thumbUrl } from '../../infra/image/bili_image';
import { prefsGet, prefsDelete } from '../../infra/storage/prefs';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { BasicDataSource } from '../../common/list_data_source';

interface MineEntry {
  title: string;
  icon: Resource;
  url: string;
}

@Component
export struct MineTab {
  @State user: UserInfo | null = null;
  @State checked: boolean = false;
  @State rel: RelStat = { following: 0, follower: 0 };
  @State history: HistoryItem[] = [];
  @State folders: FavFolder[] = [];
  @State folderTotal: number = 0;
  @State folderError: string = '';
  @Prop @Watch('onShown') refreshTick: number = 0;
  @Prop @Watch('onActive') active: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  private offAuth: (() => void) | undefined = undefined;
  private offHistory: (() => void) | undefined = undefined;
  private historyDirty: boolean = false;
  private historyRequest: number = 0;
  private destroyed: boolean = false;
  /** 已加载数据的账号 mid（相同则返回页面时不重拉收藏/观看记录） */
  private loadedMid: number = 0;
  private accountRequest: number = 0;
  private folderRequest: number = 0;
  private historyDs: BasicDataSource<HistoryItem> = new BasicDataSource<HistoryItem>();
  private folderDs: BasicDataSource<FavFolder> = new BasicDataSource<FavFolder>();

  private entries: MineEntry[] = [
    { title: '离线缓存', icon: $r('app.media.icon_download'), url: 'pages/download/DownloadPage' },
    { title: '观看记录', icon: $r('app.media.icon_history'), url: 'pages/history/HistoryPage' },
    { title: '我的收藏', icon: $r('app.media.icon_star'), url: 'pages/fav/FavListPage' },
    { title: '稍后再看', icon: $r('app.media.icon_clock'), url: 'pages/later/LaterPage' }
  ];

  aboutToAppear(): void {
    this.refresh();
    // 旧版逐夹补封面的URL缓存已不再需要，仅在确实存在时清除。
    prefsGet('fav_covers_cache', '').then((raw: string): void => {
      if (raw.length > 0) { prefsDelete('fav_covers_cache').catch(() => {}); }
    }).catch(() => {});
    this.offAuth = onAuthLogout(() => {
      this.refresh();
    });
    this.offHistory = onHistoryChanged((): void => {
      this.historyDirty = true;
      if (this.active) { this.loadHistory(); }
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.accountRequest++; this.historyRequest++; this.folderRequest++;
    if (this.offAuth !== undefined) {
      this.offAuth();
      this.offAuth = undefined;
    }
    if (this.offHistory !== undefined) { this.offHistory(); this.offHistory = undefined; }
  }

  /** 主壳从其它页面返回（登录态可能变化） */
  onShown(): void {
    this.refreshIfAccountChanged();
  }

  private async refreshIfAccountChanged(): Promise<void> {
    const mid: string = await CookieStore.get('DedeUserID');
    if (this.destroyed) { return; }
    if (this.user !== null && mid === this.loadedMid.toString()) {
      if (this.historyDirty) { this.loadHistory(); }
      return;
    }
    this.refresh();
  }

  onActive(): void {
    if (this.active && this.historyDirty) { this.loadHistory(); }
  }

  private async refresh(): Promise<void> {
    const request: number = ++this.accountRequest;
    const u: UserInfo | null = await AuthService.fetchNav();
    if (this.destroyed || request !== this.accountRequest) {
      return;
    }
    this.user = u;
    this.checked = true;
    if (u === null) {
      this.historyRequest++;
      this.folderRequest++;
      this.loadedMid = 0;
      this.rel = { following: 0, follower: 0 };
      this.history = [];
      this.folders = [];
      this.historyDs.reload([]); this.folderDs.reload([]);
      this.folderTotal = 0;
      this.folderError = '';
      return;
    }
    // 同账号普通路由返回不重拉/重建卡片；真实观看事件已单独标脏。
    if (this.loadedMid === u.mid) {
      if (this.historyDirty) { this.loadHistory(); }
      return;
    }
    this.historyRequest++; this.folderRequest++;
    this.history = []; this.folders = []; this.folderTotal = 0;
    this.historyDs.reload([]); this.folderDs.reload([]);
    this.loadedMid = u.mid;
    this.loadStat(u.mid);
    this.loadHistory();
    this.loadFolders(u.mid);
  }

  private async loadStat(mid: number): Promise<void> {
    const s: RelStat = await AuthService.relationStat(mid);
    if (!this.destroyed && mid === this.loadedMid) {
      this.rel = s;
    }
  }

  private async loadHistory(): Promise<void> {
    const request: number = ++this.historyRequest;
    const mid: number = this.loadedMid;
    if (mid === 0) { return; }
    this.historyDirty = false;
    const list: HistoryItem[] = await HistoryService.recent(20);
    if (!this.destroyed && request === this.historyRequest && mid === this.loadedMid) {
      if (JSON.stringify(this.history) !== JSON.stringify(list)) {
        this.history = list; this.historyDs.reload(list);
      }
    }
  }

  private async loadFolders(mid: number): Promise<void> {
    const request: number = ++this.folderRequest;
    try {
      const page: FavFolderPage = await FavService.folderPage(mid);
      if (this.destroyed || request !== this.folderRequest || mid !== this.loadedMid) { return; }
      this.folderError = '';
      this.folderTotal = page.total;
      if (JSON.stringify(this.folders) !== JSON.stringify(page.items)) {
        this.folders = page.items; this.folderDs.reload(page.items);
      }
    } catch (e) {
      if (!this.destroyed && request === this.folderRequest && mid === this.loadedMid) {
        this.folderError = '收藏夹加载失败，点击刷新重试';
      }
    }
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  private async doLogout(): Promise<void> {
    await AuthService.logout();
    await this.refresh();
    this.toast('已退出登录');
    router.replaceUrl({ url: 'pages/login/LoginPage' });
  }

  private openVideo(item: HistoryItem): void {
    const params: Record<string, string> = { 'bvid': item.bvid, 'title': item.title, 'cid': item.cid.toString() };
    router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
  }

  @Builder
  TopBar() {
    Row() {
      Blank()
      Image($r('app.media.icon_settings'))
        .width(22)
        .height(22)
        .fillColor($r('app.color.text_secondary'))
        .onClick(() => {
          router.pushUrl({ url: 'pages/setting/SettingPage' });
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6 + this.statusBarH })
  }

  @Builder
  ProfileCard() {
    if (this.user !== null) {
      Column({ space: 12 }) {
        Row({ space: 14 }) {
          Column() {
            AsyncImage({ src: thumbUrl((this.user as UserInfo).face, 140, 140), w: 140, h: 140 })
          }
          .width(60)
          .height(60)
          .borderRadius(30)
          .clip(true)
          .backgroundColor($r('app.color.btn_soft_bg'))

          Column({ space: 7 }) {
            Row({ space: 8 }) {
              Text((this.user as UserInfo).uname)
                .fontSize(19)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if ((this.user as UserInfo).level > 0) {
                Text('LV' + (this.user as UserInfo).level.toString())
                  .fontSize(10)
                  .fontColor('#FFFFFF')
                  .backgroundColor($r('app.color.brand_pink'))
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              }
            }

            Row({ space: 14 }) {
              Text('硬币 ' + (this.user as UserInfo).coins.toFixed(1))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              if ((this.user as UserInfo).nextExp > 0) {
                Text('经验 ' + (this.user as UserInfo).curExp.toString() + '/' + (this.user as UserInfo).nextExp.toString())
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              } else {
                Text('经验 ' + (this.user as UserInfo).curExp.toString() + '（满级）')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
            }

            Progress({
              value: (this.user as UserInfo).nextExp > 0 ? (this.user as UserInfo).curExp : 1,
              total: (this.user as UserInfo).nextExp > 0 ? (this.user as UserInfo).nextExp : 1,
              type: ProgressType.Linear
            })
              .height(4)
              .color($r('app.color.brand_pink'))
              .backgroundColor($r('app.color.divider'))
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')

        Row() {
          Column({ space: 3 }) {
            Text(formatPlayCount(this.rel.following))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('关注')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)

          Column({ space: 3 }) {
            Text(formatPlayCount(this.rel.follower))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('粉丝')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    } else {
      Row({ space: 14 }) {
        Column() {
          Text('未登录')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width(60)
        .height(60)
        .borderRadius(30)
        .backgroundColor($r('app.color.btn_soft_bg'))
        .justifyContent(FlexAlign.Center)

        Column({ space: 4 }) {
          Text('未登录')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.checked ? '扫码登录后可同步收藏与稍后再看' : '读取登录态…')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('去登录')
          .fontSize(13)
          .backgroundColor($r('app.color.brand_pink'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/login/LoginPage' });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    }
  }

  @Builder
  EntryRow() {
    Row() {
      ForEach(this.entries, (item: MineEntry) => {
        Column({ space: 7 }) {
          Image(item.icon)
            .width(24)
            .height(24)
            .fillColor($r('app.color.text_primary'))
          Text(item.title)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
        }
        .layoutWeight(1)
        .onClick(() => {
          router.pushUrl({ url: item.url });
        })
      }, (item: MineEntry) => item.title)
    }
    .width('100%')
    .padding({ top: 16, bottom: 16 })
  }

  @Builder
  HistoryCard(item: HistoryItem) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Column() {
          AsyncImage({ src: item.cover, w: 360, h: 220 })
        }
        .width('100%')
        .height(110)
        .borderRadius(6)
        .clip(true)
        .backgroundColor($r('app.color.btn_soft_bg'))

        Text(item.progress === -1 ? '已看完' : formatDuration(Math.max(0, item.progress)) + '/' + formatDuration(item.duration))
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor('#80000000')
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 6, bottom: 6 })
      }
      .width('100%')

      Text(item.title)
        .fontSize(12)
        .lineHeight(18)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 })

      Text(item.upName)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 0 })
    }
    .width(180)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openVideo(item);
    })
  }

  @Builder
  SectionTitle(title: string, section: string) {
    Row() {
      Row({ space: 6 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      if (section === 'fav' && this.folderTotal > 0) {
        Text(this.folderTotal.toString())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      Image($r('app.media.icon_arrow_right'))
            .width(18).height(18)
        .fillColor($r('app.color.text_secondary'))
      }.layoutWeight(1).onClick(() => {
        router.pushUrl({ url: section === 'history' ? 'pages/history/HistoryPage' : 'pages/fav/FavListPage' });
      })
      if (this.user !== null) {
        Image($r('app.media.icon_refresh')).width(20).height(20).margin({ left: 12 })
          .fillColor($r('app.color.text_secondary'))
          .id('mine_refresh_' + section)
          .onClick(() => {
            if (section === 'history') { this.loadHistory(); }
            else { this.loadFolders(this.loadedMid); }
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  @Builder
  HistorySection() {
    Column() {
      this.SectionTitle('观看记录', 'history')
      if (this.history.length === 0) {
        Text(this.checked && this.user !== null ? '暂无观看记录' : '登录后查看观看记录')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 16 })
      } else {
        List({ space: 14 }) {
          LazyForEach(this.historyDs, (item: HistoryItem) => {
            ListItem() { this.HistoryCard(item) }
          }, (item: HistoryItem) => item.key)
          ListItem() {
            Image($r('app.media.icon_arrow_right')).width(18).height(18).padding(12)
              .backgroundColor($r('app.color.btn_soft_bg')).borderRadius(24)
              .onClick(() => { router.pushUrl({ url: 'pages/history/HistoryPage' }); })
          }
        }.listDirection(Axis.Horizontal).alignListItem(ListItemAlign.Start).cachedCount(1)
          .scrollBar(BarState.Off).width('100%').height(173)
          .padding({ left: 20, right: 20, top: 10 }).id('mine_history_preview')
      }
    }
    .width('100%')
  }

  @Builder
  FavSection() {
    Column() {
      this.SectionTitle('我的收藏', 'fav')
      if (this.folders.length === 0) {
        Text(this.folderError || (this.checked && this.user !== null ? '暂无收藏夹' : '登录后查看收藏'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 16 })
      } else {
        List({ space: 14 }) {
            LazyForEach(this.folderDs, (folder: FavFolder) => {
              ListItem() {
              FavFolderCard({ folder: folder, preview: true, onOpen: () => {
                router.pushUrl({ url: 'pages/fav/FavListPage',
                  params: { mediaId: folder.id.toString(), title: folder.title } });
              } })
              }
            }, (folder: FavFolder) => folder.id.toString())
            if (this.folderTotal > this.folders.length) {
              ListItem() {
              Image($r('app.media.icon_arrow_right')).width(18).height(18).padding(12)
                .backgroundColor($r('app.color.btn_soft_bg')).borderRadius(24)
                .onClick(() => { router.pushUrl({ url: 'pages/fav/FavListPage' }); })
              }
            }
        }.listDirection(Axis.Horizontal).alignListItem(ListItemAlign.Start).cachedCount(1)
          .padding({ left: 20, right: 20, top: 10 }).scrollBar(BarState.Off).height(173).width('100%')
          .id('mine_fav_preview')
      }
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column() {
        this.TopBar()
        this.ProfileCard()
        this.EntryRow()
        this.HistorySection()
        this.FavSection()

        if (this.checked && this.user !== null) {
          Button('退出登录')
            .fontSize(14)
            .width('92%')
            .backgroundColor($r('app.color.btn_soft_bg'))
            .fontColor('#E54D42')
            .margin({ top: 16 })
            .onClick(() => {
              this.doLogout();
            })
        }

        Column()
          .width('100%')
          .height(120)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }
}
