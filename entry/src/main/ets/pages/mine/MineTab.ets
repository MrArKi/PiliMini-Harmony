/**
 * 我的 Tab（spec-02 V2，对齐 Nara 实拍 40）
 *  顶右设置｜头像 + 昵称 + LV/硬币/经验条｜关注·粉丝｜4 入口（离线缓存/观看记录/我的收藏/稍后再看）
 *  观看记录横滑卡片（带进度）｜我的收藏文件夹网格｜退出登录
 * 规格：docs/specs/spec-02-UI基座与我的页.md §7、docs/ui/我的页.html
 */
import { promptAction, router } from '@kit.ArkUI';
import { AsyncImage } from '../../components/AsyncImage';
import { AuthService, UserInfo, RelStat } from '../../service/auth_service';
import { HistoryService, HistoryItem } from '../../service/history_service';
import { FavService, FavFolder } from '../../service/fav_service';
import { onAuthLogout, onHistoryChanged } from '../../infra/event/app_events';
import { formatPlayCount, formatDuration } from '../../components/VideoCard';
import { thumbUrl } from '../../infra/image/bili_image';
import { prefsGet, prefsPut } from '../../infra/storage/prefs';

/** 收藏夹封面本地缓存（folderId → 封面 URL），避免每次进页面都重拉文件夹内容 */
const COVER_CACHE_KEY: string = 'fav_covers_cache';

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
  @State folderCovers: string[] = [];
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

  private entries: MineEntry[] = [
    { title: '离线缓存', icon: $r('app.media.icon_download'), url: 'pages/download/DownloadPage' },
    { title: '观看记录', icon: $r('app.media.icon_history'), url: 'pages/history/HistoryPage' },
    { title: '我的收藏', icon: $r('app.media.icon_star'), url: 'pages/fav/FavListPage' },
    { title: '稍后再看', icon: $r('app.media.icon_clock'), url: 'pages/later/LaterPage' }
  ];

  aboutToAppear(): void {
    this.refresh();
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
    if (this.offAuth !== undefined) {
      this.offAuth();
      this.offAuth = undefined;
    }
    if (this.offHistory !== undefined) { this.offHistory(); this.offHistory = undefined; }
  }

  /** 主壳从其它页面返回（登录态可能变化） */
  onShown(): void {
    this.refresh();
  }

  onActive(): void {
    if (this.active && this.historyDirty) { this.loadHistory(); }
  }

  private async refresh(): Promise<void> {
    const u: UserInfo | null = await AuthService.fetchNav();
    if (this.destroyed) {
      return;
    }
    this.user = u;
    this.checked = true;
    if (u === null) {
      this.historyRequest++;
      this.loadedMid = 0;
      this.rel = { following: 0, follower: 0 };
      this.history = [];
      this.folders = [];
      this.folderCovers = [];
      return;
    }
    this.loadedMid = u.mid;
    this.loadStat(u.mid);
    this.loadHistory();
    this.loadFolders(u.mid);
  }

  private async loadStat(mid: number): Promise<void> {
    const s: RelStat = await AuthService.relationStat(mid);
    if (!this.destroyed) {
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
      this.history = list;
    }
  }

  private async loadFolders(mid: number): Promise<void> {
    try {
      const fs: FavFolder[] = await FavService.folders(mid);
      if (this.destroyed) {
        return;
      }
      // 先用本地缓存（folderId → 封面 URL）填一遍，避免"先空后填"
      const cached: Map<number, string> = await this.loadCoverCache();
      if (this.destroyed) {
        return;
      }
      const covers: string[] = [];
      for (let i = 0; i < fs.length; i++) {
        const hit: string | undefined = cached.get(fs[i].id);
        covers.push(hit !== undefined ? hit : '');
      }
      this.folders = fs;
      this.folderCovers = covers;
      this.loadFolderCovers();
    } catch (e) {
      console.warn('[PiliMini-mine] folders fail=' + JSON.stringify(e));
    }
  }

  /** 本地封面缓存（prefs，JSON：folderId → 封面 URL） */
  private async loadCoverCache(): Promise<Map<number, string>> {
    const out: Map<number, string> = new Map<number, string>();
    try {
      const raw: string = await prefsGet(COVER_CACHE_KEY, '');
      if (raw.length === 0) {
        return out;
      }
      const obj = JSON.parse(raw) as Record<string, string>;
      const keys: string[] = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const id: number = parseInt(keys[i], 10);
        if (!isNaN(id) && id > 0 && obj[keys[i]].length > 0) {
          out.set(id, obj[keys[i]]);
        }
      }
    } catch (e) {
      // 忽略损坏缓存
    }
    return out;
  }

  private async saveCoverCache(id: number, cover: string): Promise<void> {
    try {
      const raw: string = await prefsGet(COVER_CACHE_KEY, '');
      const obj: Record<string, string> = raw.length > 0
        ? JSON.parse(raw) as Record<string, string>
        : {};
      obj[id.toString()] = cover;
      await prefsPut(COVER_CACHE_KEY, JSON.stringify(obj));
    } catch (e) {
      // 忽略
    }
  }

  /** 文件夹封面 = 第一条视频封面（全部取，串行避免密集请求；已有封面不重取） */
  private async loadFolderCovers(): Promise<void> {
    const max: number = this.folders.length;
    for (let i = 0; i < max; i++) {
      if (this.destroyed) {
        return;
      }
      if (i < this.folderCovers.length && this.folderCovers[i] !== undefined && this.folderCovers[i].length > 0) {
        continue;
      }
      try {
        const page = await FavService.folderItems(this.folders[i].id, 1);
        if (this.destroyed) {
          return;
        }
        if (page.items.length > 0) {
          const url: string = page.items[0].cover;
          const next: string[] = this.folderCovers.slice();
          next[i] = url;
          this.folderCovers = next;
          this.saveCoverCache(this.folders[i].id, url);
        }
      } catch (e) {
        console.warn('[PiliMini-mine] cover fail=' + JSON.stringify(e));
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
          AsyncImage({ src: item.cover, w: 440, h: 248 })
        }
        .width('100%')
        .aspectRatio(1.78)
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
        .fontSize(13)
        .lineHeight(18)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 })

      Text(item.upName)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 })
    }
    .width(200)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openVideo(item);
    })
  }

  @Builder
  FolderCard(item: FavFolder, index: number) {
    Column() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (index < this.folderCovers.length && this.folderCovers[index].length > 0) {
          AsyncImage({ src: this.folderCovers[index], w: 440, h: 248 })
            .width('100%')
            .aspectRatio(1.78)
        } else {
          Column() {
            Image($r('app.media.icon_star'))
              .width(28)
              .height(28)
              .fillColor($r('app.color.text_secondary'))
              .opacity(0.6)
          }
          .width('100%')
          .aspectRatio(1.78)
          .justifyContent(FlexAlign.Center)
        }

        Text(item.mediaCount.toString() + '个内容')
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor('#80000000')
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ right: 6, bottom: 6 })
      }
      .width('100%')
      .aspectRatio(1.78)
      .borderRadius(6)
      .clip(true)
      .backgroundColor($r('app.color.card_bg'))

      Text(item.title)
        .fontSize(13)
        .lineHeight(18)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 })

      Text('共' + item.mediaCount.toString() + '条视频 · 公开')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      // 直接打开该收藏夹的内容（FavListPage 读 mediaId/title 参数）
      const params: Record<string, string> = {
        'mediaId': item.id.toString(),
        'title': item.title
      };
      router.pushUrl({ url: 'pages/fav/FavListPage', params: params });
    })
  }

  @Builder
  SectionTitle(title: string, right: string, section: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      if (right.length > 0) {
        Text(right)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      Blank()
      Image($r('app.media.icon_arrow_right'))
            .width(22).height(22)
        .fillColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .onClick(() => {
      if (section === 'history') {
        router.pushUrl({ url: 'pages/history/HistoryPage' });
      } else {
        router.pushUrl({ url: 'pages/fav/FavListPage' });
      }
    })
  }

  @Builder
  HistorySection() {
    Column() {
      this.SectionTitle('观看记录', '', 'history')
      if (this.history.length === 0) {
        Text(this.checked && this.user !== null ? '暂无观看记录' : '登录后查看观看记录')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 16 })
      } else {
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.history, (item: HistoryItem) => {
              this.HistoryCard(item)
            }, (item: HistoryItem) => item.key)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ bottom: 6 })
      }
    }
    .width('100%')
  }

  @Builder
  FavSection() {
    Column() {
      this.SectionTitle('我的收藏', this.folders.length > 0 ? this.folders.length.toString() : '', 'fav')
      if (this.folders.length === 0) {
        Text(this.checked && this.user !== null ? '暂无收藏夹' : '登录后查看收藏')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 16 })
      } else {
        Column({ space: 14 }) {
          ForEach(this.chunkRows(), (row: number[]) => {
            Row({ space: 12 }) {
              ForEach(row, (i: number) => {
                if (i < this.folders.length) {
                  this.FolderCard(this.folders[i], i)
                } else {
                  Column().layoutWeight(1)
                }
              }, (i: number) => 'fc_' + i.toString())
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (row: number[]) => 'fr_' + row[0].toString())
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      }
    }
    .width('100%')
  }

  /** 文件夹按两列分行（[0,1] / [2,3] / ...） */
  private chunkRows(): number[][] {
    const rows: number[][] = [];
    let i: number = 0;
    while (i < this.folders.length) {
      const r: number[] = [i];
      if (i + 1 < this.folders.length) {
        r.push(i + 1);
      }
      rows.push(r);
      i += 2;
    }
    return rows;
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
            .backgroundColor('#F5F5F5')
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
