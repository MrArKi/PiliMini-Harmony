/**
 * 视频详情页（spec-05 + 评论区返工 R1~R9，以 PiliNara 为交互与样式基准）
 *  信息区 / UP 主区（R8）/ 简介折叠 / 分P 选集 / 操作区
 *  评论区：排序切换（R5）+ 置顶评论（R7）+ 骨架屏（R6）+ 下拉刷新（R6）
 *          评论图片（R9）+ 子回复容器（R1/R2）+ 楼中楼面板 bindSheet（R3）+ 操作行点赞（R4）
 * 规格来源：docs/ui/评论区.html、docs/参考-NaraUI基准.md §1
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { openMember } from '../../common/member_route';
import { router, promptAction, window, display, curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BasicDataSource } from '../../common/list_data_source';
import { AsyncImage } from '../../components/AsyncImage';
import { CommentItemView, CommentSkeleton } from '../../components/CommentItem';
import { PlayerView } from '../../components/player/PlayerView';
import { refreshSystemBars } from '../../infra/player/system_bars';
import { PlaybackSource } from '../../infra/player/play_controller';
import { LoadingFooter } from '../../components/StateViews';
import { formatPlayCount, formatDuration } from '../../components/VideoCard';
import { VideoItem } from '../../model/video_item';
import { VideoService, VideoDetail, VideoPageInfo, CommentItem, SubReplyPage } from '../../service/video_service';
import { SubReplyPanel } from '../../components/SubReplyPanel';
import { AuthService } from '../../service/auth_service';
import { FavService, FavFolder } from '../../service/fav_service';
import { DownloadService, DownloadTask } from '../../service/download_service';
import { DownloadLibraryService } from '../../service/download_library_service';
import { OfflineContext } from '../../model/download';
import { prefsGet } from '../../infra/storage/prefs';

function two(n: number): string {
  const s: string = n.toString();
  return s.length >= 2 ? s : '0' + s;
}

function fmtDate(ts: number): string {
  const d = new Date(ts * 1000);
  return d.getFullYear().toString() + '-' + two(d.getMonth() + 1) + '-' + two(d.getDate());
}

/** Nara NestedScrollView：上划先头部，下拉先当前列表；两个Tab必须共用。 */
const DETAIL_NESTED_SCROLL: NestedScrollOptions = {
  scrollForward: NestedScrollMode.PARENT_FIRST,
  scrollBackward: NestedScrollMode.SELF_FIRST
};

/** Nara在Harmony上用BouncingScrollPhysicsExt：速度按0.135^t衰减。
 * ArkUI指数系数为-4.2×friction；内外层固定同一阻尼，避免默认慢速模式提前制动。 */
const DETAIL_SCROLL_FRICTION: number = -Math.log(0.135) / 4.2;

@Entry
@Component
struct VideoDetailPage {
  @State bvid: string = '';
  @State detail: VideoDetail | undefined = undefined;
  @State loading: boolean = true;
  @State error: string = '';
  @State descExpanded: boolean = false;
  @State @Watch('onPageIndexChange') currentPageIdx: number = 0;
  private initialCid: number = 0;
  @State loggedIn: boolean = false;
  /** spec-06a：内嵌播放器全屏态 */
  @State @Watch('syncFullscreenBars') isFullscreen: boolean = false;

  // ===== 评论（R5/R6/R7） =====
  @State replyTotal: number = 0;
  @State replyEnd: boolean = false;
  @State replyErr: string = '';
  @State sortMode: number = 3; // 3=按热度 2=按时间
  @State sortName: string = '热门评论';
  @State topItems: CommentItem[] = [];
  @State firstLoading: boolean = false; // 骨架屏（R6）
  @State refreshing: boolean = false;
  @State refreshPullOffset: number = 0;

  // ===== UP 主区（R8） =====
  @State upFans: number = 0;

  // ===== 收藏/稍后再看（spec-07） =====
  @State favoured: boolean = false;
  @State laterAdded: boolean = false;
  @State favSheetShown: boolean = false;
  @State favSubmitting: boolean = false;
  @State folders: FavFolder[] = [];
  @State folderChecked: boolean[] = [];
  private folderOriginal: boolean[] = [];
  private favFoldersReady: boolean = false;
  private laterSubmitting: boolean = false;
  @State cachedCids: number[] = [];
  @State cacheSubmitting: boolean = false;
  private downloadChange: () => void = (): void => { this.refreshCacheState(); };

  private aid: number = 0;
  private upMid: number = 0;
  private nextOffset: string = '';
  private loadingMoreReply: boolean = false;
  private destroyed: boolean = false;
  @State routeVisible: boolean = true;
  private releasePlayer: () => Promise<void> = (): Promise<void> => Promise.resolve();
  private exitPending: boolean = false;
  private commentGeneration: number = 0;
  private orientationGeneration: number = 0;
  @State localCid: number = 0;
  private routeIndex: number = 0;
  private hideTimer: number = -1;
  @State nativeWidth: number = 0;
  @State nativeHeight: number = 0;
  private windowSizeHandler: (size: window.Size) => void = (size: window.Size): void => {
    if (!this.destroyed) { this.onWindowSize(size); }
  };
  /** 离线播放：本地文件路径（非空 = 播放已下载文件，播放器同在线一套 UI） */
  @State localPath: string = '';
  @State localCover: string = '';
  @State localArtist: string = '';
  @State localDuration: number = 0;
  @State localSource: PlaybackSource | undefined = undefined;
  private offlineContext: OfflineContext = new OfflineContext();
  @State offlineTasks: DownloadTask[] = [];
  private offlineDs: BasicDataSource<DownloadTask> = new BasicDataSource<DownloadTask>();
  @State localTitle: string = '';
  /** 全屏请求与已提交布局分开；实际窗口到位后与布局一起提交。 */
  private mainWin: window.Window | undefined = undefined;
  private fullscreenTarget: boolean | undefined = undefined;
  private fsFallbackTimer: number = -1;
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  /** 当前窗口是否横屏（进全屏过渡期：竖屏下播放器保持 16:9 不拉伸） */
  @State isLandscape: boolean = false;
  /** 楼中楼面板 */
  private ds: BasicDataSource<CommentItem> = new BasicDataSource<CommentItem>();
  /** 0=简介 1=评论（对齐 Nara 详情页分段 tab） */
  @State tab: number = 0;
  /** 原生Tabs逐帧位移同时驱动标题和单一下划线，覆盖拖动/回弹/点击动画。 */
  @State tabProgress: number = 0;
  @State tabBarWidth: number = 360;
  @State introLabelWidth: number = 26;
  @State replyLabelWidth: number = 26;
  private tabsCtrl: TabsController = new TabsController();
  @State related: VideoItem[] = [];
  @State followed: boolean = false;
  @State followBusy: boolean = false;
  /** 收窄交互：播放状态 / 累计滚动 / 收窄比例(0~1) / 继续播放命令计数 */
  @State playerState: string = 'idle';
  @State collapseRatio: number = 0;
  @State resumeTick: number = 0;
  @State subShown: boolean = false;
  @State subRoot: CommentItem | undefined = undefined;
  private subClosing: boolean = false;
  @State scrollAcc: number = 0;
  private introScroller: Scroller = new Scroller();
  private replyScroller: Scroller = new Scroller();
  private headerScroller: Scroller = new Scroller();
  @State headerExpanding: boolean = false;
  @State pageHeight: number = 0;
  @State replyHeaderOffset: number = 0;
  private lastReplyOffset: number = 0;
  private effectiveReplyOffset: number = 0;
  /** 屏幕宽高（vp；播放器高度用） */
  private screenW: number = 360;
  private screenH: number = 780;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;

