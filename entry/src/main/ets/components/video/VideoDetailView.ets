/**
 * 视频详情页（spec-05 + 评论区返工 R1~R9，以 PiliNara 为交互与样式基准）
 *  信息区 / UP 主区（R8）/ 简介折叠 / 分P 选集 / 操作区
 *  评论区：排序切换（R5）+ 置顶评论（R7）+ 骨架屏（R6）+ 下拉刷新（R6）
 *          评论图片（R9）+ 子回复容器（R1/R2）+ 楼中楼面板 bindSheet（R3）+ 操作行点赞（R4）
 * 规格来源：docs/ui/评论区.html、docs/参考-NaraUI基准.md §1
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { openMember, openMention } from '../../common/member_route';
import { HeroRect } from '../../common/hero_route';
import { RichKind, RichSegment, RichText } from '../../common/rich_text';
import { router, promptAction, window, display, curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { FrameCallback } from '@ohos.arkui.UIContext';
import { BasicDataSource } from '../../common/list_data_source';
import { AsyncImage } from '../../components/AsyncImage';
import { MeasuredContent } from '../MeasuredContent';
import { CommentItemView, CommentSkeleton } from '../../components/CommentItem';
import { PlayerView } from '../../components/player/PlayerView';
import { refreshSystemBars } from '../../infra/player/system_bars';
import { PlaybackSource } from '../../infra/player/play_controller';
import { LoadingFooter } from '../../components/StateViews';
import { formatPlayCount, formatDuration } from '../../components/VideoCard';
import { VideoItem } from '../../model/video_item';
import { VideoService, VideoDetail, VideoPageInfo, VideoSeasonSection, VideoEpisode, CommentItem, SubReplyPage, VideoTag } from '../../service/video_service';
import { SubReplyPanel } from '../../components/SubReplyPanel';
import { VideoPartsStrip, VideoEpisodePanel, EpisodeSelection, makeVideoPartsSource } from '../../components/VideoEpisodePanel';
import { AuthService } from '../../service/auth_service';
import { FavService, FavFolder } from '../../service/fav_service';
import { DownloadService, DownloadTask, qualityLabel } from '../../service/download_service';
import { DownloadLibraryService } from '../../service/download_library_service';
import { OfflineContext } from '../../model/download';
import { prefsGet } from '../../infra/storage/prefs';
import { DanmakuPreferences, DanmakuSettings, copyDanmakuPreferences } from '../../infra/danmaku/settings';
import { VideoDetailHandle } from './video_detail_handle';

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

class DetailPlayerLayoutCallback extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(_time: number): void { this.action(); this.action = () => {}; }
}

class DetailContentIdleCallback extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(_timeLeft: number): void { this.action(); this.action = () => {}; }
}

interface DetailSourceGeometry {
  bvid: string;
  cid: number;
  localPath: string;
  width: number;
  height: number;
}

let nextDetailVisualId: number = 0;

@Component
export struct VideoDetailView {
  /** 宿主注入，不能加 @Prop（否则句柄会被深拷贝） */
  handle: VideoDetailHandle = new VideoDetailHandle();
  @Prop inputBvid: string = '';
  @Prop inputTitle: string = '';
  @Prop inputCover: string = '';
  @Prop inputNavigation: boolean = false;
  @Prop inputRouteSession: number = 0;
  onDisposed: (session: number) => void = () => {};
  private disposedSession: number = 0;
  @Prop inputExitCover: boolean = false;
  @Prop inputHeroMoving: boolean = false;
  @Prop inputCid: number = 0;
  @Prop inputLocalPath: string = '';
  @Prop inputLocalAudioPath: string = '';
  @Prop inputLocalCover: string = '';
  @Prop inputLocalArtist: string = '';
  @Prop inputLocalDuration: number = 0;
  @Prop inputOfflineScope: string = 'all';
  @Prop inputOfflineKey: string = '';
  /** 宿主是否已被其它页面/NavDestination 覆盖（替代 router.getState().index 判定） */
  private covered: boolean = false;

  @State bvid: string = '';
  @State detail: VideoDetail | undefined = undefined;
  @State loading: boolean = true;
  @State error: string = '';
  @State descExpanded: boolean = false;
  /** 简介展开态实测高度（Nara ExpandablePanel 的 AnimatedMultiHeight 等价物） */
  @State descH: number = 0;
  /** 简介里的链接/@只解析一次，展开/收起不重复切分。 */
  private descRichKey: string = '';
  private descRichCache: RichSegment[] = [];
  @State currentPageIdx: number = 0;
  private initialCid: number = 0;
  @State onlineSource: PlaybackSource | undefined = undefined;
  @State partsSource: string = '';
  @State partsCount: number = 0;
  @State episodeShown: boolean = false;
  @State episodeSeason: boolean = false;
  @State episodeSwitching: boolean = false;
  private detailGeneration: number = 0;
  private detailContentGeneration: number = 0;
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
  @State upVideos: number = 0;
  @State upLevel: number = 0;
  /** 标签行：接口失败保持空，不显示占位空行。 */
  @State videoTags: VideoTag[] = [];

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
  private commentsForeground: boolean = true;
  private releasePlayer: () => Promise<void> = (): Promise<void> => Promise.resolve();
  private exitPending: boolean = false;
  private fetchGeneration: number = 0;
  private commentGeneration: number = 0;
  private orientationGeneration: number = 0;
  @State localCid: number = 0;
  private routeIndex: number = 0;
  private hideTimer: number = -1;
  @State nativeWidth: number = 0;
  @State nativeHeight: number = 0;
  /** 与轻量播放输入同批提交，不等待详情正文；尺寸不能跨BV/分P/本地文件复用。 */
  @State sourceGeometry: DetailSourceGeometry = { bvid: '', cid: 0, localPath: '', width: 0, height: 0 };
  private playerVisualId: string = 'video_detail_visual_' + (++nextDetailVisualId).toString();
  private visualGeneration: number = 0;
  private visualOutputReady: boolean = false;
  private visualReadyPending: boolean = false;
  private visualReadyNotified: boolean = false;
  private visualUnavailableNotified: boolean = false;
  private lastReportedVisualRect: HeroRect = new HeroRect();
  private windowSizeHandler: (size: window.Size) => void = (size: window.Size): void => {
    if (!this.destroyed) { this.onWindowSize(size); }
  };
  /** 离线播放：本地文件路径（非空 = 播放已下载文件，播放器同在线一套 UI） */
  @State localPath: string = '';
  /** DASH 双文件：独立音轨路径（空=旧版单文件 MP4）。 */
  @State localAudioPath: string = '';
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
  @State controlInsetTop: number = 0;
  @State controlInsetLeft: number = 0;
  @State controlInsetRight: number = 0;
  private avoidAreaHandler: (options: window.AvoidAreaOptions) => void = (options: window.AvoidAreaOptions): void => {
    if (!this.destroyed && (options.type === window.AvoidAreaType.TYPE_SYSTEM ||
      options.type === window.AvoidAreaType.TYPE_CUTOUT)) { this.updateControlInsets(); }
  };
  /** 当前窗口是否横屏（进全屏过渡期：竖屏下播放器保持 16:9 不拉伸） */
  @State isLandscape: boolean = false;
  /** 楼中楼面板 */
  private ds: BasicDataSource<CommentItem> = new BasicDataSource<CommentItem>(true);
  private commentIds: Set<number> = new Set<number>();
  private replyRetryReset: boolean = true;
  /** 0=简介 1=评论（对齐 Nara 详情页分段 tab） */
  @State tab: number = 0;
  /** 原生Tabs逐帧位移同时驱动标题和单一下划线，覆盖拖动/回弹/点击动画。 */
  @State tabProgress: number = 0;
  @State tabBarWidth: number = 192;
  @State introLabelWidth: number = 26;
  @State replyLabelWidth: number = 26;
  private tabsCtrl: TabsController = new TabsController();
  @State relatedCount: number = 0;
  private relatedDs: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  private routeSettled: boolean = false;
  @State playbackMountReady: boolean = false;
  private playerLayoutReady: boolean = false;
  private initialBodyReady: boolean = false;
  private tabMoving: boolean = false;
  private tabAnimating: boolean = false;
  private contentWaiters: (() => void)[] = [];
  private contentFramePending: boolean = false;
  private tabsGeneration: number = 0;
  private tabsMounted: boolean = false;
  private settleTimer: number = -1;
  @State followed: boolean = false;
  @State followBusy: boolean = false;
  /** 收窄交互：播放状态 / 累计滚动 / 收窄比例(0~1) / 继续播放命令计数 */
  @State playerState: string = 'idle';
  @State danmakuPreferences: DanmakuPreferences = new DanmakuPreferences();
  @State danmakuReady: boolean = false;
  private danmakuRevision: number = 0;
  @State collapseRatio: number = 0;
  @State resumeTick: number = 0;
  @State subShown: boolean = false;
  @State subRoot: CommentItem | undefined = undefined;
  @State subTargetRpid: number = 0;
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
  private handleBinding: number = 0;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;

  aboutToAppear(): void {
    this.disposedSession = this.inputRouteSession;
    this.handleBinding = ++this.handle.bindingGeneration;
    this.handle.show = (): void => { this.onHostShow(); };
    this.handle.hide = (covered: boolean = false): void => { this.onHostHide(covered); };
    this.routeIndex = router.getState().index;
    this.handle.back = (): boolean => this.onHostBack();
    this.handle.routeEntry = (p: number): void => { this.onRouteEntryProgress(p); };
    this.handle.visualRect = (): HeroRect => this.playerVisualRect();
    DanmakuSettings.load().then((value: DanmakuPreferences): void => {
      if (!this.destroyed && this.danmakuRevision === 0) { this.danmakuPreferences = value; this.danmakuReady = true; }
    }).catch((): void => {
      if (!this.destroyed) { this.danmakuReady = true; promptAction.showToast({ message: '弹幕偏好读取失败，使用默认设置' }); }
    });
    this.settleTimer = setTimeout((): void => {
      this.finishRouteEntry();
    }, this.inputNavigation ? 1800 : NARA_ROUTE_DURATION + 32);
    DownloadService.init(getContext(this) as common.Context);
    DownloadService.onChange(this.downloadChange);
    DownloadService.load().then((): void => { this.refreshCacheState(); }).catch((): void => {
      // 下载资料损坏只影响缓存管理，不能阻断在线播放；缓存入口会报告原错误。
      if (!this.destroyed && !this.exitPending) { this.cachedCids = []; }
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
      win.on('avoidAreaChange', this.avoidAreaHandler);
      const rect: window.Rect = win.getWindowProperties().windowRect;
      this.onWindowSize({ width: rect.width, height: rect.height });
    }).catch(() => {
      // 忽略
    });
    if (this.inputBvid.length > 0) { this.bvid = this.inputBvid; }
    if (this.inputTitle.length > 0) { this.localTitle = this.inputTitle; }
    if (this.inputCid > 0) { this.initialCid = this.inputCid; }
    if (this.inputLocalPath.length > 0) {
      this.localPath = this.inputLocalPath;
      this.localAudioPath = this.inputLocalAudioPath;
      this.localCid = this.inputCid;
      this.localCover = this.inputLocalCover;
      this.localArtist = this.inputLocalArtist;
      this.localDuration = this.inputLocalDuration;
      this.offlineContext = { scope: this.inputOfflineScope, key: this.inputOfflineKey };
    }
    if (this.localPath) { this.updateLocalSource(); }
    this.reportVisualRect(true);
    this.fetch();
  }

  aboutToDisappear(): void {
    this.onDisposed(this.disposedSession);
    if (this.handleBinding === this.handle.bindingGeneration) {
      this.handle.show = (): void => {};
      this.handle.hide = (): void => {};
      this.handle.back = (): boolean => false;
      this.handle.routeEntry = (): void => {};
      this.handle.visualRect = (): HeroRect => new HeroRect();
    }
    AppStorage.setOrCreate<boolean>('playerFullscreen', false);
    DownloadService.offChange(this.downloadChange);
    if (this.hideTimer !== -1) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
    this.destroyed = true;
    if (this.settleTimer !== -1) { clearTimeout(this.settleTimer); this.settleTimer = -1; }
    this.flushContentWaiters();
    refreshSystemBars(getContext(this) as common.UIAbilityContext);
    this.commentGeneration++;
    this.detailGeneration++;
    this.orientationGeneration++;
    if (this.fsFallbackTimer !== -1) {
      clearTimeout(this.fsFallbackTimer);
      this.fsFallbackTimer = -1;
    }
    if (this.mainWin !== undefined) {
      this.mainWin.off('windowSizeChange', this.windowSizeHandler);
      this.mainWin.off('avoidAreaChange', this.avoidAreaHandler);
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

  onHostHide(covered: boolean = false): void {
    this.commentsForeground = false;
    this.covered = covered;
    if (this.inputNavigation) { AppStorage.setOrCreate<boolean>('navVideoDetailVisible', false); }
    if (this.hideTimer !== -1) { clearTimeout(this.hideTimer); }
    // 页面在应用退后台时也收到 hide；仅路由栈顶改变才暂停。
    this.hideTimer = setTimeout((): void => {
      this.hideTimer = -1;
      if (!this.destroyed && (this.covered || router.getState().index !== this.routeIndex)) { this.routeVisible = false; }
      refreshSystemBars(getContext(this) as common.UIAbilityContext);
    }, 20);
  }
  onHostShow(): void {
    if (this.destroyed || this.exitPending) { return; }
    this.commentsForeground = true;
    if (this.hideTimer !== -1) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
    this.covered = false;
    this.routeIndex = router.getState().index;
    this.routeVisible = true;
    if (this.inputNavigation) { AppStorage.setOrCreate<boolean>('navVideoDetailVisible', true); }
    if (this.upMid > 0) {
      const ownerMid: number = this.upMid;
      VideoService.relationState(ownerMid).then((followed: boolean) => {
        if (!this.destroyed && !this.exitPending && this.upMid === ownerMid) { this.followed = followed; }
      });
    }
    this.syncFullscreenBars();
    this.reportVisualRect();
    this.tryNotifyVisualReady();
  }

  /** 当前分P 的 cid */
  private syncFullscreenBars(): void {
    AppStorage.setOrCreate<boolean>('playerFullscreen', (this.fullscreenTarget ?? this.isFullscreen) && !this.destroyed);
    this.updateControlInsets();
    refreshSystemBars(getContext(this) as common.UIAbilityContext);
    this.reportVisualRect(true);
  }

  /** 仅控制区避让，视频Surface仍铺满；竖全屏保留系统栏隐藏前的顶部安全区。 */
  private updateControlInsets(): void {
    const win: window.Window | undefined = this.mainWin;
    if (!win || this.destroyed) { return; }
    try {
      const system: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      this.controlInsetTop = Math.max(px2vp(system.topRect.height), px2vp(cutout.topRect.height),
        this.isLandscape ? 0 : this.statusBarH);
      this.controlInsetLeft = px2vp(Math.max(system.leftRect.width, cutout.leftRect.width));
      this.controlInsetRight = px2vp(Math.max(system.rightRect.width, cutout.rightRect.width));
    } catch (_) { this.controlInsetTop = this.isLandscape ? 0 : this.statusBarH; }
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

  /** BV/cid/元数据为单次播放器输入，避免跨合集切换字段Watch交叉。 */
  private syncOnlineSource(): void {
    const d: VideoDetail | undefined = this.detail;
    if (!d || this.localPath.length > 0 || d.pages.length === 0) { return; }
    this.prepareOnlineSource(d, this.currentPageIdx);
  }

  /** 轻量播放输入先就绪；正文稍后提交时复用同一源，避免Watch再次取流。 */
  private prepareOnlineSource(d: VideoDetail, index: number): void {
    const p: VideoPageInfo | undefined = d.pages[Math.min(index, d.pages.length - 1)];
    if (!p || p.cid <= 0) { return; }
    this.prepareSourceGeometry(d.bvid, p.cid, '', p.width, p.height);
    if (this.onlineSource?.bvid === d.bvid && this.onlineSource.cid === p.cid) {
      this.reportVisualRect(true); return;
    }
    this.onlineSource = { bvid: d.bvid, cid: p.cid, localPath: '',
      title: d.pages.length > 1 ? 'P' + p.page.toString() + ' ' + p.part : d.title,
      artist: d.ownerName, cover: d.cover, localDuration: 0, offlineScope: '', offlineKey: '' };
    this.reportVisualRect(true);
  }

  private currentSeasonSection(): number {
    return Math.max(0, this.detail?.season?.sections.findIndex((section: VideoSeasonSection): boolean =>
      section.episodes.some((episode: VideoEpisode): boolean => episode.bvid === this.bvid)) ?? 0);
  }

  private seasonProgress(): string {
    const section = this.detail?.season?.sections[this.currentSeasonSection()];
    if (!section) { return ''; }
    const index: number = section.episodes.findIndex((episode: VideoEpisode): boolean => episode.bvid === this.bvid);
    return (index >= 0 ? index + 1 : 1).toString() + '/' + section.episodes.length.toString();
  }

  private openEpisodes(season: boolean): void {
    if (this.episodeSwitching) { return; }
    this.episodeSeason = season; this.episodeShown = true;
  }

  private async selectEpisode(selection: EpisodeSelection): Promise<void> {
    if (this.destroyed || this.exitPending || this.localPath.length > 0) { return; }
    if (this.cacheSubmitting || this.favSubmitting || this.laterSubmitting || this.followBusy) {
      promptAction.showToast({ message: '请等待当前操作完成' }); return;
    }
    if (selection.bvid === this.bvid) {
      const index: number = this.detail?.pages.findIndex((p: VideoPageInfo): boolean => p.cid === selection.cid) ?? -1;
      if (index < 0) { promptAction.showToast({ message: '该分集暂不可用' }); return; }
      this.detailGeneration++; this.episodeSwitching = false; this.episodeShown = false;
      if (index !== this.currentPageIdx) { this.currentPageIdx = index; this.syncOnlineSource(); }
      return;
    }
    const generation: number = ++this.detailGeneration;
    this.episodeSwitching = true;
    try {
      const detail: VideoDetail = await VideoService.viewDetail(selection.bvid);
      if (this.destroyed || this.exitPending || generation !== this.detailGeneration) { return; }
      if (this.cacheSubmitting || this.favSubmitting || this.laterSubmitting || this.followBusy) {
        promptAction.showToast({ message: '请等待当前操作完成后重新选集' }); return;
      }
      const index: number = detail.pages.findIndex((p: VideoPageInfo): boolean => p.cid === selection.cid);
      if (index < 0) { throw new Error('该分集暂不可用'); }
      this.episodeShown = false;
      this.applyOnlineDetail(detail, index);
      this.loadOnlineExtras(detail);
    } catch (_) {
      if (!this.destroyed && !this.exitPending && generation === this.detailGeneration) {
        promptAction.showToast({ message: '切换失败，请重试' });
      }
    } finally { if (!this.destroyed && !this.exitPending && generation === this.detailGeneration) { this.episodeSwitching = false; } }
  }

  private applyOnlineDetail(detail: VideoDetail, index: number): void {
    if (this.destroyed || this.exitPending) { return; }
    const changed: boolean = this.bvid !== detail.bvid || this.aid !== detail.aid;
    this.detailContentGeneration++;
    this.bvid = detail.bvid; this.currentPageIdx = index; this.detail = detail;
    this.partsSource = makeVideoPartsSource(detail.bvid, detail.pages); this.partsCount = detail.pages.length;
    this.aid = detail.aid; this.upMid = detail.ownerMid; this.replyTotal = detail.replyCount;
    this.syncOnlineSource(); this.refreshCacheState();
    if (changed) {
      this.commentGeneration++; this.loadingMoreReply = false; this.ds.reload([]); this.topItems = [];
      this.nextOffset = ''; this.replyEnd = false; this.replyErr = ''; this.replyHeaderOffset = 0;
      this.lastReplyOffset = 0; this.effectiveReplyOffset = 0;
      this.relatedDs.reload([]); this.relatedCount = 0; this.upFans = 0; this.upVideos = 0; this.upLevel = 0; this.videoTags = []; this.followed = false;
      this.favoured = false; this.laterAdded = false; this.favFoldersReady = false;
      this.folders = []; this.folderOriginal = []; this.folderChecked = [];
      this.descExpanded = false; this.descH = 0; this.subShown = false; this.subRoot = undefined;
      try { this.replyScroller.scrollEdge(Edge.Top); this.introScroller.scrollEdge(Edge.Top); } catch (_) {}
    }
    this.loadComments(true);
  }

  private loadOnlineExtras(detail: VideoDetail): void {
    if (this.destroyed || this.exitPending) { return; }
    const generation: number = this.detailContentGeneration;
    VideoService.upCard(detail.ownerMid).then((card): void => {
      if (!this.destroyed && !this.exitPending && generation === this.detailContentGeneration) {
        this.upFans = card.fans; this.upVideos = card.videos; this.upLevel = card.level;
      }
    }).catch(() => {});
    VideoService.tags(detail.bvid, this.currentCid()).then((list: VideoTag[]): void => {
      if (!this.destroyed && !this.exitPending && generation === this.detailContentGeneration) { this.videoTags = list; }
    }).catch(() => {});
    this.loadFavState();
    VideoService.related(detail.bvid).then(async (list: VideoItem[]): Promise<void> => {
      await this.waitForContentIdle();
      if (!this.destroyed && !this.exitPending && generation === this.detailContentGeneration) {
        this.relatedDs.reload(list); this.relatedCount = list.length;
      }
    }).catch(() => {});
    VideoService.relationState(detail.ownerMid).then((value: boolean): void => {
      if (!this.destroyed && !this.exitPending && generation === this.detailContentGeneration) { this.followed = value; }
    }).catch(() => {});
  }

  private prepareSourceGeometry(bvid: string, cid: number, localPath: string, width: number, height: number): void {
    const previous: DetailSourceGeometry = this.sourceGeometry;
    const changed: boolean = previous.bvid !== bvid || previous.cid !== cid || previous.localPath !== localPath;
    const valid: boolean = Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0;
    if (changed) {
      this.nativeWidth = 0; this.nativeHeight = 0;
      this.visualGeneration++; this.visualOutputReady = false;
      this.visualReadyPending = false; this.visualReadyNotified = false;
      this.visualUnavailableNotified = false;
    }
    if (!changed && (!valid || (previous.width === width && previous.height === height))) { return; }
    this.sourceGeometry = { bvid, cid, localPath, width: valid ? width : 0, height: valid ? height : 0 };
  }

  private geometryMatches(source: PlaybackSource | undefined): boolean {
    const geometry: DetailSourceGeometry = this.sourceGeometry;
    return source !== undefined && source.bvid === geometry.bvid && source.cid === geometry.cid &&
      source.localPath === geometry.localPath;
  }

  private sourceDimension(width: boolean): number {
    const source: PlaybackSource | undefined = this.localPath.length > 0 ? this.localSource : this.onlineSource;
    if (!this.geometryMatches(source)) { return 0; }
    return width ? this.sourceGeometry.width : this.sourceGeometry.height;
  }

  /** 旧源已排队的尺寸回调不能写进切换后的源；同源正文补交不影响有效原生尺寸。 */
  private videoSizeHandler(): (width: number, height: number) => void {
    const source: PlaybackSource | undefined = this.localPath.length > 0 ? this.localSource : this.onlineSource;
    const generation: number = this.visualGeneration;
    return (width: number, height: number): void => {
      if (this.destroyed || this.exitPending || generation !== this.visualGeneration || !this.geometryMatches(source) ||
        !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) { return; }
      this.nativeWidth = width; this.nativeHeight = height;
      this.reportVisualRect(true);
      this.tryNotifyVisualReady();
    };
  }

  private videoOutputReadyHandler(): () => void {
    const source: PlaybackSource | undefined = this.localPath.length > 0 ? this.localSource : this.onlineSource;
    const generation: number = this.visualGeneration;
    return (): void => {
      if (this.destroyed || this.exitPending || generation !== this.visualGeneration || !this.geometryMatches(source)) { return; }
      this.visualOutputReady = true;
      this.tryNotifyVisualReady();
    };
  }

  private playerStateHandler(): (state: string) => void {
    const generation: number = this.visualGeneration;
    const source: PlaybackSource | undefined = this.localPath.length > 0 ? this.localSource : this.onlineSource;
    return (state: string): void => {
      if (this.destroyed || this.exitPending || generation !== this.visualGeneration || !this.geometryMatches(source)) { return; }
      if (state === 'completed' && this.localPath.length > 0) { this.nextOffline(1); }
      if ((state === 'playing' || state === 'loading') && this.scrollAcc > 0 && !this.headerExpanding) {
        this.headerExpanding = true;
        this.headerScroller.scrollTo({ xOffset: 0, yOffset: 0,
          animation: { duration: Math.max(1, Math.round(200 * this.scrollAcc / this.playerHeight())), curve: Curve.Linear } });
      }
      this.playerState = state;
      if (state === 'error') { this.notifyVisualUnavailable(); }
      this.tryNotifyVisualReady();
    };
  }

  private visualReadyConditions(): boolean {
    return !this.destroyed && !this.exitPending && this.routeVisible &&
      this.handleBinding === this.handle.bindingGeneration && this.visualOutputReady &&
      this.nativeWidth > 0 && this.nativeHeight > 0 &&
      (this.playerState === 'playing' || this.playerState === 'paused' || this.playerState === 'completed');
  }

  private tryNotifyVisualReady(): void {
    if (this.visualReadyPending || this.visualReadyNotified || !this.visualReadyConditions()) { return; }
    const generation: number = this.visualGeneration;
    this.visualReadyPending = true;
    try {
      this.getUIContext().postFrameCallback(new DetailContentIdleCallback((): void => {
        if (generation !== this.visualGeneration) { return; }
        this.visualReadyPending = false;
        if (this.visualReadyNotified || !this.visualReadyConditions()) { return; }
        this.visualReadyNotified = true;
        this.handle.onVisualReady();
      }));
    } catch (_) { this.visualReadyPending = false; }
  }

  private notifyVisualUnavailable(): void {
    if (this.destroyed || this.exitPending || this.handleBinding !== this.handle.bindingGeneration ||
      this.visualReadyNotified || this.visualUnavailableNotified) { return; }
    this.visualUnavailableNotified = true;
    this.handle.onVisualUnavailable();
  }

  private windowVisualRect(rect: HeroRect): HeroRect {
    const windowW: number = this.viewportWidth > 0 ? px2vp(this.viewportWidth) : Math.min(this.screenW, this.screenH);
    const windowH: number = this.viewportHeight > 0 ? px2vp(this.viewportHeight) : Math.max(this.screenW, this.screenH);
    const left: number = Math.max(0, Math.min(windowW, rect.x));
    const top: number = Math.max(0, Math.min(windowH, rect.y));
    const right: number = Math.max(left, Math.min(windowW, rect.x + rect.w));
    const bottom: number = Math.max(top, Math.min(windowH, rect.y + rect.h));
    return new HeroRect(left, top, right - left, bottom - top);
  }

  private playerVisualRect(): HeroRect {
    if (this.playbackMountReady && !this.destroyed) {
      try {
        const info = this.getUIContext().getComponentUtils().getRectangleById(this.playerVisualId);
        const rect: HeroRect = new HeroRect(px2vp(info.windowOffset.x), px2vp(info.windowOffset.y),
          px2vp(info.size.width), px2vp(info.size.height));
        if (rect.w > 0 && rect.h > 0) { return this.windowVisualRect(rect); }
      } catch (_) { /* 未挂载/未布局时使用与生产播放器相同的预估尺寸。 */ }
    }
    return this.estimatedVisualRect();
  }

  private estimatedVisualRect(): HeroRect {
    const windowW: number = this.viewportWidth > 0 ? px2vp(this.viewportWidth) : Math.min(this.screenW, this.screenH);
    const windowH: number = this.viewportHeight > 0 ? px2vp(this.viewportHeight) : Math.max(this.screenW, this.screenH);
    return this.windowVisualRect(new HeroRect(0, this.isFullscreen ? 0 : this.statusBarH, windowW,
      this.isFullscreen ? windowH : Math.max(0, this.playerBoxHeight() - this.statusBarH)));
  }

  private reportVisualRect(estimated: boolean = false): void {
    if (this.destroyed || this.exitPending || this.handleBinding !== this.handle.bindingGeneration) { return; }
    const rect: HeroRect = estimated ? this.estimatedVisualRect() : this.playerVisualRect();
    const previous: HeroRect = this.lastReportedVisualRect;
    if (Math.abs(rect.x - previous.x) < 0.1 && Math.abs(rect.y - previous.y) < 0.1 &&
      Math.abs(rect.w - previous.w) < 0.1 && Math.abs(rect.h - previous.h) < 0.1) { return; }
    this.lastReportedVisualRect = rect;
    this.handle.onVisualRect(rect);
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
    // 横屏窗口（小窗/分屏）里播放器占满窗口，不要再按窄边算 16:9
    if (this.isLandscape && !this.isFullscreen && this.viewportHeight > 0) { return px2vp(this.viewportHeight); }
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
    this.beginExit();
    try {
      const prepareStarted: number = Date.now();
      await this.handle.prepareExit();
      console.info('[VideoExit] prepareMs=' + (Date.now() - prepareStarted).toString());
      const releaseStarted: number = Date.now();
      await this.releasePlayer();
      console.info('[VideoExit] releaseMs=' + (Date.now() - releaseStarted).toString());
      if (this.destroyed) { return; }
      this.handle.exit(toHome);
    } catch (_) {
      this.restoreAfterExitFailure();
      if (!this.destroyed) { promptAction.showToast({ message: '退出播放失败，请重试' }); }
    }
  }

  /** 只冻结后续提交；已挂载Surface仍保留，等待releasePlayer完整停止原生输出。 */
  private beginExit(): void {
    this.exitPending = true;
    this.fetchGeneration++;
    this.detailGeneration++;
    if (this.settleTimer !== -1) { clearTimeout(this.settleTimer); this.settleTimer = -1; }
    this.flushContentWaiters();
  }

  private restoreAfterExitFailure(): void {
    this.exitPending = false;
    this.handle.cancelExit();
    if (this.destroyed) { return; }
    this.finishRouteEntry();
    this.episodeSwitching = false;
    if (this.loading) { this.fetch(); }
    else if (this.detail !== undefined && this.localPath.length === 0) {
      this.loadComments(true);
      this.loadOnlineExtras(this.detail);
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
    this.reportVisualRect(true);
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
    if (this.destroyed || this.exitPending) { return; }
    const generation: number = ++this.fetchGeneration;
    const requestedCid: number = this.initialCid > 0 ? this.initialCid : this.currentCid();
    if (this.localPath.length > 0) {
      try {
        await DownloadService.load();
        if (this.destroyed || this.exitPending || generation !== this.fetchGeneration) { return; }
        this.offlineTasks = DownloadLibraryService.playlist(this.offlineContext);
        this.offlineDs.reload(this.offlineTasks);
        const task = this.offlineTasks.find((t: DownloadTask): boolean => t.bvid === this.bvid && t.cid === this.localCid);
        if (!task) { this.error = '本地文件已失效，请返回缓存页检查'; this.notifyVisualUnavailable(); }
        else { this.localCover = task.cover; this.localArtist = task.upName; this.localDuration = task.duration;
          this.localAudioPath = task.audioPath; if (this.localPath !== task.filePath) { this.localPath = task.filePath; }
          this.updateLocalSource(); }
      } catch (e) {
        if (!this.destroyed && !this.exitPending && generation === this.fetchGeneration) {
          this.error = (e as Error).message; this.notifyVisualUnavailable();
        }
      }
      if (!this.destroyed && !this.exitPending && generation === this.fetchGeneration) { this.loading = false; }
      return;
    }
    if (this.bvid.length === 0) {
      this.error = '缺少 bvid';
      this.loading = false;
      this.notifyVisualUnavailable();
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const d: VideoDetail = await VideoService.viewDetail(this.bvid);
      if (this.destroyed || this.exitPending || generation !== this.fetchGeneration) { return; }
      const initialPage: number = Math.max(0, d.pages.findIndex((p: VideoPageInfo): boolean => p.cid === requestedCid));
      this.prepareOnlineSource(d, initialPage);
      if (this.onlineSource === undefined) { throw new Error('缺少可播放分集'); }
      // Nara半程只放行唯一播放器；正文与列表仍避开整段转场。
      await this.waitForContentIdle();
      if (this.destroyed || this.exitPending || generation !== this.fetchGeneration) {
        return;
      }
      this.initialCid = 0;
      this.applyOnlineDetail(d, initialPage);
      const loggedIn: boolean = await AuthService.isLogin();
      if (this.destroyed || this.exitPending || generation !== this.fetchGeneration) { return; }
      this.loggedIn = loggedIn;
      this.showLoadedBody();
      this.loadOnlineExtras(d);
    } catch (e) {
      if (this.destroyed || this.exitPending || generation !== this.fetchGeneration) {
        return;
      }
      const err = e as Error;
      this.error = err.message !== undefined && err.message.length > 0 ? ('加载失败：' + err.message) : '加载失败，请重试';
      this.loading = false;
      this.notifyVisualUnavailable();
    }
  }

  /** 先完成播放器首次布局，再在下一帧构建简介，避免两棵树挤在同一帧。 */
  private onPlayerInitialLayout(): void {
    if (this.destroyed) { return; }
    // 首布局只通知一次；退出期间也记住私有标记，取消退出后不必等待第二次通知。
    if (this.exitPending) { this.playerLayoutReady = true; return; }
    this.getUIContext().postFrameCallback(new DetailPlayerLayoutCallback((): void => {
      if (this.destroyed) { return; }
      this.playerLayoutReady = true;
      if (!this.exitPending && this.initialBodyReady) { this.loading = false; }
    }));
  }

  private showLoadedBody(): void {
    if (this.destroyed || this.exitPending) { return; }
    this.initialBodyReady = true;
    if (this.playerLayoutReady) { this.loading = false; }
  }

  /** 网络继续并发，列表提交避开路由/横滑关键帧；无轮询，退页解开所有等待。 */
  private finishRouteEntry(): void {
    if (this.settleTimer !== -1) { clearTimeout(this.settleTimer); this.settleTimer = -1; }
    if (this.destroyed || this.exitPending || this.routeSettled) { return; }
    this.routeSettled = true;
    this.playbackMountReady = true;
    this.flushContentWaiters();
  }

  private onRouteEntryProgress(progress: number): void {
    if (this.destroyed || this.exitPending) { return; }
    if (progress >= 0.5) { this.playbackMountReady = true; }
    if (progress < 1 || this.routeSettled) { return; }
    if (this.settleTimer !== -1) { clearTimeout(this.settleTimer); }
    // 离开转场回调后再提交新树；无动画/未回调时仍有原有时长兜底。
    this.settleTimer = setTimeout((): void => { this.finishRouteEntry(); }, 0);
  }

  private waitForContentIdle(): Promise<void> {
    if (this.destroyed || this.exitPending) { return Promise.resolve(); }
    return new Promise<void>((resolve: () => void): void => {
      this.contentWaiters.push(resolve);
      this.flushContentWaiters();
    });
  }

  private flushContentWaiters(): void {
    if (this.destroyed || this.exitPending) {
      const pending: (() => void)[] = this.contentWaiters;
      this.contentWaiters = [];
      pending.forEach((resolve: () => void): void => { resolve(); });
      return;
    }
    if (!this.routeSettled || this.tabMoving || this.tabAnimating ||
      this.contentFramePending || this.contentWaiters.length === 0) { return; }
    // 同时到达的详情/评论/推荐不再于一个微任务批次全部建树；每帧只放行一个提交。
    this.contentFramePending = true;
    this.getUIContext().postFrameCallback(new DetailContentIdleCallback((): void => {
      this.contentFramePending = false;
      if (this.destroyed || this.exitPending || !this.routeSettled || this.tabMoving || this.tabAnimating) {
        if (this.destroyed || this.exitPending) { this.flushContentWaiters(); }
        return;
      }
      const resolve: (() => void) | undefined = this.contentWaiters.shift();
      if (resolve !== undefined) { resolve(); }
      this.flushContentWaiters();
    }));
  }

  /** 先绘制简介，再在独立空闲帧物化相邻评论页，首个横滑无需临时建整棵树。 */
  private async preloadCommentTab(): Promise<void> {
    if (this.destroyed || this.exitPending) { return; }
    const generation: number = ++this.tabsGeneration;
    this.tabsMounted = true;
    await this.waitForContentIdle();
    if (this.destroyed || this.exitPending || !this.tabsMounted || generation !== this.tabsGeneration || this.tab === 1) { return; }
    try { await this.tabsCtrl.preloadItems([1]); }
    catch (_) { /* 预加载失败仍保留原生Tabs按需构建，不阻断切页。 */ }
  }

  private uniqueComments(items: CommentItem[]): CommentItem[] {
    return items.filter((item: CommentItem): boolean => {
      if (this.commentIds.has(item.rpid)) { return false; }
      this.commentIds.add(item.rpid);
      return true;
    });
  }

  private canPrefetchComments(): boolean {
    return !this.destroyed && !this.exitPending && this.routeVisible && this.commentsForeground &&
      this.tab === 1 && !this.subShown && !this.episodeShown && !this.favSheetShown && !this.isFullscreen &&
      router.getState().index === this.routeIndex;
  }

  private prefetchComments(start: number, end: number): void {
    const screenCount: number = Math.max(1, end - start + 1);
    if (this.canPrefetchComments() && !this.firstLoading && this.replyErr.length === 0 && this.ds.size() > 0 &&
      end >= 1 + this.topItems.length + this.ds.size() - 1 - screenCount) { this.loadComments(false); }
  }

  private async loadComments(reset: boolean): Promise<void> {
    if (this.destroyed || this.exitPending || (!reset && this.loadingMoreReply) || this.aid === 0) {
      return;
    }
    if (!reset && this.replyEnd) {
      return;
    }
    this.loadingMoreReply = true;
    this.replyRetryReset = reset;
    const generation: number = reset ? ++this.commentGeneration : this.commentGeneration;
    this.replyErr = '';
    if (reset) {
      this.firstLoading = true;
    }
    try {
      const requestedOffset: string = reset ? '' : this.nextOffset;
      const r = await VideoService.reply(this.aid, requestedOffset, this.sortMode);
      await this.waitForContentIdle();
      if (this.destroyed || this.exitPending || generation !== this.commentGeneration) {
        return;
      }
      if (reset) {
        this.commentIds.clear();
        this.topItems = this.uniqueComments(r.topItems);
        this.ds.reload(this.uniqueComments(r.items));
      } else {
        this.ds.append(this.uniqueComments(r.items));
      }
      if (r.total > 0) {
        this.replyTotal = r.total;
      }
      if (r.sortName.length > 0) {
        this.sortName = r.sortName;
      }
      this.nextOffset = r.nextOffset;
      this.replyEnd = r.isEnd || r.nextOffset === requestedOffset;
    } catch (e) {
      await this.waitForContentIdle();
      if (this.destroyed || this.exitPending || generation !== this.commentGeneration) { return; }
      const err = e as Error;
      this.replyErr = '评论加载失败，点击重试';
    } finally {
      if (!this.destroyed && !this.exitPending && generation === this.commentGeneration) {
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
  private toggleSub(item: CommentItem, targetRpid: number = 0): void {
    if (this.subShown || this.subClosing) { return; }
    this.subRoot = item;
    this.subTargetRpid = targetRpid;
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
      await win.setPreferredOrientation(target ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.PORTRAIT);
      if (this.destroyed) { await win.setPreferredOrientation(window.Orientation.PORTRAIT); return; }
      if (generation === this.orientationGeneration) {
        this.finishFullscreen(this.viewportWidth, this.viewportHeight);
      } else {
        // 超时后的迟到请求不能把新请求/已提交的页面留在旧方向。
        const landscape: boolean = this.fullscreenTarget ?? this.isFullscreen;
        await win.setPreferredOrientation(landscape ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.PORTRAIT);
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
      this.mainWin.setPreferredOrientation(this.isFullscreen ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.PORTRAIT)
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
    // 小窗/分屏：布局按窗口尺寸算，不能继续用整块屏幕的宽高
    const w: number = px2vp(size.width);
    const h: number = px2vp(size.height);
    if (w > 0 && h > 0) { this.screenW = w; this.screenH = h; }
    this.updateControlInsets();
    this.finishFullscreen(size.width, size.height);
    this.reportVisualRect(true);
  }

  /** 系统返回（侧滑/按键）：全屏时先退全屏，不退出页面 */
  onHostBack(): boolean {
    if (this.destroyed || this.exitPending) { return true; }
    if (this.episodeShown) { this.episodeShown = false; return true; }
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
        { page: p.page, seasonId: d.seasonId || '', seasonTitle: d.seasonTitle || '', seasonOrder: d.seasonOrder || 0,
          upMid: this.upMid }); }
      this.refreshCacheState();
      promptAction.showToast({ message: '已加入缓存队列' });
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message });
    } finally { this.cacheSubmitting = false; }
  }

  private refreshCacheState(): void {
    if (this.destroyed || this.exitPending) { return; }
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
    if (this.destroyed || this.exitPending || !this.loggedIn || this.aid === 0) {
      return;
    }
    const generation: number = this.detailContentGeneration;
    const aid: number = this.aid;
    const bvid: string = this.bvid;
    try {
      const u = await AuthService.fetchNav();
      if (u === null || this.destroyed || this.exitPending || generation !== this.detailContentGeneration) { return; }
      const folders: FavFolder[] = await FavService.folders(u.mid, aid);
      if (this.destroyed || this.exitPending || generation !== this.detailContentGeneration) { return; }
      this.folders = folders;
      this.favFoldersReady = folders.every((f: FavFolder): boolean => f.stateKnown === true);
      this.folderOriginal = folders.map((f: FavFolder): boolean => f.favState === true);
      this.favoured = this.folderOriginal.some((v: boolean): boolean => v);
      // 稍后再看状态（列表量小，直接查）
      const later = await FavService.laterList();
      if (this.destroyed || this.exitPending || generation !== this.detailContentGeneration) { return; }
      this.laterAdded = false;
      for (let i = 0; i < later.length; i++) {
        if (later[i].bvid === bvid) {
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
  /** 标签行：Nara 的圆角标签，点击进搜索；无标签时不占行高。 */
  @Builder
  TagRow() {
    if (this.videoTags.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.videoTags, (tag: VideoTag) => {
          Text(tag.display())
            .fontSize(13)
            .fontColor($r('app.color.nara_secondary'))
            .backgroundColor($r('app.color.btn_soft_bg'))
            .borderRadius(6)
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .margin({ right: 8, bottom: 8 })
            .id('video_tag_' + tag.id.toString())
            .onClick((): void => { this.openTag(tag); })
        }, (tag: VideoTag) => tag.id.toString() + '_' + tag.name)
      }
      .width('100%').margin({ top: 8 })
    }
  }

  /** 简介/标签是否有点开的必要：都没内容时点标题不该有任何反应。 */
  private hasIntro(d: VideoDetail): boolean {
    return d.desc.length > 0 || this.videoTags.length > 0;
  }

  private toggleIntro(): void {
    const d: VideoDetail | undefined = this.detail;
    if (d === undefined || !this.hasIntro(d)) { return; }
    this.descExpanded = !this.descExpanded;
  }

  private openTag(tag: VideoTag): void {
    const keyword: string = tag.display();
    if (keyword.length === 0) { return; }
    router.pushUrl({ url: 'pages/search/SearchPage', params: { 'keyword': keyword } });
  }

  private descSegments(desc: string): RichSegment[] {
    if (this.descRichKey !== desc) {
      this.descRichKey = desc;
      this.descRichCache = RichText.isRich(desc) ? RichText.parse(desc) : [];
    }
    return this.descRichCache;
  }

  private descSegmentColor(segment: RichSegment): ResourceColor {
    return segment.kind === RichKind.Link ? $r('app.color.link_blue') : $r('app.color.brand_pink');
  }

  private tapDescSegment(segment: RichSegment): void {
    if (segment.kind === RichKind.Link) {
      RichText.openUrl(getContext(this) as common.UIAbilityContext, segment.target);
    } else if (segment.kind === RichKind.Mention) {
      openMention(segment.target, []);
    }
  }

  @Builder
  ExpandedIntro(d: VideoDetail) {
    Column() {
      Column({ space: 2 }) {
        if (this.descSegments(d.desc).length > 0) {
          Text() {
            ForEach(this.descSegments(d.desc), (segment: RichSegment) => {
              if (segment.kind === RichKind.Plain) {
                Span(segment.text).fontSize(13).fontColor($r('app.color.text_secondary'))
              } else {
                Span(segment.text).fontSize(13).fontColor(this.descSegmentColor(segment))
                  .onClick((): void => { this.tapDescSegment(segment); })
              }
            }, (segment: RichSegment, index: number) => index.toString() + '_' + segment.kind.toString())
          }
          .fontSize(13)
          .lineHeight(20)
          .width('100%')
        } else if (d.desc.length > 0) {
          Text(d.desc).fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary')).width('100%')
        }
        Text('收起')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .onClick((): void => {
            this.descExpanded = false;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start).margin({ top: 8 })

      this.TagRow()
    }
    .width('100%')
    .height(LayoutPolicy.fixAtIdealSize)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Header(d: VideoDetail) {
    Column() {
      // Nara 行为：标题/播放数据整块可点，简介与标签默认折叠（高度 0），点一下展开
      Text(d.title)
        .id('video_intro_toggle')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .onClick((): void => { this.toggleIntro(); })

      Text(formatPlayCount(d.viewCount) + '播放 · ' + formatPlayCount(d.danmakuCount) + '弹幕 · ' + fmtDate(d.pubdate))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%').margin({ top: 8 })
        .onClick((): void => { this.toggleIntro(); })

      // 操作行上方的间距也归入同一高度动画，避免点开时8vp间距先瞬间消失。
      Column() {
        MeasuredContent({ content: (): void => { this.ExpandedIntro(d); },
          onHeight: (height: number): void => { this.descH = height; } })
          .width('100%')
      }
      .width('100%')
      .height(this.descExpanded ? Math.max(8, this.descH + (this.videoTags.length > 0 ? 0 : 8)) : 8)
      .id('video_intro_panel')
      .clip(true)
      .animation({ duration: 300, curve: Curve.Linear })

      Row({ space: 10 }) {
        this.DetailAction(0)
        this.DetailAction(1)
        this.DetailAction(2)
      }
      .id('video_detail_actions')
      .width('100%')
      if (d.season !== undefined) {
        Row({ space: 10 }) {
          Text('合集：' + d.season.title).fontSize(12).fontColor($r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Image($r('app.media.icon_living_static')).width(12).height(12).fillColor($r('app.color.brand_pink')).margin({ left: 5 })
          Text(this.seasonProgress()).fontSize(12).fontColor($r('app.color.text_primary'))
          Image($r('app.media.icon_arrow_right')).width(13).height(13).fillColor($r('app.color.text_primary')).margin({ left: -4 })
        }.width('calc(100% - 4vp)').padding({ left: 8, right: 8, top: 12, bottom: 12 })
          .backgroundColor($r('app.color.btn_soft_bg')).borderRadius(6).margin({ left: 2, right: 2, top: 8 })
          .id('video_season_entry').accessibilityText('合集：' + d.season.title + ' ' + this.seasonProgress())
          .onClick(() => { this.openEpisodes(true); })
      }
      if (this.partsCount > 1) {
        // 不捕获Builder参数d；BV和pages由页面一次提交的primitive快照统一传递。
        VideoPartsStrip({ source: this.partsSource, currentCid: this.currentCid(),
          onOpen: () => { this.openEpisodes(false); }, onSelect: (selection: EpisodeSelection): void => { this.selectEpisode(selection); } })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.bg_page'))
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

  private async changeDanmaku(value: DanmakuPreferences): Promise<void> {
    if (!this.danmakuReady) { return; }
    const previous: DanmakuPreferences = this.danmakuPreferences;
    const revision: number = ++this.danmakuRevision;
    this.danmakuPreferences = copyDanmakuPreferences(value);
    try { await DanmakuSettings.save(this.danmakuPreferences); }
    catch (_) {
      if (!this.destroyed && revision === this.danmakuRevision) {
        this.danmakuPreferences = previous;
        promptAction.showToast({ message: '弹幕设置保存失败，请重试' });
      }
    }
  }

  private toggleDanmaku(): void {
    const value: DanmakuPreferences = copyDanmakuPreferences(this.danmakuPreferences);
    value.enabled = !value.enabled; this.changeDanmaku(value);
  }

  @Builder
  TabBar() {
    Row() {
    if (this.isOfflinePlayback()) {
      // Nara video/view.dart:2341/2362：本地源只有一个 tab「离线视频」，
      // 单 tab 不画下划线指示器，label 用常规主文字色（非主题主色），最宽 96 左对齐。
      Text('离线视频')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width(96)
        .height(45)
        .textAlign(TextAlign.Start)
        .accessibilityText('离线视频')
    } else {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row() {
        this.TabLabel('简介', 0)
        this.TabLabel(this.replyTotal > 0 ? ('评论 ' + formatPlayCount(this.replyTotal)) : '评论', 1)
      }
      .width('100%').height('100%')
      Rect().height(3).width(this.indicatorWidth()).radius(1.5)
        .fill($r('app.color.brand_pink'))
        .position({ x: this.tabBarWidth * (0.25 + this.tabProgress * 0.5) - this.indicatorWidth() / 2, y: 42 })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('calc(100% - 52vp)').constraintSize({ maxWidth: 192 })
    .height(45)
    .onAreaChange((_old: Area, area: Area): void => { this.tabBarWidth = Number(area.width); })
    }
    Blank()
    Button({ type: ButtonType.Normal }) {
      Image(this.danmakuPreferences.enabled ? $r('app.media.icon_dm_on') : $r('app.media.icon_dm_off'))
        .width(22).height(22)
        .fillColor(this.danmakuPreferences.enabled ? $r('app.color.nara_secondary') : $r('app.color.nara_outline'))
    }.width(38).height(38).padding(0).margin({ right: 14 }).backgroundColor(Color.Transparent)
      .enabled(this.danmakuReady && !this.isOfflinePlayback())
      .id('danmaku_inline_toggle')
      .accessibilityText(this.danmakuPreferences.enabled ? '关闭弹幕' : '开启弹幕')
      .onClick((): void => { this.toggleDanmaku(); })
    }.width('100%').height(45)
    .backgroundColor($r('app.color.bg_page'))
    .border({ width: { bottom: 1 }, color: $r('app.color.tab_divider') })
  }

  private async toggleFollow(): Promise<void> {
    if (this.followBusy || this.upMid <= 0 || this.exitPending) {
      return;
    }
    const ownerMid: number = this.upMid;
    const generation: number = this.detailContentGeneration;
    this.followBusy = true;
    try {
      const logged: boolean = await AuthService.isLogin();
      if (this.destroyed || this.exitPending || generation !== this.detailContentGeneration) { return; }
      if (!logged) { promptAction.showToast({ message: '请先登录' }); return; }
      const next: boolean = !this.followed;
      await VideoService.relationModify(ownerMid, next);
      if (!this.destroyed && !this.exitPending && generation === this.detailContentGeneration) {
        this.followed = next;
        promptAction.showToast({ message: next ? '已关注' : '已取消关注' });
      }
    } catch (e) {
      if (!this.destroyed && !this.exitPending && generation === this.detailContentGeneration) {
        promptAction.showToast({ message: '操作失败，请重试' });
      }
    } finally { this.followBusy = false; }
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

  /** 推荐标题；卡片作为List独立懒加载项，避免整组构建和测量。 */
  @Builder
  RelatedSection() {
    Column() {
      if (this.relatedCount > 0) {
        Text('相关推荐')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .padding({ left: 12, right: 12, top: 12, bottom: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** R8：UP 主区（头像 + 名字 + 粉丝数 + 关注按钮，对齐 Nara 实拍 39） */
  @Builder
  UpArea(d: VideoDetail) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Column() {
          AsyncImage({ src: d.ownerFace, w: 120, h: 120 })
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .clip(true)
        .backgroundColor($r('app.color.btn_soft_bg'))

      }
      .width(40)
      .height(40)
      .onClick(() => { openMember(d.ownerMid); })

      Column({ space: 3 }) {
        Text(d.ownerName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.upSubText())
          .fontSize(11)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => { openMember(d.ownerMid); })

      Button(this.followed ? '已关注' : '关注')
        .fontSize(12)
        .height(30)
        .padding({ left: 14, right: 14 })
        .borderRadius(15)
        .backgroundColor(this.followed ? $r('app.color.btn_soft_bg') : $r('app.color.brand_pink'))
        .fontColor(this.followed ? $r('app.color.text_secondary') : '#FFFFFF')
        .enabled(!this.followBusy)
        .onClick(() => {
          this.toggleFollow();
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 0 })
  }

  /** UP 行副标题：粉丝 + 投稿数（Nara 同行展示）。 */
  private upSubText(): string {
    if (this.upFans <= 0 && this.upVideos <= 0) { return '粉丝数加载中…'; }
    const fans: string = formatPlayCount(this.upFans) + '粉丝';
    return this.upVideos > 0 ? fans + ' · ' + formatPlayCount(this.upVideos) + '视频' : fans;
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

  private offlineIndex(): number {
    return this.offlineTasks.findIndex((t: DownloadTask): boolean => t.bvid === this.bvid && t.cid === this.localCid);
  }

  private updateLocalSource(): void {
    this.prepareSourceGeometry(this.bvid, this.localCid, this.localPath, 0, 0);
    this.localSource = { bvid: this.bvid, cid: this.localCid, localPath: this.localPath,
      localAudioPath: this.localAudioPath,
      title: this.localTitle, artist: this.localArtist, cover: this.localCover, localDuration: this.localDuration,
      offlineScope: this.offlineContext.scope, offlineKey: this.offlineContext.key };
    this.reportVisualRect(true);
  }

  private playOffline(task: DownloadTask): void {
    if (this.exitPending || this.destroyed) { return; }
    if (!DownloadLibraryService.available(task)) { promptAction.showToast({ message: '本地文件已失效' }); return; }
    // 同一页面/Surface保留全屏和倍速，单个源快照避免不同P的字段交叉。
    this.bvid = task.bvid; this.localCid = task.cid; this.localPath = task.filePath;
    this.localAudioPath = task.audioPath;
    this.localCover = task.cover; this.localArtist = task.upName; this.localDuration = task.duration;
    this.localTitle = task.part ? task.title + ' · ' + task.part : task.title;
    this.updateLocalSource();
  }

  private nextOffline(delta: number): void {
    const index: number = this.offlineIndex() + delta;
    if (index >= 0 && index < this.offlineTasks.length) { this.playOffline(this.offlineTasks[index]); }
  }

  private isOfflinePlayback(): boolean {
    return this.localPath.length > 0;
  }

  /** 回到该视频的在线页：先释放本地播放器再 replaceUrl，避免同栈叠出第二个内核实例。 */
  private async openOnlineDetail(t: DownloadTask): Promise<void> {
    if (this.exitPending || this.destroyed) { return; }
    this.beginExit();
    try {
      await this.releasePlayer();
      if (this.destroyed) { return; }
      await router.replaceUrl({
        url: 'pages/video/VideoDetailPage',
        params: { 'bvid': t.bvid, 'cid': t.cid.toString() }
      });
    } catch (_) {
      this.restoreAfterExitFailure();
      if (!this.destroyed) { promptAction.showToast({ message: '打开视频页失败' }); }
    }
  }

  private async copyOfflinePath(t: DownloadTask): Promise<void> {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, t.filePath);
      await pasteboard.getSystemPasteboard().setData(data);
      if (!this.destroyed) { promptAction.showToast({ message: '已复制缓存路径' }); }
    } catch (_) {
      if (!this.destroyed) { promptAction.showToast({ message: '复制失败' }); }
    }
  }

  /** 删除单个缓存：二次确认 → 删文件 → 重排列表（删的是当前播放项则切到剩余首项）。 */
  private confirmRemoveOffline(t: DownloadTask): void {
    AlertDialog.show({
      title: '删除缓存',
      message: '将删除「' + (t.part.length > 0 ? t.part : t.title) + '」的本地文件。',
      autoCancel: true,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: '#E54D42',
        action: () => { this.removeOffline(t); }
      }
    });
  }

  private async removeOffline(t: DownloadTask): Promise<void> {
    try {
      await DownloadService.removeMany([t.cid]);
    } catch (e) {
      if (!this.destroyed) { promptAction.showToast({ message: (e as Error).message }); }
      return;
    }
    if (this.destroyed) { return; }
    this.offlineTasks = DownloadLibraryService.playlist(this.offlineContext);
    this.offlineDs.reload(this.offlineTasks);
    if (this.offlineTasks.length === 0) { this.leaveVideo(); return; }
    const playing: boolean = this.offlineTasks.some((v: DownloadTask): boolean => v.bvid === this.bvid && v.cid === this.localCid);
    if (!playing) { this.playOffline(this.offlineTasks[0]); }
  }

  /** 旧任务没存 mid（upMid=0）时按 UP 名反查一次，命中后回填内存。 */
  private async visitUpOf(t: DownloadTask): Promise<void> {
    if (t.upMid > 0) { openMember(t.upMid); return; }
    const name: string = t.upName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '缺少 UP 主信息' });
      return;
    }
    try {
      const mid: number = await VideoService.searchUserByName(name);
      if (this.destroyed) { return; }
      if (mid > 0) {
        t.upMid = mid;
        openMember(mid);
      } else {
        promptAction.showToast({ message: '未找到该 UP 主' });
      }
    } catch (_) {
      if (!this.destroyed) { promptAction.showToast({ message: '查找失败，请检查网络' }); }
    }
  }

  /** 离线视频列表：与在线播放同一骨架，tab 栏下方就是这一列（不再有页面级大标题与上下集按钮）。 */
  @Builder
  LocalVideoPanel() {
    List() {
      LazyForEach(this.offlineDs, (t: DownloadTask) => {
        ListItem() {
          OfflineVideoCard({
            task: t,
            current: t.cid === this.localCid && t.bvid === this.bvid,
            onOpen: (): void => { if (t.cid !== this.localCid) { this.playOffline(t); } },
            onOpenOnline: (): void => { this.openOnlineDetail(t); },
            onCopyPath: (): void => { this.copyOfflinePath(t); },
            onVisitUp: (): void => { this.visitUpOf(t); },
            onRemove: (): void => { this.confirmRemoveOffline(t); }
          })
        }
      }, (t: DownloadTask): string => t.bvid + ':' + t.cid.toString())
    }
    .width('100%')
    .layoutWeight(1)
    .cachedCount(2)
    // 与收藏/历史等列表页一致：只留顶部 7vp，滚到底就是最后一项贴底，不做底部留白。
    .padding({ top: 7 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
    .nestedScroll(DETAIL_NESTED_SCROLL)
  }

  /** 与加载完成后的Tab/UP/标题位置一致，首帧即建立详情几何。 */
  @Builder
  EntrySkeleton() {
    Column() {
      this.TabBar()
      Row({ space: 10 }) {
        Circle().width(34).height(34).fill($r('app.color.btn_soft_bg'))
        Column({ space: 7 }) {
          Rect().width(88).height(13).radius(3).fill($r('app.color.btn_soft_bg'))
          Rect().width(120).height(10).radius(3).fill($r('app.color.btn_soft_bg'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Rect().width(54).height(28).radius(5).fill($r('app.color.btn_soft_bg'))
      }.width('100%').height(58).padding({ left: 12, right: 12 })
      Column({ space: 10 }) {
        Rect().width('94%').height(17).radius(3).fill($r('app.color.btn_soft_bg'))
        Rect().width('68%').height(17).radius(3).fill($r('app.color.btn_soft_bg'))
        Rect().width('60%').height(12).radius(3).fill($r('app.color.btn_soft_bg'))
        Row({ space: 10 }) {
          Rect().layoutWeight(1).height(32).radius(5).fill($r('app.color.btn_soft_bg'))
          Rect().layoutWeight(1).height(32).radius(5).fill($r('app.color.btn_soft_bg'))
          Rect().layoutWeight(1).height(32).radius(5).fill($r('app.color.btn_soft_bg'))
        }.width('100%')
      }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
      Blank()
    }.width('100%').height(this.visibleBodyHeight()).hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Refresh({ refreshing: $$this.refreshing, builder: this.EmptyRefreshIndicator() }) {
        Scroll(this.headerScroller) {
          Column() {
      // 顶栏已移除（对齐 Nara：播放器自带返回/标题覆盖层，页面不再有「视频详情」标题栏）

      // 整页变换由宿主承担；自动入场始终黑底，不能先显示封面再切视频。
      Column() {
        if (this.error.length === 0 && (!this.playbackMountReady ||
          (this.onlineSource === undefined && this.localPath.length === 0))) {
          LoadingProgress().width(36).height(36).color('#FFFFFF')
        }
      }
      .width('100%')
      .height(this.playerHeight() + this.statusBarH)
      .opacity(this.inputHeroMoving ? 0 : 1)
      .backgroundColor('#000000')
      .padding({ top: this.statusBarH })
      .justifyContent(FlexAlign.Center)
      .clip(true)
      if (this.loading) {
        this.EntrySkeleton()
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
      } else if (this.isOfflinePlayback() && !this.isFullscreen) {
        // 与在线播放同一骨架：播放器 → tab 栏 → 内容（Nara video/view.dart:1916-1950）。
        // 高度必须跟 playerBoxHeight 联动（visibleBodyHeight），用 bodyHeight 会在播放时
        // 比可见区高出一条，外层 Scroll 会把 tab 栏一起滚走。
        Column() {
          this.TabBar()
          this.LocalVideoPanel()
        }
        .width('100%')
        .height(this.visibleBodyHeight())
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

              LazyForEach(this.relatedDs, (item: VideoItem) => {
                ListItem() { this.RelatedRow(item) }.width('100%')
              }, (item: VideoItem) => item.key)
            }
            .cachedCount(3)
            .scrollBar(BarState.Off)
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
                        onOpenSub: (it: CommentItem, targetRpid: number) => {
                          this.toggleSub(it, targetRpid);
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
                        onOpenSub: (it: CommentItem, targetRpid: number) => {
                          this.toggleSub(it, targetRpid);
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

                // 紧凑页脚；仅此处补一次底部安全区。
                ListItem() {
                  Column() {
                    if (this.replyErr.length > 0) {
                      Text(this.replyErr)
                        .fontSize(12)
                        .fontColor($r('app.color.brand_pink'))
                        .onClick(() => {
                          this.loadComments(this.replyRetryReset);
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
                  .height(48)
                  .justifyContent(FlexAlign.Center)
                  .margin({ bottom: this.navBarH })
                }
                .width('100%')
              }
              .cachedCount(1)
              .scrollBar(BarState.Off)
              .width('100%')
              .height('100%')
              .divider({ strokeWidth: 0.3, color: '#14000000', startMargin: 55, endMargin: 15 })
              .onReachEnd(() => {
                if (this.canPrefetchComments() && !this.firstLoading && this.replyErr.length === 0) { this.loadComments(false); }
              })
              .onScrollIndex((start: number, end: number) => { this.prefetchComments(start, end); })
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
        .edgeEffect(EdgeEffect.None)
        .layoutWeight(1)
        .width('100%')
        .animationDuration(300)
        .onAppear((): void => { this.preloadCommentTab(); })
        .onContentDidScroll((_selected: number, index: number, position: number): void => {
          this.tabProgress = Math.max(0, Math.min(1, index - position));
          this.tabMoving = position > -0.999 && position < 0.999 && Math.abs(position) > 0.001;
          this.flushContentWaiters();
        })
        .onAnimationStart((): void => { this.tabAnimating = true; })
        .onAnimationEnd((index: number, extraInfo: TabsAnimationEvent): void => {
          this.tabProgress = index;
          this.tabMoving = Math.abs(extraInfo.currentOffset) > 0.5;
          this.tabAnimating = false;
          this.flushContentWaiters();
        })
        .onDisAppear((): void => {
          this.tabsMounted = false;
          this.tabsGeneration++;
          this.tabMoving = false;
          this.tabAnimating = false;
          this.flushContentWaiters();
        })
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
        if (this.episodeShown && this.detail !== undefined) {
          VideoEpisodePanel({ detail: this.detail, currentCid: this.currentCid(), seasonMode: this.episodeSeason,
            initialSection: this.currentSeasonSection(), onClose: () => { this.episodeShown = false; },
            onSelect: (selection: EpisodeSelection): void => { this.selectEpisode(selection); } })
            .width('100%').height(this.visibleBodyHeight())
            .transition(TransitionEffect.move(TransitionEdge.BOTTOM))
        }
        if (this.episodeSwitching) {
          Row({ space: 6 }) {
            LoadingProgress().width(16).height(16).color($r('app.color.brand_pink'))
            Text('正在切换…').fontSize(12).fontColor($r('app.color.text_secondary'))
          }.padding(8).borderRadius(8).backgroundColor($r('app.color.card_bg')).position({ x: 12, y: 50 })
            .hitTestBehavior(HitTestMode.None)
        }
        if (this.subShown && this.subRoot !== undefined) {
          SubReplyPanel({ embedded: true, root: this.subRoot, upMid: this.upMid, aid: this.aid,
            active: this.routeVisible && !this.isFullscreen,
            targetRpid: this.subTargetRpid,
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
        .backToTop(this.routeVisible && !this.isFullscreen)
        .friction(DETAIL_SCROLL_FRICTION)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .onDidScroll(() => { this.syncHeaderScroll(); })
        // 保留原生嵌套链处理归顶/惯性；仅抵消Refresh实际位移，不改Scroll偏移或播放器比例。
        .translate({ y: -this.refreshPullOffset })
      }
      .width('100%').height('100%')
      .visibility(this.isFullscreen ? Visibility.None : Visibility.Visible)
      .pullToRefresh(!this.subShown && this.tab === 1 && this.scrollAcc < 0.5)
      .refreshOffset(64)
      .onOffsetChange((offset: number): void => { this.refreshPullOffset = Math.max(0, offset); })
      .onRefreshing(() => { this.refreshing = true; this.loadComments(true); })
      // 内嵌播放器（spec-06a；单一实例，全屏只改尺寸，避免 Surface 重建）
      // 离线播放（localPath 非空）时即使详情未加载完成也先渲染播放器
      if (this.playbackMountReady && (this.onlineSource !== undefined || this.localPath.length > 0)) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            Column().width('100%').height(this.isFullscreen ? 0 : this.statusBarH)
            Stack() {
            PlayerView({
              onInitialLayout: (): void => { this.onPlayerInitialLayout(); },
              sourceWidth: this.sourceDimension(true),
              sourceHeight: this.sourceDimension(false),
              onVideoSize: this.videoSizeHandler(),
              onVideoOutputReady: this.videoOutputReadyHandler(),
              visible: this.routeVisible,
              registerRelease: (release: () => Promise<void>): void => { this.releasePlayer = release; },
              bvid: this.bvid,
              cid: this.onlineSource !== undefined ? this.onlineSource.cid : this.currentCid(),
              cover: this.onlineSource !== undefined ? this.onlineSource.cover : this.localCover,
              title: this.onlineSource !== undefined ? this.onlineSource.title : this.localTitle,
              artist: this.onlineSource !== undefined ? this.onlineSource.artist : this.localArtist,
              partText: this.partLabel(),
              danmakuCount: this.detail !== undefined ? this.detail.danmakuCount : 0,
              danmakuPreferences: this.danmakuPreferences,
              danmakuReady: this.danmakuReady,
              onDanmakuChange: (value: DanmakuPreferences): void => { this.changeDanmaku(value); },
              isFullscreen: this.isFullscreen,
              controlInsetTop: this.controlInsetTop,
              controlInsetLeft: this.controlInsetLeft,
              controlInsetRight: this.controlInsetRight,
              autoPlay: !this.exitPending,
              showIdleCover: false,
              localPath: this.localPath,
              localSource: this.localSource,
              playbackSource: this.onlineSource,
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
              onStateChange: this.playerStateHandler(),
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
            }
            .id(this.playerVisualId)
            .width('100%')
            .layoutWeight(1)
            .clip(true)
            .onAreaChange((): void => { this.reportVisualRect(); })
          }
          .width('100%')
          .height('100%')

        }
        .width('100%')
        .height(this.isFullscreen ? '100%' : this.playerBoxHeight())
        .opacity(this.inputHeroMoving ? 0 : 1)
        .backgroundColor('#000000')
        .clip(true)
      }

      if (this.inputExitCover) {
        Column() {
          AsyncImage({ src: this.inputCover.length > 0 ? this.inputCover : this.localCover, w: 320, h: 200,
            synchronous: true })
        }
        .width('100%').height(this.playerBoxHeight()).backgroundColor('#000000')
        .hitTestBehavior(HitTestMode.None)
      }
    }
     .width('100%')
     .height('100%')
     .onAreaChange((_old: Area, area: Area) => { this.pageHeight = Number(area.height); })
     .backgroundColor(this.isFullscreen ? '#000000' : $r('app.color.bg_page'))
  }
}

/**
 * 离线视频列表项（Nara introduction/local/view.dart:50-199）。
 * 菜单状态必须放在组件内：所有行共享父页面 @State 会让整个列表的菜单同时展开。
 */
@Component
struct OfflineVideoCard {
  @ObjectLink task: DownloadTask;
  @Prop current: boolean = false;
  onOpen: () => void = () => {};
  onOpenOnline: () => void = () => {};
  onCopyPath: () => void = () => {};
  onVisitUp: () => void = () => {};
  onRemove: () => void = () => {};
  @State menuShown: boolean = false;

  @Builder
  MenuRow(icon: Resource, label: string) {
    Row({ space: 8 }) {
      Image(icon).width(16).height(16).fillColor($r('app.color.text_secondary'))
      Text(label).fontSize(13).fontColor($r('app.color.text_primary')).maxLines(1)
    }
    .width('100%').height(45).padding({ left: 8, right: 8 })
  }

  @Builder
  MenuPanel() {
    Menu() {
      MenuItem(this.MenuRow($r('app.media.icon_play'), '查看详情页'))
        .onClick(() => { this.menuShown = false; this.onOpenOnline(); })
      MenuItem(this.MenuRow($r('app.media.icon_copy'), '复制缓存路径'))
        .onClick(() => { this.menuShown = false; this.onCopyPath(); })
      MenuItem(this.MenuRow($r('app.media.icon_person'), '访问 UP 主'))
        .enabled(this.task.upMid > 0 || this.task.upName.length > 0)
        .onClick(() => { this.menuShown = false; this.onVisitUp(); })
      MenuItem(this.MenuRow($r('app.media.icon_delete_all'), '删除缓存'))
        .onClick(() => { this.menuShown = false; this.onRemove(); })
    }.width(192)
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.TopEnd }) {
          AsyncImage({ src: this.task.cover, w: 320, h: 200 })
          Text(qualityLabel(this.task.quality)).fontSize(10).fontColor(Color.White)
            .backgroundColor('#80000000').borderRadius(4).padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ top: 6, right: 6 })
          Text(formatDuration(this.task.duration)).fontSize(10).fontColor(Color.White)
            .backgroundColor('#80000000').borderRadius(4).padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .position({ right: 6, bottom: 6 })
        }
        .width(160).height(100).borderRadius(6).clip(true).backgroundColor($r('app.color.btn_soft_bg'))

        Column({ space: 5 }) {
          Text(this.task.title).fontSize(14).lineHeight(19.88).letterSpacing(0.3)
            .fontColor(this.current ? $r('app.color.brand_pink') : $r('app.color.text_primary'))
            .fontWeight(this.current ? FontWeight.Medium : FontWeight.Normal)
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.task.part.length > 0 && this.task.part !== this.task.title) {
            Text(this.task.part).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Blank()
          Text(this.task.upName).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
            .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ right: 30 })
        }
        .layoutWeight(1).height(100).alignItems(HorizontalAlign.Start)
      }
      .width('100%').height(110)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .id('offline_item_' + this.task.cid.toString())
      .onClick(() => { if (!this.current) { this.onOpen(); } })

      Row() {
        Image($r('app.media.icon_more')).width(29).height(29).padding(5.5)
          .fillColor($r('app.color.text_secondary'))
      }
      .width(29)
      .height(29)
      .margin({ right: 12, bottom: 5 })
      .accessibilityText('缓存操作')
      .id('offline_menu_' + this.task.cid.toString())
      .onClick(() => { this.menuShown = !this.menuShown; })
      .bindMenu(this.menuShown, this.MenuPanel(), {
        placement: Placement.TopRight,
        enableArrow: false,
        onDisappear: () => { this.menuShown = false; }
      })
    }
    .width('100%')
    .height(112)
  }
}