  aboutToAppear(): void {
    DownloadService.init(getContext(this) as common.Context);
    DownloadService.onChange(this.downloadChange);
    DownloadService.load().then((): void => { this.refreshCacheState(); }).catch((): void => {
      // 下载资料损坏只影响缓存管理，不能阻断在线播放；缓存入口会报告原错误。
      if (!this.destroyed) { this.cachedCids = []; }
    });
    try {
      const disp = display.getDefaultDisplaySync();
      this.screenW = px2vp(disp.width);
      this.screenH = px2vp(disp.height);
    } catch (e) {
      // 兜底默认值
    }
    // 全屏退出动画：监听窗口尺寸变化（转回竖屏后再恢复布局）
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      if (this.destroyed) {
        return;
      }
      this.mainWin = win;
      win.on('windowSizeChange', this.windowSizeHandler);
      const rect: window.Rect = win.getWindowProperties().windowRect;
      this.onWindowSize({ width: rect.width, height: rect.height });
    }).catch(() => {
      // 忽略
    });
    const pm: Record<string, string> | undefined = router.getParams() as Record<string, string> | undefined;
    if (pm !== undefined) {
      const b: string | undefined = pm['bvid'];
      if (b !== undefined) {
        this.bvid = b;
      }
      const cid: number = Number(pm['cid'] || '0');
      if (Number.isSafeInteger(cid) && cid > 0) { this.initialCid = cid; }
      const lp: string | undefined = pm['localPath'];
      if (lp !== undefined && lp.length > 0) {
        this.localPath = lp;
        this.localCid = parseInt(pm['cid'] || '0', 10);
        this.localCover = pm['localCover'] || ''; this.localArtist = pm['localArtist'] || '';
        this.localDuration = Number(pm['localDuration'] || '0');
        this.offlineContext = { scope: pm['offlineScope'] || 'all', key: pm['offlineKey'] || '' };
      }
      const lt: string | undefined = pm['title'];
      if (lt !== undefined) {
        this.localTitle = lt;
      }
    }
    if (this.localPath) { this.updateLocalSource(); }
    this.fetch();
  }

  aboutToDisappear(): void {
    AppStorage.setOrCreate<boolean>('playerFullscreen', false);
    DownloadService.offChange(this.downloadChange);
    if (this.hideTimer !== -1) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
    this.destroyed = true;
    refreshSystemBars(getContext(this) as common.UIAbilityContext);
    this.commentGeneration++;
    this.orientationGeneration++;
    if (this.fsFallbackTimer !== -1) {
      clearTimeout(this.fsFallbackTimer);
      this.fsFallbackTimer = -1;
    }
    if (this.mainWin !== undefined) {
      this.mainWin.off('windowSizeChange', this.windowSizeHandler);
      this.mainWin = undefined;
    }
    // 全屏态直接返回（系统返回键）时恢复竖屏，否则主壳留在横屏；
    // 竖屏视频全屏（未旋转窗口）无需恢复
    if (this.isFullscreen || this.fullscreenTarget !== undefined || this.isLandscape) {
      this.fullscreenTarget = undefined;
      this.isFullscreen = false;
      const ctx = getContext(this);
      window.getLastWindow(ctx).then((win: window.Window) => {
        win.setPreferredOrientation(window.Orientation.PORTRAIT).catch(() => {
          // 忽略
        });
      }).catch(() => {
        // 忽略
      });
    }
  }

  onPageHide(): void {
    if (this.hideTimer !== -1) { clearTimeout(this.hideTimer); }
    // 页面在应用退后台时也收到 hide；仅路由栈顶改变才暂停。
    this.hideTimer = setTimeout((): void => {
      this.hideTimer = -1;
      if (!this.destroyed && router.getState().index !== this.routeIndex) { this.routeVisible = false; }
      refreshSystemBars(getContext(this) as common.UIAbilityContext);
    }, 20);
  }
  onPageShow(): void {
    if (this.hideTimer !== -1) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
    this.routeIndex = router.getState().index;
    this.routeVisible = true;
    if (this.upMid > 0) {
      VideoService.relationState(this.upMid).then((followed: boolean) => {
        if (!this.destroyed) { this.followed = followed; }
      });
    }
    this.syncFullscreenBars();
  }

  /** 当前分P 的 cid */
  private syncFullscreenBars(): void {
    AppStorage.setOrCreate<boolean>('playerFullscreen', (this.fullscreenTarget ?? this.isFullscreen) && !this.destroyed);
    refreshSystemBars(getContext(this) as common.UIAbilityContext);
  }

  /** 当前分P 的 cid */
  private currentCid(): number {
    if (this.localPath.length > 0) { return this.localCid; }
    const d: VideoDetail | undefined = this.detail;
    if (d === undefined || d.pages.length === 0) {
      return 0;
    }
    const idx: number = Math.min(this.currentPageIdx, d.pages.length - 1);
    return d.pages[idx].cid;
  }

  private onPageIndexChange(): void { this.nativeWidth = 0; this.nativeHeight = 0; }

  private sourceDimension(width: boolean): number {
    const d: VideoDetail | undefined = this.detail;
    if (d === undefined || d.pages.length === 0) { return 0; }
    const localIdx: number = this.localPath.length > 0 ? d.pages.findIndex((p: VideoPageInfo): boolean => p.cid === this.localCid) : -1;
    const idx: number = localIdx >= 0 ? localIdx : Math.min(this.currentPageIdx, d.pages.length - 1);
    return width ? d.pages[idx].width : d.pages[idx].height;
  }

  /** 播放器标题副行（多 P 显示当前 part） */
  private partLabel(): string {
    const d: VideoDetail | undefined = this.detail;
    if (d === undefined || d.pages.length <= 1) {
      return '';
    }
    const idx: number = Math.min(this.currentPageIdx, d.pages.length - 1);
    const p: VideoPageInfo = d.pages[idx];
    return 'P' + p.page.toString() + ' ' + p.part;
  }

  /** 当前分P 是否竖屏视频（高 > 宽；dimension 缺失视为横屏，Nara isVertical 同构） */
  private isVerticalVideo(): boolean {
    if (this.nativeWidth > 0 && this.nativeHeight > 0) { return this.nativeHeight > this.nativeWidth; }
    return this.sourceDimension(false) > this.sourceDimension(true);
  }

  /** 播放器高度：横屏视频 16:9（Nara minVideoHeight）；竖屏视频 max(屏高*0.65, 屏宽)（Nara maxVideoHeight）；
   全屏在 build 里用 100% 铺满 */
  private playerHeight(): number {
    const shortSide: number = Math.min(this.screenW, this.screenH);
    const longSide: number = Math.max(this.screenW, this.screenH);
    if (this.isVerticalVideo()) {
      return Math.max(longSide * 0.65, shortSide);
    }
    return shortSide * 9 / 16;
  }

  /** Nara VideoHeader：竖视频先收至16:9，暂停时才可继续收至56。 */
  private playerBoxHeight(): number {
    const full: number = this.playerHeight() + this.statusBarH;
    return full - Math.min(this.scrollAcc, this.playerHeight() - 56);
  }

  /** 返回主页（Nara onCloseAll）：栈里有主壳则回退到它，否则用 replaceUrl 兜底 */
  private goHome(): void {
    this.leaveVideo(true);
  }

  /** 原生输出先关闭，Surface随后由路由销毁，不能把两者同时发起。 */
  private async leaveVideo(toHome: boolean = false): Promise<void> {
    if (this.destroyed || this.exitPending) { return; }
    this.exitPending = true;
    try {
      await this.releasePlayer();
      if (this.destroyed) { return; }
      if (toHome) {
        try { router.back({ url: 'pages/main/MainShell' }); }
        catch (_) { await router.replaceUrl({ url: 'pages/main/MainShell' }); }
      } else { router.back(); }
    } catch (_) {
      this.exitPending = false;
      if (!this.destroyed) { promptAction.showToast({ message: '退出播放失败，请重试' }); }
    }
  }

  private minimumPlayerHeight(): number {
    return !this.headerExpanding && (this.playerState === 'playing' || this.playerState === 'loading') ?
      Math.min(this.screenW, this.screenH) * 9 / 16 : 56;
  }

  private bodyHeight(): number {
    return Math.max(1, (this.pageHeight || this.screenH) - this.statusBarH - this.minimumPlayerHeight());
  }

  private visibleBodyHeight(): number {
    return Math.max(1, (this.pageHeight || this.screenH) - this.playerBoxHeight());
  }

  /** 外层真实滚动量是唯一来源；原生嵌套链负责内外层和Refresh的边界交接。 */
  private syncHeaderScroll(): void {
    const minVideo: number = Math.min(this.screenW, this.screenH) * 9 / 16;
    this.scrollAcc = Math.max(0, this.headerScroller.currentOffset().yOffset);
    if (this.scrollAcc < 0.1) { this.headerExpanding = false; }
    this.collapseRatio = Math.max(0, Math.min(1,
      (this.scrollAcc - (this.playerHeight() - minVideo)) / Math.max(1, minVideo - 56)));
  }

  /** Nara RenderSliverFloatingHeader：上划离屏，下划从评论视口顶部浮出。 */
  private syncReplyHeader(): void {
    const offset: number = Math.max(0, this.replyScroller.currentOffset().yOffset);
    const delta: number = offset - this.lastReplyOffset;
    if (delta < 0 || this.effectiveReplyOffset < 45) {
      if (delta < 0) { this.effectiveReplyOffset = Math.min(45, this.effectiveReplyOffset); }
      this.effectiveReplyOffset = Math.max(0, Math.min(offset, this.effectiveReplyOffset + delta));
    } else { this.effectiveReplyOffset = offset; }
    this.lastReplyOffset = offset;
    this.replyHeaderOffset = Math.min(45, this.effectiveReplyOffset);
  }

  private async fetch(): Promise<void> {
    if (this.localPath.length > 0) {
      try {
        await DownloadService.load();
        if (this.destroyed) { return; }
        this.offlineTasks = DownloadLibraryService.playlist(this.offlineContext);
        this.offlineDs.reload(this.offlineTasks);
        const task = this.offlineTasks.find((t: DownloadTask): boolean => t.bvid === this.bvid && t.cid === this.localCid);
        if (!task) { this.error = '本地文件已失效，请返回缓存页检查'; }
        else { this.localCover = task.cover; this.localArtist = task.upName; this.localDuration = task.duration; }
      } catch (e) { if (!this.destroyed) { this.error = (e as Error).message; } }
      if (!this.destroyed) { this.loading = false; }
      return;
    }
    if (this.bvid.length === 0) {
      this.error = '缺少 bvid';
      this.loading = false;
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const d: VideoDetail = await VideoService.viewDetail(this.bvid);
      if (this.destroyed) {
        return;
      }
      const initialPage: number = d.pages.findIndex((p: VideoPageInfo): boolean => p.cid === this.initialCid);
      if (initialPage >= 0) { this.currentPageIdx = initialPage; }
      this.initialCid = 0;
      this.detail = d;
      this.aid = d.aid;
      this.upMid = d.ownerMid;
      this.replyTotal = d.replyCount;
      this.loggedIn = await AuthService.isLogin();
      if (this.destroyed) {
        return;
      }
      this.loading = false;
      this.loadComments(true);
      // UP 主粉丝数（R8，非阻塞）
      VideoService.fans(d.ownerMid).then((n: number) => {
        if (!this.destroyed) {
          this.upFans = n;
        }
      });
      // 收藏状态 + 收藏夹列表（spec-07，非阻塞）
      this.loadFavState();
      // 相关推荐（spec-05 V2「简介」面板底部，非阻塞）
      VideoService.related(this.bvid).then((list: VideoItem[]) => {
        if (!this.destroyed) {
          this.related = list;
        }
      }).catch(() => {
      });
      // UP 关注状态（非阻塞）
      VideoService.relationState(d.ownerMid).then((f: boolean) => {
        if (!this.destroyed) {
          this.followed = f;
        }
      });
    } catch (e) {
      if (this.destroyed) {
        return;
      }
      const err = e as Error;
      this.error = err.message !== undefined && err.message.length > 0 ? ('加载失败：' + err.message) : '加载失败，请重试';
      this.loading = false;
    }
  }

  private async loadComments(reset: boolean): Promise<void> {
    if (this.destroyed || (!reset && this.loadingMoreReply) || this.aid === 0) {
      return;
    }
    if (!reset && this.replyEnd) {
      return;
    }
    this.loadingMoreReply = true;
    const generation: number = reset ? ++this.commentGeneration : this.commentGeneration;
    this.replyErr = '';
    if (reset) {
      this.firstLoading = true;
    }
    try {
      const r = await VideoService.reply(this.aid, reset ? '' : this.nextOffset, this.sortMode);
      if (this.destroyed || generation !== this.commentGeneration) {
        return;
      }
      if (reset) {
        this.ds.reload(r.items);
        this.topItems = r.topItems;
      } else {
        this.ds.append(r.items);
      }
      if (r.total > 0) {
        this.replyTotal = r.total;
      }
      if (r.sortName.length > 0) {
        this.sortName = r.sortName;
      }
      this.nextOffset = r.nextOffset;
      this.replyEnd = r.isEnd;
    } catch (e) {
      if (this.destroyed || generation !== this.commentGeneration) { return; }
      const err = e as Error;
      this.replyErr = '评论加载失败，点击重试';
    } finally {
      if (!this.destroyed && generation === this.commentGeneration) {
        this.loadingMoreReply = false;
        this.firstLoading = false;
        this.refreshing = false;
      }
    }
  }

  /** R5：排序切换（热门 ↔ 时间） */
  private switchSort(): void {
    this.sortMode = this.sortMode === 3 ? 2 : 3;
    this.sortName = this.sortMode === 3 ? '热门评论' : '最新评论';
    this.replyEnd = false;
    this.nextOffset = '';
    this.loadComments(true);
  }

  /** Nara replyReply：只覆盖详情区，视频继续使用同一Surface。 */
  private toggleSub(item: CommentItem): void {
    if (this.subShown || this.subClosing) { return; }
    this.subRoot = item;
    animateTo({ duration: 250, curve: curves.cubicBezierCurve(0.4, 0, 0.2, 1) }, () => { this.subShown = true; });
  }

  private closeSub(): void {
    if (!this.subShown || this.subClosing) { return; }
    this.subClosing = true;
    animateTo({ duration: 200, curve: curves.cubicBezierCurve(0.4, 0, 0.2, 1), onFinish: () => {
      this.subClosing = false;
      if (!this.destroyed) { this.subRoot = undefined; }
    } }, () => { this.subShown = false; });
  }

  private loadSubMore(item: CommentItem): void {
    this.toggleSub(item);
  }

  /** 评论条目就地刷新（注意：点击回调拿到的是 @ObjectLink 代理，须按 rpid 匹配而非引用） */
  private refreshComment(item: CommentItem): void {
    for (let i = 0; i < this.ds.size(); i++) {
      if (this.ds.getData(i).rpid === item.rpid) {
        this.ds.notifyChange(i);
        return;
      }
    }
    for (let i = 0; i < this.topItems.length; i++) {
      if (this.topItems[i].rpid === item.rpid) {
        this.topItems = this.topItems.slice();
        return;
      }
    }
  }

  /** spec-06a：全屏 = 横屏 + 隐藏其它内容（Nara 同构）；竖屏视频全屏不旋转（Nara FullScreenMode.vertical 同构） */
  private async toggleFullscreen(): Promise<void> {
    if (this.destroyed || this.fullscreenTarget !== undefined) { return; }
    const generation: number = ++this.orientationGeneration;
    const target: boolean = !this.isFullscreen;
    if (this.isVerticalVideo()) {
      // 竖屏视频：全屏 = 竖向铺满整屏，不请求横屏旋转
      this.isFullscreen = target;
      return;
    }
    this.fullscreenTarget = target;
    this.syncFullscreenBars();
    // 仅作请求看门狗，正常路径由窗口尺寸事件完成，无动画等待定时器。
    this.fsFallbackTimer = setTimeout((): void => {
      this.fsFallbackTimer = -1;
      if (!this.destroyed && generation === this.orientationGeneration && this.fullscreenTarget !== undefined) {
        this.finishFullscreen(this.viewportWidth, this.viewportHeight);
        if (this.fullscreenTarget !== undefined) { this.cancelFullscreen(generation); }
      }
    }, 1500);
    try {
      const win: window.Window = await this.getWin();
      if (this.destroyed || generation !== this.orientationGeneration) { return; }
      await win.setPreferredOrientation(target ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
      if (this.destroyed) { await win.setPreferredOrientation(window.Orientation.PORTRAIT); return; }
      if (generation === this.orientationGeneration) {
        this.finishFullscreen(this.viewportWidth, this.viewportHeight);
      } else {
        // 超时后的迟到请求不能把新请求/已提交的页面留在旧方向。
        const landscape: boolean = this.fullscreenTarget ?? this.isFullscreen;
        await win.setPreferredOrientation(landscape ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
      }
    } catch (e) {
      this.cancelFullscreen(generation);
    }
  }

  private finishFullscreen(width: number, height: number): void {
    const target: boolean | undefined = this.fullscreenTarget;
    if (this.destroyed || target === undefined || width <= 0 || height <= 0 || (width > height) !== target) { return; }
    if (this.fsFallbackTimer !== -1) { clearTimeout(this.fsFallbackTimer); this.fsFallbackTimer = -1; }
    this.fullscreenTarget = undefined;
    this.isFullscreen = target;
  }

  private cancelFullscreen(generation: number): void {
    if (this.destroyed || generation !== this.orientationGeneration || this.fullscreenTarget === undefined) { return; }
    if (this.fsFallbackTimer !== -1) { clearTimeout(this.fsFallbackTimer); this.fsFallbackTimer = -1; }
    this.fullscreenTarget = undefined;
    this.orientationGeneration++;
    this.syncFullscreenBars();
    if (this.mainWin !== undefined) {
      this.mainWin.setPreferredOrientation(this.isFullscreen ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT)
        .catch((): void => { console.warn('[VideoDetail] 恢复屏幕方向失败'); });
    }
    console.warn('[VideoDetail] 全屏方向切换未完成');
    promptAction.showToast({ message: '屏幕方向切换未完成，请重试' });
  }

  private async getWin(): Promise<window.Window> {
    const w: window.Window | undefined = this.mainWin;
    if (w !== undefined) {
      return w;
    }
    const nw: window.Window = await window.getLastWindow(getContext(this));
    if (this.destroyed) { throw new Error('页面已退出'); }
    this.mainWin = nw;
    return nw;
  }

  /** 方向已真实改变，在ArkUI下一轮布局前提交，避免先布局中间尺寸Surface。 */
  private onWindowSize(size: window.Size): void {
    this.viewportWidth = size.width; this.viewportHeight = size.height;
    this.isLandscape = size.width > size.height;
    this.finishFullscreen(size.width, size.height);
  }

  /** 系统返回（侧滑/按键）：全屏时先退全屏，不退出页面 */
  onBackPress(): boolean {
    if (this.subShown || this.subClosing) { this.closeSub(); return true; }
    if (this.fullscreenTarget !== undefined) {
      return true;
    }
    if (this.isFullscreen) {
      this.toggleFullscreen();
      return true;
    }
    this.leaveVideo();
    return true;
  }

  private onFav(): void {
    if (!this.loggedIn) {
      promptAction.showToast({ message: '请先登录（我的页 → 去登录）' });
      return;
    }
    if (!this.favFoldersReady || this.folders.length === 0) {
      promptAction.showToast({ message: '收藏夹加载中，请稍候' });
      this.loadFavState();
      return;
    }
    const checked: boolean[] = this.folderOriginal.slice();
    if (!this.favoured && checked.length > 0) { checked[0] = true; }
    this.folderChecked = checked;
    this.favSheetShown = true;
  }

  private async onLater(): Promise<void> {
    if (!this.loggedIn) {
      promptAction.showToast({ message: '请先登录（我的页 → 去登录）' });
      return;
    }
    if (this.laterSubmitting) { return; }
    this.laterSubmitting = true;
    try {
      if (this.laterAdded) {
        await FavService.laterRemove(this.aid);
        this.laterAdded = false;
        promptAction.showToast({ message: '已移出稍后再看' });
      } else {
        await FavService.laterAdd(this.aid);
        this.laterAdded = true;
        promptAction.showToast({ message: '已加入稍后再看' });
      }
    } catch (e) {
      promptAction.showToast({ message: '操作失败：' + (e as Error).message });
    } finally { this.laterSubmitting = false; }
  }

  /** spec-09：加入下载（串行单任务，取当前分P） */
  private async onCache(): Promise<void> {
    if (this.cacheSubmitting) { return; }
    if (this.cachedCids.indexOf(this.currentCid()) >= 0) {
      router.pushUrl({ url: 'pages/download/DownloadPage' });
      return;
    }
    const d: VideoDetail | undefined = this.detail;
    if (d === undefined || d.pages.length === 0) {
      return;
    }
    DownloadService.init(getContext(this) as common.Context);
    const p: VideoPageInfo = d.pages[Math.min(this.currentPageIdx, d.pages.length - 1)];
    this.cacheSubmitting = true;
    try {
      const qnStr: string = await prefsGet('setting_default_qn', '80');
      if (this.destroyed) { return; }
      const qn: number = parseInt(qnStr, 10);
      const realQn: number = isNaN(qn) ? 80 : qn;
      const part: string = d.pages.length > 1 ? ('P' + p.page.toString() + ' ' + p.part) : '';
      const existing: DownloadTask | undefined = DownloadService.list().find((t: DownloadTask): boolean =>
        t.bvid === this.bvid && t.cid === p.cid);
      if (existing !== undefined && existing.status === 'failed') { await DownloadService.resume(p.cid); }
      else { await DownloadService.add(this.bvid, p.cid, d.title, d.cover, realQn, part, p.duration, d.ownerName,
        { page: p.page, seasonId: d.seasonId || '', seasonTitle: d.seasonTitle || '', seasonOrder: d.seasonOrder || 0 }); }
      this.refreshCacheState();
      promptAction.showToast({ message: '已加入缓存队列' });
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message });
    } finally { this.cacheSubmitting = false; }
  }

  private refreshCacheState(): void {
    if (this.destroyed) { return; }
    this.cachedCids = DownloadService.list().filter((t: DownloadTask): boolean =>
      t.bvid === this.bvid && t.status !== 'failed').map((t: DownloadTask): number => t.cid);
  }

  private actionSelected(kind: number): boolean {
    return kind === 0 ? this.cachedCids.indexOf(this.currentCid()) >= 0 : (kind === 1 ? this.favoured : this.laterAdded);
  }

  private actionLabel(kind: number): string {
    if (kind === 0) { return this.cacheSubmitting ? '加入中' : (this.actionSelected(0) ? '已缓存' : '缓存'); }
    if (kind === 1) { return this.favoured ? '已收藏' : '收藏'; }
    return this.laterAdded ? '已稍后' : '稍后看';
  }

  private actionIcon(kind: number): Resource {
    if (kind === 0) { return $r('app.media.icon_download'); }
    if (kind === 1) { return this.favoured ? $r('app.media.icon_star') : $r('app.media.icon_star_outline'); }
    return this.laterAdded ? $r('app.media.icon_clock_filled') : $r('app.media.icon_clock');
  }

  @Builder
  DetailAction(kind: number) {
    Column({ space: 2 }) {
      Stack() {
        Image(this.actionIcon(kind)).width(18).height(18)
          .fillColor(this.actionSelected(kind) ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
      }.width(28).height(28)
      Text(this.actionLabel(kind)).fontSize(11)
        .fontColor(this.actionSelected(kind) ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
    }
    .layoutWeight(1).height(52).justifyContent(FlexAlign.Center).borderRadius(6)
    .accessibilityText(this.actionLabel(kind)).onClick((): void => {
      if (kind === 0) { this.onCache(); }
      else if (kind === 1) { this.onFav(); }
      else { this.onLater(); }
    })
  }

  /** spec-07：拉收藏状态（已收藏则默认勾选其所在夹） */
  private async loadFavState(): Promise<void> {
    if (!this.loggedIn || this.aid === 0) {
      return;
    }
    try {
      const u = await AuthService.fetchNav();
      if (u === null) {
        return;
      }
      const folders: FavFolder[] = await FavService.folders(u.mid, this.aid);
      if (this.destroyed) { return; }
      this.folders = folders;
      this.favFoldersReady = folders.every((f: FavFolder): boolean => f.stateKnown === true);
      this.folderOriginal = folders.map((f: FavFolder): boolean => f.favState === true);
      this.favoured = this.folderOriginal.some((v: boolean): boolean => v);
      // 稍后再看状态（列表量小，直接查）
      const later = await FavService.laterList();
      if (this.destroyed) { return; }
      this.laterAdded = false;
      for (let i = 0; i < later.length; i++) {
        if (later[i].bvid === this.bvid) {
          this.laterAdded = true;
          break;
        }
      }
    } catch (e) {
      // 静默
    }
  }

  private async submitFav(): Promise<void> {
    if (this.favSubmitting || !this.favFoldersReady) { return; }
    const addIds: number[] = [];
    const delIds: number[] = [];
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folderChecked[i] === true && this.folderOriginal[i] !== true) {
        addIds.push(this.folders[i].id);
      } else if (this.folderChecked[i] !== true && this.folderOriginal[i] === true) {
        delIds.push(this.folders[i].id);
      }
    }
    if (addIds.length === 0 && delIds.length === 0) {
      this.favSheetShown = false;
      return;
    }
    this.favSubmitting = true;
    try {
      await FavService.deal(this.aid, addIds, delIds);
      this.folderOriginal = this.folderChecked.slice();
      const willFav: boolean = this.folderOriginal.some((v: boolean): boolean => v);
      this.favoured = willFav;
      promptAction.showToast({ message: willFav ? '收藏成功' : '已取消收藏' });
      this.favSheetShown = false;
    } catch (e) {
      promptAction.showToast({ message: '操作失败：' + (e as Error).message });
    } finally {
      this.favSubmitting = false;
    }
  }

  // ===== 详情头（含 R8 UP 主区） =====
  @Builder
  Header(d: VideoDetail) {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text(this.bvid)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
        Blank()
      }
      .width('100%')

      Text(d.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Text(formatPlayCount(d.viewCount) + '播放 · ' + formatPlayCount(d.danmakuCount) + '弹幕 · ' + fmtDate(d.pubdate))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Column({ space: 2 }) {
        Text(d.desc.length > 0 ? d.desc : '（无简介）')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(this.descExpanded ? 200 : 3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (d.desc.length > 40) {
          Text(this.descExpanded ? '收起' : '展开更多')
            .fontSize(12)
            .fontColor($r('app.color.brand_pink'))
            .onClick(() => {
              this.descExpanded = !this.descExpanded;
            })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (d.pages.length > 1) {
        Column({ space: 6 }) {
          Text('选集（' + d.pages.length.toString() + ' P）')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Scroll() {
            Row({ space: 8 }) {
              ForEach(d.pages, (p: VideoPageInfo, i: number) => {
                Text('P' + p.page.toString() + ' ' + p.part)
                  .fontSize(12)
                  .fontColor(i === this.currentPageIdx ? Color.White : $r('app.color.text_primary'))
                  .backgroundColor(i === this.currentPageIdx ? $r('app.color.brand_pink') : $r('app.color.bg_page'))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .maxLines(1)
                  .onClick(() => {
                    this.currentPageIdx = i;
                  })
              }, (p: VideoPageInfo, i: number) => 'pg_' + i.toString() + '_' + p.cid.toString())
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }
        .width('100%')
      }

      Row({ space: 10 }) {
        this.DetailAction(0)
        this.DetailAction(1)
        this.DetailAction(2)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 分段 tab：简介 / 评论(N)（Nara 详情页顶部 tab；弹幕功能未实现故不设「发弹幕」） */
  @Builder
  TabLabel(title: string, index: number) {
    Stack() {
      Text(title).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
      Text(title).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.brand_pink'))
        .opacity(index === 0 ? 1 - this.tabProgress : this.tabProgress)
        .onAreaChange((_old: Area, area: Area): void => {
          if (index === 0) { this.introLabelWidth = Number(area.width); }
          else { this.replyLabelWidth = Number(area.width); }
        })
    }
    .layoutWeight(1).height('100%')
    .accessibilityGroup(true)
    .accessibilityText(title)
    .accessibilitySelected(this.tab === index)
    .onClick((): void => { this.tabsCtrl.changeIndex(index); })
  }

  private indicatorWidth(): number {
    return this.introLabelWidth * (1 - this.tabProgress) + this.replyLabelWidth * this.tabProgress;
  }

  @Builder
  TabBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row() {
        this.TabLabel('简介', 0)
        this.TabLabel(this.replyTotal > 0 ? ('评论 ' + formatPlayCount(this.replyTotal)) : '评论', 1)
      }
      .width('100%').height('100%')
      Rect().height(3).width(this.indicatorWidth()).radius(1.5)
        .fill($r('app.color.brand_pink'))
        .position({ x: this.tabBarWidth * (0.25 + this.tabProgress * 0.5) - this.indicatorWidth() / 2, y: 45 })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(48)
    .onAreaChange((_old: Area, area: Area): void => { this.tabBarWidth = Number(area.width); })
    .backgroundColor($r('app.color.card_bg'))
  }

  private async toggleFollow(): Promise<void> {
    if (this.followBusy || this.upMid <= 0) {
      return;
    }
    const logged: boolean = await AuthService.isLogin();
    if (this.destroyed) {
      return;
    }
    if (!logged) {
      promptAction.showToast({ message: '请先登录' });
      return;
    }
    this.followBusy = true;
    try {
      const next: boolean = !this.followed;
      await VideoService.relationModify(this.upMid, next);
      if (!this.destroyed) {
        this.followed = next;
        promptAction.showToast({ message: next ? '已关注' : '已取消关注' });
      }
    } catch (e) {
      if (!this.destroyed) {
        promptAction.showToast({ message: '操作失败，请重试' });
      }
    }
    this.followBusy = false;
  }

  /** 相关推荐行（Nara：横图 + 标题 2 行 + UP 名 + 播放/弹幕） */
  @Builder
  RelatedRow(item: VideoItem) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
          AsyncImage({ src: item.cover, w: 320, h: 180 })
        }
        .width('100%')
        .height('100%')

        if (item.duration > 0) {
          Text(formatDuration(item.duration))
            .fontSize(10)
            .fontColor('#FFFFFF')
            .backgroundColor('#80000000')
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ right: 5, bottom: 5 })
        }
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
        Row({ space: 10 }) {
          Row({ space: 3 }) {
            Image($r('app.media.icon_play'))
              .width(13)
              .height(13)
              .fillColor($r('app.color.text_secondary'))
              .opacity(0.8)
            Text(formatPlayCount(item.playCount))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          Row({ space: 3 }) {
            Image($r('app.media.icon_danmaku'))
              .width(13)
              .height(13)
              .fillColor($r('app.color.text_secondary'))
              .opacity(0.8)
            Text(formatPlayCount(item.danmaku))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .onClick(() => {
      const params: Record<string, string> = { 'bvid': item.bvid, 'title': item.title };
      router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
    })
  }

  /** 相关推荐区块（标题 + 列表） */
  @Builder
  RelatedSection() {
    Column() {
      if (this.related.length > 0) {
        Text('相关推荐')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .padding({ left: 12, right: 12, top: 12, bottom: 4 })
        ForEach(this.related, (item: VideoItem) => {
          this.RelatedRow(item)
        }, (item: VideoItem) => item.key)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** R8：UP 主区（头像 + 名字 + 粉丝数 + 关注按钮，对齐 Nara 实拍 39） */
  @Builder
  UpArea(d: VideoDetail) {
    Row({ space: 10 }) {
      Column() {
        AsyncImage({ src: d.ownerFace, w: 112, h: 112 })
      }
      .width(38)
      .height(38)
      .borderRadius(19)
      .clip(true)
      .backgroundColor($r('app.color.btn_soft_bg'))
      .onClick(() => { openMember(d.ownerMid); })

      Column({ space: 2 }) {
        Text(d.ownerName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.upFans > 0 ? (formatPlayCount(this.upFans) + '粉丝') : '粉丝数加载中…')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => { openMember(d.ownerMid); })

      Button(this.followed ? '已关注' : '关注')
        .fontSize(13)
        .height(32)
        .padding({ left: 16, right: 16 })
        .borderRadius(16)
        .backgroundColor(this.followed ? $r('app.color.btn_soft_bg') : $r('app.color.brand_pink'))
        .fontColor(this.followed ? $r('app.color.text_secondary') : '#FFFFFF')
        .enabled(!this.followBusy)
        .onClick(() => {
          this.toggleFollow();
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
  }

  /** R5：排序头（左「热门评论」+ 右「sort 图标 + 按热度/按时间」） */
  @Builder
  SortHeader() {
    Row() {
      Text(this.sortMode === 3 ? '热门评论' : '最新评论')
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Row({ space: 4 }) {
        Image($r('app.media.icon_sort'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.text_secondary'))
        Text(this.sortMode === 3 ? '按热度' : '按时间')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .height(40).padding({ left: 12, right: 12 })
      .onClick(() => {
        this.switchSort();
      })
    }
    .width('100%')
    .height(45)
    .padding({ left: 12, right: 6, top: 2.5, bottom: 2.5 })
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  EmptyRefreshIndicator() { Row().width('100%').height(0) }

  /** Nara RefreshLayout固定body，仅指示器在评论视口内出现。 */
  @Builder
  CommentRefreshIndicator() {
    Row() {
      LoadingProgress().width(28).height(28).color($r('app.color.brand_pink'))
    }
    .width(49).height(49).justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.card_bg')).borderRadius(24.5)
    .shadow({ radius: 2, color: '#33000000', offsetY: 2 })
    .position({ x: '50%', y: 89 * Math.min(1, this.refreshPullOffset / 64) - 49 })
    .translate({ x: -24.5 })
    .scale({ x: Math.min(1, this.refreshPullOffset / 64), y: Math.min(1, this.refreshPullOffset / 64) })
    .hitTestBehavior(HitTestMode.None)
  }

  /** spec-07：收藏夹选择面板 */
  @Builder
  FavPanel() {
    Column() {
      Text('选择收藏夹' + (this.favoured ? '（已收藏，取消勾选可移出）' : ''))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 12 })

      List() {
        ForEach(this.folders, (f: FavFolder, i: number) => {
          ListItem() {
            Row() {
              Checkbox()
                .select(this.folderChecked[i] === true)
                .selectedColor($r('app.color.brand_pink'))
                .onChange((v: boolean) => {
                  const next: boolean[] = this.folderChecked.slice();
                  next[i] = v;
                  this.folderChecked = next;
                })
              Text(f.title)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Text(f.mediaCount.toString())
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
        }, (f: FavFolder) => f.id.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 50 })

      Button(this.favSubmitting ? '提交中…' : '确定')
        .fontSize(14)
        .width('92%')
        .margin({ bottom: 20 })
        .backgroundColor($r('app.color.brand_pink'))
        .enabled(!this.favSubmitting)
        .onClick(() => {
          this.submitFav();
        })
    }
    .width('100%')
    .height(360)
    .backgroundColor($r('app.color.card_bg'))
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

  private offlineIndex(): number {
    return this.offlineTasks.findIndex((t: DownloadTask): boolean => t.bvid === this.bvid && t.cid === this.localCid);
  }

  private updateLocalSource(): void {
    this.localSource = { bvid: this.bvid, cid: this.localCid, localPath: this.localPath,
      title: this.localTitle, artist: this.localArtist, cover: this.localCover, localDuration: this.localDuration,
      offlineScope: this.offlineContext.scope, offlineKey: this.offlineContext.key };
  }

  private playOffline(task: DownloadTask): void {
    if (this.exitPending || this.destroyed) { return; }
    if (!DownloadLibraryService.available(task)) { promptAction.showToast({ message: '本地文件已失效' }); return; }
    // 同一页面/Surface保留全屏和倍速，单个源快照避免不同P的字段交叉。
    this.bvid = task.bvid; this.localCid = task.cid; this.localPath = task.filePath;
    this.localCover = task.cover; this.localArtist = task.upName; this.localDuration = task.duration;
    this.localTitle = task.part ? task.title + ' · ' + task.part : task.title;
    this.nativeWidth = 0; this.nativeHeight = 0; this.updateLocalSource();
  }

  private nextOffline(delta: number): void {
    const index: number = this.offlineIndex() + delta;
    if (index >= 0 && index < this.offlineTasks.length) { this.playOffline(this.offlineTasks[index]); }
  }

  @Builder
  OfflinePanel() {
    Column({ space: 8 }) {
      Text(this.localTitle).fontSize(16).fontColor($r('app.color.text_primary'))
        .width('100%').maxLines(2).padding({ left: 12, right: 12, top: 12 })
      Row() {
        Text('上一集').id('offline_previous').fontSize(13).fontColor($r('app.color.brand_pink'))
          .opacity(this.offlineIndex() > 0 ? 1 : 0.35).enabled(this.offlineIndex() > 0)
          .padding(12).onClick(() => { this.nextOffline(-1); })
        Blank()
        Text('本地播放 · ' + (this.offlineIndex() + 1).toString() + '/' + this.offlineTasks.length.toString())
          .fontSize(12).fontColor($r('app.color.text_secondary'))
        Blank()
        Text('下一集').id('offline_next').fontSize(13).fontColor($r('app.color.brand_pink'))
          .opacity(this.offlineIndex() + 1 < this.offlineTasks.length ? 1 : 0.35)
          .enabled(this.offlineIndex() + 1 < this.offlineTasks.length)
          .padding(12).onClick(() => { this.nextOffline(1); })
      }.width('100%')
      List() {
        LazyForEach(this.offlineDs, (t: DownloadTask) => {
          ListItem() {
            Row({ space: 10 }) {
              Image($r('app.media.icon_play')).width(16).height(16)
                .fillColor(t.cid === this.localCid ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
              Text(t.part || t.title).fontSize(14).layoutWeight(1).maxLines(2)
                .fontColor(t.cid === this.localCid ? $r('app.color.brand_pink') : $r('app.color.text_primary'))
              Text(formatDuration(t.duration)).fontSize(12).fontColor($r('app.color.text_secondary'))
            }.width('100%').padding({ left: 12, right: 12, top: 14, bottom: 14 })
              .id('offline_item_' + t.cid.toString()).onClick(() => { if (t.cid !== this.localCid) { this.playOffline(t); } })
          }
        }, (t: DownloadTask): string => t.bvid + ':' + t.cid.toString())
      }.width('100%').layoutWeight(1).cachedCount(1)
        .edgeEffect(EdgeEffect.None, { alwaysEnabled: true }).nestedScroll(DETAIL_NESTED_SCROLL)
    }.width('100%').height(this.bodyHeight())
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Refresh({ refreshing: $$this.refreshing, builder: this.EmptyRefreshIndicator() }) {
        Scroll(this.headerScroller) {
          Column() {
      // 顶栏已移除（对齐 Nara：播放器自带返回/标题覆盖层，页面不再有「视频详情」标题栏）

      Column().width('100%').height(this.playerHeight() + this.statusBarH)
      if (this.loading) {
        Column() {
          LoadingProgress().width(40).height(40)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: 12 }) {
          Text(this.error)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Button('重试')
            .fontSize(13)
            .backgroundColor($r('app.color.brand_pink'))
            .onClick(() => {
              this.fetch();
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.localPath.length > 0 && !this.isFullscreen) {
        this.OfflinePanel()
      } else if (this.detail !== undefined && !this.isFullscreen) {
        Stack({ alignContent: Alignment.TopStart }) {
        Column() {
        // tab 行固定在播放器下方（Nara：body = Column[buildTabBar, Expanded(内容)]）：
        // 播放器收窄时随之上移，且不参与列表滚动
        this.TabBar()

        // Bug3：简介/评论两个 tab 左右滑动切换（Tabs 横向滑动 + 自定义 TabBar，默认 bar 隐藏）
        Tabs({ barPosition: BarPosition.Start, index: this.tab, controller: this.tabsCtrl }) {
          // tab 0：简介
          TabContent() {
            List({ scroller: this.introScroller }) {
              ListItem() {
                this.UpArea(this.detail)
              }
              .width('100%')

              ListItem() {
                this.Header(this.detail)
              }
              .width('100%')

              ListItem() {
                this.RelatedSection()
              }
              .width('100%')
            }
            .cachedCount(3)
            .width('100%')
            .height('100%')
            // 对应Nara AlwaysScrollableScrollPhysics，短内容也向头部传递剩余距离。
            .edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
            .friction(DETAIL_SCROLL_FRICTION)
            .nestedScroll(DETAIL_NESTED_SCROLL)
          }

          // tab 1：评论
          TabContent() {
            Stack({ alignContent: Alignment.TopStart }) {
              List({ scroller: this.replyScroller }) {
                ListItem() { Column().width('100%').height(45) }
                .width('100%')

                // R7：置顶评论
                ForEach(this.topItems, (t: CommentItem) => {
                  ListItem() {
                    Column() {
                      CommentItemView({
                        item: t,
                        upMid: this.upMid,
                        onOpenSub: (it: CommentItem) => {
                          this.toggleSub(it);
                        },
                        onSubMore: (it: CommentItem) => {
                          this.loadSubMore(it);
                        }
                      })
                    }
                    .width('100%')
                    .backgroundColor($r('app.color.comment_top_bg'))
                  }
                  .width('100%')
                }, (t: CommentItem) => 'top_' + t.rpid.toString() + '_'
                  + t.subPage.toString() + (t.expanded ? 'e' : 'c'))

                // R6：首屏骨架屏 ×5 / 评论列表
                if (this.firstLoading) {
                  ForEach([0, 1, 2, 3, 4], (i: number) => {
                    ListItem() {
                      CommentSkeleton({ variant: i })
                    }
                    .width('100%')
                  }, (i: number) => 'sk_' + i.toString())
                } else {
                  LazyForEach(this.ds, (item: CommentItem) => {
                    ListItem() {
                      CommentItemView({
                        item: item,
                        upMid: this.upMid,
                        onOpenSub: (it: CommentItem) => {
                          this.toggleSub(it);
                        },
                        onSubMore: (it: CommentItem) => {
                          this.loadSubMore(it);
                        }
                      })
                    }
                    .width('100%')
                    // key 携带展开态/分页号：状态变化时强制重建该条目，确保内联展开必然刷新
                  }, (item: CommentItem) => item.rpid.toString() + '_'
                    + item.subPage.toString() + (item.expanded ? 'e' : 'c'))
                }

                // 页脚（高 125，含底部安全区）
                ListItem() {
                  Column() {
                    if (this.replyErr.length > 0) {
                      Text(this.replyErr)
                        .fontSize(12)
                        .fontColor($r('app.color.brand_pink'))
                        .onClick(() => {
                          this.loadComments(false);
                        })
                    } else if (this.replyEnd && this.ds.size() === 0 && this.topItems.length === 0) {
                      Text('还没有评论，快来抢沙发吧')
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                    } else if (this.replyEnd) {
                      Text('没有更多评论了')
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                    } else {
                      Text('加载中…')
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                    }
                  }
                  .width('100%')
                  .height(125)
                  .justifyContent(FlexAlign.Center)
                  .padding({ bottom: this.navBarH })
                }
                .width('100%')
              }
              .cachedCount(3)
              .width('100%')
              .height('100%')
              .divider({ strokeWidth: 0.3, color: '#14000000', startMargin: 55, endMargin: 15 })
              .onReachEnd(() => {
                this.loadComments(false);
              })
              .edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
              .friction(DETAIL_SCROLL_FRICTION)
              .nestedScroll(DETAIL_NESTED_SCROLL)
              .onDidScroll(() => { this.syncReplyHeader(); })
              Column() { this.SortHeader() }
                .width('100%').height(45)
                .position({ x: 0, y: -this.replyHeaderOffset })
              if (this.refreshPullOffset > 0) { this.CommentRefreshIndicator() }
            }
            .width('100%').height('100%').clip(true)
          }
        }
        .barHeight(0)
        .scrollable(true)
        .layoutWeight(1)
        .width('100%')
        .animationDuration(300)
        .onContentDidScroll((_selected: number, index: number, position: number): void => {
          this.tabProgress = Math.max(0, Math.min(1, index - position));
        })
        .onAnimationEnd((index: number): void => { this.tabProgress = index; })
        .onChange((index: number) => {
          this.tab = index;
        })
        .bindSheet($$this.favSheetShown, this.FavPanel(), {
          height: 360,
          dragBar: true,
          showClose: true,
          backgroundColor: $r('app.color.card_bg')
        })
        }
        .width('100%').height(this.visibleBodyHeight())
        if (this.subShown && this.subRoot !== undefined) {
          SubReplyPanel({ embedded: true, root: this.subRoot, upMid: this.upMid, aid: this.aid,
            onClose: () => { this.closeSub(); } })
            .width('100%').height(this.visibleBodyHeight())
            .transition(TransitionEffect.move(TransitionEdge.BOTTOM))
        }
        }
        .width('100%').height(this.bodyHeight()).clip(true)
      }
          }.width('100%')
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
        .friction(DETAIL_SCROLL_FRICTION)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .onDidScroll(() => { this.syncHeaderScroll(); })
        // 保留原生嵌套链处理归顶/惯性；仅抵消Refresh实际位移，不改Scroll偏移或播放器比例。
        .translate({ y: -this.refreshPullOffset })
      }
      .width('100%').height('100%')
      .visibility(this.isFullscreen ? Visibility.None : Visibility.Visible)
      .pullToRefresh(this.tab === 1 && this.scrollAcc < 0.5)
      .refreshOffset(64)
      .onOffsetChange((offset: number): void => { this.refreshPullOffset = Math.max(0, offset); })
      .onRefreshing(() => { this.refreshing = true; this.loadComments(true); })
      // 内嵌播放器（spec-06a；单一实例，全屏只改尺寸，避免 Surface 重建）
      // 离线播放（localPath 非空）时即使详情未加载完成也先渲染播放器
      if (this.detail !== undefined || this.localPath.length > 0) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            Column().width('100%').height(this.isFullscreen ? 0 : this.statusBarH)
            PlayerView({
              sourceWidth: this.sourceDimension(true),
              sourceHeight: this.sourceDimension(false),
              onVideoSize: (w: number, h: number): void => { this.nativeWidth = w; this.nativeHeight = h; },
              visible: this.routeVisible,
              registerRelease: (release: () => Promise<void>): void => { this.releasePlayer = release; },
              bvid: this.bvid,
              cid: this.currentCid(),
              cover: this.detail !== undefined ? this.detail.cover : this.localCover,
              title: this.detail !== undefined ? this.detail.title : this.localTitle,
              artist: this.detail !== undefined ? this.detail.ownerName : this.localArtist,
              partText: this.partLabel(),
              danmakuCount: this.detail !== undefined ? this.detail.danmakuCount : 0,
              isFullscreen: this.isFullscreen,
              autoPlay: true,
              localPath: this.localPath,
              localSource: this.localSource,
              localDuration: this.localDuration,
              offlineScope: this.offlineContext.scope,
              offlineKey: this.offlineContext.key,
              resumeTick: this.resumeTick,
              collapseRatio: this.collapseRatio,
              onGoHome: () => {
                this.goHome();
              },
              viewHeight: '100%',
              canvasWidth: this.viewportWidth > 0 ? px2vp(this.viewportWidth) : Math.min(this.screenW, this.screenH),
              canvasHeight: this.isFullscreen && this.viewportHeight > 0 ? px2vp(this.viewportHeight) :
                (this.isFullscreen ? Math.max(this.screenW, this.screenH) : this.playerHeight()),
              viewportHeight: this.playerBoxHeight() - this.statusBarH,
              onStateChange: (st: string) => {
                if (st === 'completed' && this.localPath.length > 0) { this.nextOffline(1); }
                if (st === 'playing' && this.scrollAcc > 0) {
                  this.headerExpanding = true;
                  this.headerScroller.scrollTo({ xOffset: 0, yOffset: 0,
                    animation: { duration: Math.max(1, Math.round(200 * this.scrollAcc / this.playerHeight())), curve: Curve.Linear } });
                  this.playerState = st;
                } else { this.playerState = st; }
              },
              onExit: () => {
                if (this.isFullscreen) {
                  this.toggleFullscreen();
                } else {
                  this.leaveVideo();
                }
              },
              onToggleFullscreen: () => {
                this.toggleFullscreen();
              }
            })
            .layoutWeight(1)
          }
          .width('100%')
          .height('100%')

        }
        .width('100%')
        .height(this.isFullscreen ? '100%' : this.playerBoxHeight())
        .backgroundColor('#000000')
        .clip(true)
      }

    }
     .width('100%')
     .height('100%')
     .onAreaChange((_old: Area, area: Area) => { this.pageHeight = Number(area.height); })
     .backgroundColor(this.isFullscreen ? '#000000' : $r('app.color.bg_page'))
  }
}
