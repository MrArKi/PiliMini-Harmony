/**
 * 主壳（复刻 Nara 沉浸光感）：
 *  - 底部页签用 ArkUI Tabs + 悬浮样式 + systemMaterial（沉浸式系统材质）
 *  - 内容 barOverlap 从栏下穿过（各列表底部留白 110）
 *  - 首页 / 动态 / 我的 三页由 Tabs 保活
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router, curves, window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { FrameCallback } from '@ohos.arkui.UIContext';
import { HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import { HomeTab } from '../home/HomeTab';
import lazy { DynamicTab } from '../dynamic/DynamicTab';
import lazy { MineTab } from '../mine/MineTab';
import { AuthService } from '../../service/auth_service';
import { onAuthLogout, onAppBackground, onAppForeground } from '../../infra/event/app_events';
import { DynamicUnread } from '../../infra/event/dynamic_unread';
import { prefsGet } from '../../infra/storage/prefs';
import { FeedNavRequest } from '../../common/feed_navigation';
import { HeroRoute, HeroRect, VideoNavParam } from '../../common/hero_route';
import lazy { VideoDetailView } from '../../components/video/VideoDetailView';
import { VideoDetailHandle } from '../../components/video/video_detail_handle';
import { MATERIAL_LEVEL_KEY } from '../../config/ui_preferences';
import { markStartup } from '../../infra/startup_trace';

/** 与已验收图片查看器一致：双向300ms，官方属性动画同步图片与裁剪窗。 */
const HERO_DURATION: number = 300;
const HERO_CURVE: ICurve = curves.cubicBezierCurve(0, 0, 0.58, 1);

class HeroPixels {
  serial: number;
  pixel: image.PixelMap;
  constructor(serial: number, pixel: image.PixelMap) { this.serial = serial; this.pixel = pixel; }
}

class HeroFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  // onFrame在开始绘制时回调；盖板完成绘制后才允许关闭Surface输出。
  onIdle(_time: number): void { this.action(); this.action = () => {}; }
}

@Entry
@Component
struct MainShell {
  @State currentIndex: number = 0;
  @State dynamicVisited: boolean = false;
  @State mineVisited: boolean = false;
  @State shownTick: number = 0;
  @State pageVisible: boolean = true;
  /** 回首页时让首页滚到顶（系统返回键 / 手势返回触发） */
  @State homeTopTick: number = 0;
  @State homeNavRequest: FeedNavRequest = new FeedNavRequest();
  @State dynamicNavRequest: FeedNavRequest = new FeedNavRequest();
  @State materialLevel: number = 10;
  @StorageProp('dynamicUnreadCount') dynamicUnreadCount: number = 0;
  @State appForeground: boolean = true;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private tabsCtrl: HdsTabsController = new HdsTabsController();
  /** 首页→详情的独立导航栈：只有走这条栈才有共享元素转场（spec-33） */
  private navStack: NavPathStack = new NavPathStack();
  private detailHandle: VideoDetailHandle = new VideoDetailHandle();
  /** 目标页入参：builder 的 param 是 object，避免强转，用字段传 */
  private pendingNav: VideoNavParam = new VideoNavParam('', 0, '');
  @State detailShown: boolean = false;
  @State shellW: number = 360;
  @State shellH: number = 780;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  private flightMap: image.PixelMap | undefined = undefined;
  @State flightImages: HeroPixels[] = [];
  private sharedId: string = '';
  private targetRect: HeroRect = new HeroRect();
  @State pictureRect: HeroRect = new HeroRect();
  @State flightRadius: number = 0;
  private heroProxy: NavigationTransitionProxy | undefined = undefined;
  private transitionStarted: boolean = false;
  private entryDeadline: number = 0;
  private pixelSerial: number = 0;
  private paintResolve: (() => void) | undefined = undefined;
  @State flightRect: HeroRect = new HeroRect();
  @State coverOpacity: number = 1;
  @State contentOpacity: number = 1;
  @State exitPreparing: boolean = false;
  @State heroMoving: boolean = false;
  @State heroBusy: boolean = false;
  private heroReturning: boolean = false;
  private heroGeneration: number = 0;
  private detailSession: number = 0;
  private sourceW: number = 0;
  private sourceH: number = 0;
  private hostX: number = 0;
  private hostY: number = 0;
  private bootQueued: boolean = false;
  private entrySettled: boolean = false;
  private outputReady: boolean = false;
  private coverDisplayed: boolean = false;
  private exitCleanupTimer: number = -1;
  private offAuth: (() => void) | undefined = undefined;
  private offBackground: (() => void) | undefined = undefined;
  private offForeground: (() => void) | undefined = undefined;
  private unreadTimer: number = -1;
  private destroyed: boolean = false;
  private firstShow: boolean = true;
  private logoutPending: boolean = false;
  private touchX: number = 0;
  private touchY: number = 0;
  private barsHidden: boolean = false;
  private lastReselectIndex: number = -1;
  private lastReselectAt: number = 0;

  private onNavClick(index: number): void {
    this.markTabVisited(index);
    if (index === this.currentIndex && (index === 0 || index === 1)) {
      const now: number = Date.now();
      const doubleTap: boolean = this.lastReselectIndex === index && now - this.lastReselectAt < 500;
      this.lastReselectIndex = index;
      this.lastReselectAt = now;
      if (index === 0) {
        this.homeNavRequest = new FeedNavRequest(this.homeNavRequest.serial + 1, doubleTap);
      } else {
        this.dynamicNavRequest = new FeedNavRequest(this.dynamicNavRequest.serial + 1, doubleTap);
      }
    } else {
      this.lastReselectIndex = -1;
      if (index === 1) { DynamicUnread.dismissBadge(); }
      this.currentIndex = index;
    }
    this.updateUnreadSchedule();
    this.onScrollHidden(false);
  }

  private markTabVisited(index: number): void {
    if (index === 1) { this.dynamicVisited = true; }
    if (index === 2) { this.mineVisited = true; }
  }

  /** 主壳统一观察手指方向；短列表/空态也能呼回底栏，不抢子组件滚动手势。 */
  private onShellTouch(event: TouchEvent): void {
    if (event.touches.length !== 1) { return; }
    const point: TouchObject = event.touches[0];
    if (event.type === TouchType.Down) {
      this.touchX = point.screenX; this.touchY = point.screenY;
    } else if (event.type === TouchType.Move) {
      const dy: number = point.screenY - this.touchY;
      const dx: number = point.screenX - this.touchX;
      if (Math.abs(dy) > 30 && Math.abs(dy) > Math.abs(dx) * 1.2) {
        this.onScrollHidden(dy < 0);
        this.touchX = point.screenX; this.touchY = point.screenY;
      }
    }
  }

  aboutToAppear(): void {
    markStartup('mainShellAppear');
    DynamicUnread.reset();
    // -101 全局登出 → 清失效 Cookie + 回登录页（spec-03 验收 6）
    this.offAuth = onAuthLogout(() => {
      DynamicUnread.reset();
      // 已在登录页：并发 -101 去重
      if (this.logoutPending || router.getState().path === 'pages/login/LoginPage') {
        return;
      }
      this.logoutPending = true;
      AuthService.logout().then(() => {
        router.replaceUrl({ url: 'pages/login/LoginPage' }).then(() => {
          // 清空栈内历史页，避免返回键回到失效会话
          router.clear();
        }).catch(() => {
        });
      }).catch(() => {
        this.logoutPending = false;
      });
    });
    this.offBackground = onAppBackground(() => {
      this.appForeground = false;
      this.stopUnreadSchedule();
    });
    this.offForeground = onAppForeground(() => {
      this.appForeground = true;
      this.updateUnreadSchedule();
    });
    this.loadMaterialLevel();
    this.updateUnreadSchedule();
    // 当前封面由组件实例注册；返回不以BV重找其它卡片。
    HeroRoute.updateRect = (): void => {};
    HeroRoute.push = (param: VideoNavParam): boolean => this.openVideo(param);
    this.detailHandle.prepareExit = (): Promise<void> => this.freezeVideoPage();
    this.detailHandle.cancelExit = (): void => {
      this.heroGeneration++;
      this.heroBusy = false; this.exitPreparing = false; this.heroMoving = false;
      this.contentOpacity = 1;
      this.coverOpacity = this.outputReady ? 0 : 1;
    };
    this.detailHandle.onVisualUnavailable = (): void => {
      if (!this.exitPreparing) { this.coverOpacity = 0; }
    };
    this.detailHandle.onVisualReady = (): void => {
      this.outputReady = true;
      this.revealVideo();
    };
    this.detailHandle.onVisualRect = (rect: HeroRect): void => {
      if (!this.exitPreparing && !this.heroReturning && this.coverOpacity > 0 && rect.w > 0 && rect.h > 0) {
        this.targetRect = this.localRect(rect);
        if (!this.heroBusy) { this.flightGeometry(this.targetRect, false); }
        else if (this.transitionStarted && !this.heroReturning) {
          // 轻量分P尺寸中途到达时重定向正在运行的官方属性动画，终点不再瞬跳。
          this.getUIContext().animateTo({ duration: Math.max(1, this.entryDeadline - Date.now()), curve: HERO_CURVE },
            (): void => { this.flightGeometry(this.targetRect, false); });
        }
      }
    };
    this.detailHandle.exit = (_toHome: boolean): void => this.closeVideo();
  }

  private mountRoot(): void {
    if (this.bootQueued) { return; }
    this.bootQueued = true;
    this.getUIContext().postFrameCallback(new HeroFrame((): void => {
      if (!this.destroyed && this.navStack.size() === 0) {
        this.navStack.pushPath({ name: 'home' }, false);
      }
    }));
  }

  private localRect(rect: HeroRect): HeroRect {
    return new HeroRect(rect.x - this.hostX, rect.y - this.hostY, rect.w, rect.h);
  }

  private openVideo(param: VideoNavParam): boolean {
    if (this.destroyed || this.heroBusy || this.detailShown || this.navStack.size() !== 1) { return true; }
    this.pendingNav = param;
    this.detailSession++;
    this.sourceW = this.shellW; this.sourceH = this.shellH;
    this.heroBusy = true; this.heroReturning = false; this.heroMoving = true;
    this.entrySettled = false; this.outputReady = false; this.coverDisplayed = false;
    this.setFlightMap(param.pixelMap);
    this.sharedId = param.pixelMap === undefined ? '' : 'video_cover_' + param.sourceId;
    this.targetRect = new HeroRect(0, this.statusBarH, this.shellW, this.shellW * 9 / 16);
    this.flightGeometry(param.rect.w > 0 ? this.localRect(param.rect) : this.targetRect, true);
    this.flightRadius = param.rect.w > 0 ? 12 : 0;
    this.transitionStarted = false;
    this.coverOpacity = 1; this.contentOpacity = 0; this.exitPreparing = false;
    this.heroGeneration++;
    this.detailShown = true;
    try { this.navStack.pushPath({ name: 'video', param: param.bvid }); }
    catch (_) { this.finishHero(this.heroGeneration); }
    this.updateUnreadSchedule();
    return true;
  }

  /** VO配置并非像素上屏证明；等封面也完成绘制，再在绘制后的回调中交接。 */
  private revealVideo(): void {
    if (!this.entrySettled || !this.outputReady || !this.coverDisplayed || this.exitPreparing || this.destroyed) { return; }
    const generation: number = this.heroGeneration;
    this.getUIContext().postFrameCallback(new HeroFrame((): void => {
      if (this.destroyed || generation !== this.heroGeneration || this.exitPreparing) { return; }
      this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseOut }, (): void => { this.coverOpacity = 0; });
    }));
  }

  private closeVideo(): void {
    if (this.destroyed || this.heroReturning || this.navStack.size() <= 1) { return; }
    this.heroReturning = true; this.heroBusy = true;
    this.heroGeneration++; this.transitionStarted = false;
    try { this.navStack.pop(); }
    catch (_) { this.heroReturning = false; this.heroBusy = false; throw new Error('视频导航返回失败'); }
  }

  /** 外裁剪框与内部等比图像独立插值，和动态大图同一计算方式。 */
  private flightGeometry(rect: HeroRect, cover: boolean): void {
    let ratio: number = rect.w / Math.max(1, rect.h);
    if (this.flightMap !== undefined) {
      const info: image.ImageInfo = this.flightMap.getImageInfoSync();
      ratio = info.size.width / Math.max(1, info.size.height);
    }
    const width: number = cover ? Math.max(rect.w, rect.h * ratio) : Math.min(rect.w, rect.h * ratio);
    const height: number = width / Math.max(0.0001, ratio);
    this.flightRect = rect;
    this.pictureRect = new HeroRect((rect.w - width) / 2, (rect.h - height) / 2, width, height);
  }

  private startHero(): void {
    const proxy: NavigationTransitionProxy | undefined = this.heroProxy;
    if (proxy === undefined || this.transitionStarted || this.destroyed ||
      (!this.heroReturning && this.flightMap !== undefined && !this.coverDisplayed)) { return; }
    this.transitionStarted = true;
    this.heroMoving = true;
    this.entryDeadline = Date.now() + HERO_DURATION;
    const generation: number = this.heroGeneration;
    const source: HeroRect = this.localRect(HeroRoute.sourceRect(this.pendingNav.sourceId));
    HeroRoute.hideSource(this.pendingNav.sourceId, true);
    this.detailHandle.routeEntry(0.5);
    this.getUIContext().animateTo({ duration: HERO_DURATION, curve: HERO_CURVE,
      onFinish: (): void => {
        if (this.destroyed || generation !== this.heroGeneration) { return; }
        proxy.finishTransition();
        this.finishHero(generation);
      }
    }, (): void => {
      this.contentOpacity = this.heroReturning ? 0 : 1;
      if (this.heroReturning) {
        if (this.sharedId.length > 0 && source.w > 0) { this.flightGeometry(source, true); this.flightRadius = 12; }
        else { this.coverOpacity = 0; }
      } else {
        this.flightGeometry(this.targetRect, false); this.flightRadius = 0;
      }
    });
  }

  private finishHero(generation: number): void {
    if (this.destroyed || generation !== this.heroGeneration) { return; }
    this.heroGeneration++;
    this.heroProxy = undefined;
    // 原生已经完整关闭；导航中断时也不能留下失效的详情树。
    if (this.heroReturning && this.navStack.size() > 1) { this.navStack.pop(false); }
    this.heroBusy = false; this.heroReturning = false; this.exitPreparing = false; this.heroMoving = false;
    this.detailShown = this.navStack.size() > 1;
    this.contentOpacity = this.detailShown ? 1 : 0;
    this.flightRadius = this.detailShown ? 0 : 12;
    HeroRoute.hideSource(this.pendingNav.sourceId, false);
    if (this.detailShown) {
      this.entrySettled = true;
      this.detailHandle.routeEntry(1);
      HeroRoute.clearSourceFrame();
      this.flightGeometry(this.targetRect, false);
      this.revealVideo();
      console.info('[VideoHero] push=finished officialProperties=1');
    } else {
      // 当前视频帧只属于回程；首页落位后立即恢复该卡的原封面。
      HeroRoute.clearSourceFrame();
      AppStorage.setOrCreate<boolean>('navVideoDetailVisible', false);
      this.clearExitImages(this.detailSession);
      console.info('[VideoHero] pop=finished');
    }
    this.updateUnreadSchedule();
  }

  private clearExitImages(session: number): void {
    if (session !== this.detailSession || this.navStack.size() > 1 || this.heroReturning) { return; }
    const generation: number = this.heroGeneration;
    const clear = (): void => {
      if (session !== this.detailSession || generation !== this.heroGeneration || this.detailShown) { return; }
      if (this.exitCleanupTimer !== -1) { clearTimeout(this.exitCleanupTimer); this.exitCleanupTimer = -1; }
      this.setFlightMap(undefined);
      this.pendingNav.pixelMap = undefined;
    };
    if (this.exitCleanupTimer !== -1) { clearTimeout(this.exitCleanupTimer); }
    this.exitCleanupTimer = setTimeout(clear, 250);
    try { this.getUIContext().postFrameCallback(new HeroFrame(clear)); } catch (_) { /* timer清理 */ }
  }

  /** 官方窗口快照含SURFACE；仅截可见播放器，盖层出图后才关闭原生。 */
  private async freezeVideoPage(): Promise<void> {
    if (this.destroyed || !this.detailShown) { return; }
    this.heroBusy = true; this.exitPreparing = true;
    const generation: number = ++this.heroGeneration;
    // 上轮/入场像素不能充当本轮返回快照；先撤飞行层，再截仍在输出的唯一Surface。
    this.coverOpacity = 0;
    this.setFlightMap(undefined);
    const source: HeroRect = HeroRoute.sourceRect(this.pendingNav.sourceId);
    if (Math.abs(this.sourceW - this.shellW) > 1 || Math.abs(this.sourceH - this.shellH) > 1 ||
      source.w <= 0 || source.h <= 0 || source.y + source.h <= 0 || source.y >= this.shellH) { this.sharedId = ''; }
    try {
      await this.waitPaint(false);
      if (this.destroyed || generation !== this.heroGeneration) { return; }
      const current: HeroRect = this.detailHandle.visualRect();
      if (current.w <= 0 || current.h <= 0) { throw new Error('播放器当前矩形不可用'); }
      this.targetRect = this.localRect(current);
      if (!await this.captureExitFrame(current, generation)) { this.sharedId = ''; }
    } catch (_) {
      // 本轮没有新像素就淡出，不把历史暂停帧或封面冒充当前视频帧。
      if (!this.destroyed && generation === this.heroGeneration) { this.sharedId = ''; }
    }
    if (this.destroyed || generation !== this.heroGeneration) { return; }
    this.coverOpacity = 1;
    if (this.flightMap === undefined) {
      this.sharedId = ''; this.contentOpacity = 0;
      await this.waitPaint(false);
    } else {
      try { await this.waitPaint(true); }
      catch (_) {
        // 无可显示快照时先隐藏详情，再安全释放，不能把超时当作已绘制。
        this.sharedId = ''; this.coverOpacity = 0; this.contentOpacity = 0;
        await this.waitPaint(false);
      }
    }
    if (generation !== this.heroGeneration || this.destroyed) { throw new Error('返回已取消'); }
    if (this.sharedId.length > 0 && this.flightMap !== undefined &&
      !HeroRoute.setSourceFrame(this.pendingNav.sourceId, this.flightMap)) { this.sharedId = ''; }
  }

  /** 超时只降级淡出；迟到快照始终释放，不得覆盖已返回或新详情的像素。 */
  private captureExitFrame(rect: HeroRect, generation: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (captured: boolean) => void): void => {
      let finished: boolean = false;
      const finish = (captured: boolean): void => {
        if (finished) { return; }
        finished = true; clearTimeout(timer); resolve(captured);
      };
      const timer: number = setTimeout((): void => finish(false), 1200);
      window.getLastWindow(getContext(this)).then(async (win: window.Window): Promise<void> => {
        if (finished || this.destroyed || generation !== this.heroGeneration) { return; }
        const snapshot: image.PixelMap = await win.snapshot();
        let retained: boolean = false;
        try {
          if (finished || this.destroyed || generation !== this.heroGeneration) { return; }
          const info: image.ImageInfo = await snapshot.getImageInfo();
          const x: number = Math.max(0, Math.round(vp2px(rect.x)));
          const y: number = Math.max(0, Math.round(vp2px(rect.y)));
          const width: number = Math.min(info.size.width - x, Math.round(vp2px(rect.w)));
          const height: number = Math.min(info.size.height - y, Math.round(vp2px(rect.h)));
          if (width < 1 || height < 1) { return; }
          await snapshot.crop({ x: x, y: y, size: { width: width, height: height } });
          const ratio: number = Math.min(1, 1400 / Math.max(width, height));
          if (ratio < 1) { await snapshot.scale(ratio, ratio); }
          if (finished || this.destroyed || generation !== this.heroGeneration) { return; }
          this.setFlightMap(snapshot); this.flightGeometry(this.targetRect, false); retained = true;
          console.info('[VideoExit] playerFrameReady=1');
          finish(true);
        } finally { if (!retained) { snapshot.release().catch((): void => {}); } }
      }).catch((): void => {}).finally((): void => finish(false));
    });
  }

  private setFlightMap(pixel: image.PixelMap | undefined): void {
    this.flightMap = pixel; this.coverDisplayed = false;
    this.pixelSerial++;
    this.flightImages = pixel === undefined ? [] : [new HeroPixels(this.pixelSerial, pixel)];
  }

  private onCoverDisplayed(serial: number): void {
    if (serial !== this.pixelSerial || this.destroyed) { return; }
    this.coverDisplayed = true;
    if (this.paintResolve !== undefined) { this.paintResolve(); }
    this.revealVideo();
    this.startHero();
  }

  private waitPaint(requireImage: boolean): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      let finished: boolean = false;
      let queued: boolean = false;
      const finish = (success: boolean): void => {
        if (finished) { return; }
        finished = true; clearTimeout(timer); this.paintResolve = undefined;
        if (success) { resolve(); } else { reject(new Error('返回盖层未完成绘制')); }
      };
      const timer: number = setTimeout((): void => finish(false), 200);
      const enqueue = (): void => {
        if (queued || finished || (requireImage && !this.coverDisplayed)) { return; }
        queued = true;
        try { this.getUIContext().postFrameCallback(new HeroFrame((): void => finish(true))); }
        catch (_) { finish(false); }
      };
      this.paintResolve = enqueue;
      enqueue();
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    HeroRoute.push = (): boolean => false;
    HeroRoute.updateRect = (): void => {};
    this.heroGeneration++;
    if (this.exitCleanupTimer !== -1) { clearTimeout(this.exitCleanupTimer); this.exitCleanupTimer = -1; }
    if (this.heroProxy !== undefined) { this.heroProxy.finishTransition(); this.heroProxy = undefined; }
    this.setFlightMap(undefined);
    HeroRoute.hideSource(this.pendingNav.sourceId, false);
    HeroRoute.clearSourceFrame();
    AppStorage.setOrCreate<boolean>('navVideoDetailVisible', false);
    this.stopUnreadSchedule();
    if (this.offBackground) { this.offBackground(); this.offBackground = undefined; }
    if (this.offForeground) { this.offForeground(); this.offForeground = undefined; }
    if (this.offAuth !== undefined) {
      this.offAuth();
      this.offAuth = undefined;
    }
  }

  private async loadMaterialLevel(): Promise<void> {
    try {
      const raw: string = await prefsGet(MATERIAL_LEVEL_KEY, '10');
      if (this.destroyed) { return; }
      const n: number = parseInt(raw, 10);
      this.materialLevel = isNaN(n) ? 10 : n;
    } catch (_) { /* 本地偏好暂时不可用时保留官方自适应默认值。 */ }
  }

  /** 档位 → hdsMaterial.MaterialLevel（0 精美 / 1 轻柔 / 2 流畅 / 10 自适应，非法回退自适应） */
  private materialLevelEnum(): hdsMaterial.MaterialLevel {
    if (this.materialLevel === 0) {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (this.materialLevel === 1) {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (this.materialLevel === 2) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  /** 从其它页面返回主壳时刷新「首页头像 / 我的 / 材质档位」 */
  onPageShow(): void {
    this.pageVisible = true;
    if (this.detailShown) { this.detailHandle.show(); }
    this.loadMaterialLevel();
    this.updateUnreadSchedule();
    if (this.firstShow) {
      this.firstShow = false;
      return;
    }
    this.shownTick++;
  }

  onPageHide(): void {
    this.pageVisible = false;
    if (this.detailShown) { this.detailHandle.hide(); }
    this.stopUnreadSchedule();
  }

  private stopUnreadSchedule(): void {
    if (this.unreadTimer >= 0) { clearTimeout(this.unreadTimer); this.unreadTimer = -1; }
    DynamicUnread.cancel();
  }

  /** Nara 默认五分钟；只在主壳前台且不在动态页时工作。 */
  private updateUnreadSchedule(): void {
    if (this.destroyed || !this.pageVisible || !this.appForeground || this.detailShown || this.currentIndex === 1) {
      this.stopUnreadSchedule(); return;
    }
    // aboutToAppear/onPageShow、导航点击/onChange 成对出现，复用同一前台周期。
    if (this.unreadTimer >= 0) { return; }
    DynamicUnread.refresh();
    this.unreadTimer = setTimeout(() => {
      this.unreadTimer = -1;
      this.updateUnreadSchedule();
    }, 5 * 60 * 1000);
  }

  /** 列表下滑：底栏动画隐藏（Nara：HdsTabsController.applyHideAnimation(SCROLL_ANIMATION)） */
  private onScrollHidden(hidden: boolean): void {
    if (this.barsHidden === hidden) { return; }
    try {
      if (hidden) {
        this.tabsCtrl.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION);
      } else {
        this.tabsCtrl.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
      }
      this.barsHidden = hidden;
    } catch (e) {
      // HDS 动画失败不影响功能
    }
  }

  /** 系统返回 / 手势返回：在动态或我的页 → 回首页（并滚到顶） */
  onBackPress(): boolean {
    if (this.detailShown || this.navStack.size() > 1) {
      if (!this.heroBusy) { this.detailHandle.back(); }
      return true;
    }
    if (this.currentIndex !== 0) {
      this.currentIndex = 0;
      this.updateUnreadSchedule();
      this.homeTopTick++;
      this.onScrollHidden(false);
      return true;
    }
    return false;
  }

  @Builder
  NavItem(label: string, icon: Resource, index: number) {
    Column({ space: 2 }) {
      if (index === 1 && this.dynamicUnreadCount > 0) {
        Badge({ count: this.dynamicUnreadCount, maxCount: 99, position: BadgePosition.RightTop,
          style: { badgeSize: 13, fontSize: 8, fontWeight: FontWeight.Medium,
            badgeColor: $r('app.color.brand_pink'), color: '#FFFFFF', borderColor: '#FFFFFF' } }) {
          Image(icon).width(24).height(24)
            .fillColor(this.currentIndex === index ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
        }
      } else {
        Image(icon).width(24).height(24)
          .fillColor(this.currentIndex === index ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
      }
      Text(label)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.currentIndex === index ? '#1FFB7299' : Color.Transparent)
    .borderRadius(28)
    .id('main_nav_' + index.toString())
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

  @Builder
  HomeContent() {
    HdsTabs({ barPosition: BarPosition.End, controller: this.tabsCtrl, index: this.currentIndex }) {
      TabContent() {
        Stack() {
          HomeTab({
            active: this.pageVisible && !this.detailShown && this.currentIndex === 0,
            refreshTick: this.shownTick,
            topTick: this.homeTopTick,
            navRequest: this.homeNavRequest,
            onGoMine: () => {
              this.markTabVisited(2);
              this.currentIndex = 2;
              this.onScrollHidden(false);
            }
          })
        }
        .width('100%')
        .height('100%')
      }
      .tabBar(this.NavItem('首页', $r('app.media.icon_home'), 0))

      TabContent() {
        Stack() {
          if (this.dynamicVisited) {
            DynamicTab({ active: this.pageVisible && !this.detailShown && this.appForeground && this.currentIndex === 1,
              navRequest: this.dynamicNavRequest })
          }
        }
        .width('100%')
        .height('100%')
      }
      .tabBar(this.NavItem('动态', $r('app.media.icon_lightning'), 1))

      TabContent() {
        Stack() {
          if (this.mineVisited) {
            MineTab({ refreshTick: this.shownTick, active: this.pageVisible && !this.detailShown && this.currentIndex === 2 })
          }
        }
        .width('100%')
        .height('100%')
      }
      .tabBar(this.NavItem('我的', $r('app.media.icon_person'), 2))
    }
    .barMode(BarMode.Fixed)
    .barOverlap(true)
    .barHeight(56)
    .barFloatingStyle({
      barBottomMargin: 8 + this.navBarH,
      // 官方 HDS 沉浸光感：materialType IMMERSIVE + 设置页四档（精美/轻柔/流畅/自适应）
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: this.materialLevelEnum()
      } as SystemMaterialParams
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .onTouch((event: TouchEvent) => { this.onShellTouch(event); })
    .onTabBarClick((index: number): void => { this.onNavClick(index); })
    .onChange((index: number) => {
      this.markTabVisited(index);
      if (index === 1 && index !== this.currentIndex) { DynamicUnread.dismissBadge(); }
      this.currentIndex = index;
      this.updateUnreadSchedule();
      this.onScrollHidden(false);
    })
  }

  @Builder
  VideoContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      VideoDetailView({
        handle: this.detailHandle,
        inputBvid: this.pendingNav.bvid,
        inputCid: this.pendingNav.cid,
        inputTitle: this.pendingNav.title,
        inputCover: this.pendingNav.cover,
        inputNavigation: true,
        inputHeroMoving: this.heroMoving,
        inputRouteSession: this.detailSession,
        onDisposed: (session: number): void => { this.clearExitImages(session); }
      })
        .width('100%').height('100%').opacity(this.contentOpacity)
        .transition(TransitionEffect.OPACITY).enabled(!this.exitPreparing && !this.heroBusy)
      if (this.flightImages.length > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach(this.flightImages, (frame: HeroPixels) => {
            Image(frame.pixel).width(this.pictureRect.w).height(this.pictureRect.h).objectFit(ImageFit.Fill)
              .position({ x: this.pictureRect.x, y: this.pictureRect.y })
              .autoResize(false).syncLoad(true).draggable(false)
              .onComplete((event): void => {
                if (event !== undefined && event.loadingStatus === 1) { this.onCoverDisplayed(frame.serial); }
              })
          }, (frame: HeroPixels) => frame.serial.toString())
        }
        .width(this.flightRect.w).height(this.flightRect.h)
        .position({ x: this.flightRect.x, y: this.flightRect.y })
        .borderRadius(this.flightRadius).clip(true).backgroundColor(Color.Black)
        .opacity(this.coverOpacity)
        .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS).id('video_hero_frame')
      }
    }
    .width('100%').height('100%')
    .transition(TransitionEffect.opacity(1))
  }

  @Builder
  Destination(name: string, _param: object) {
    if (name === 'home') {
      NavDestination() { this.HomeContent() }
        .hideTitleBar(true).systemTransition(NavigationSystemTransitionType.NONE)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else {
      NavDestination() { this.VideoContent() }
        .hideTitleBar(true).backgroundColor(Color.Transparent)
        .systemTransition(NavigationSystemTransitionType.NONE)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .onShown((): void => { this.detailHandle.show(); this.detailHandle.routeEntry(0.5); })
        .onHidden((reason: VisibilityChangeReason): void => {
          this.detailHandle.hide(reason !== VisibilityChangeReason.APP_STATE);
        })
        .onBackPressed((): boolean => { if (!this.heroBusy) { this.detailHandle.back(); } return true; })
    }
  }

  build() {
    Navigation(this.navStack) {}
      .navDestination(this.Destination)
      .customNavContentTransition((from: NavContentInfo, to: NavContentInfo, _operation: NavigationOperation):
        NavigationAnimatedTransition | undefined => {
        if (from.name !== 'video' && to.name !== 'video') { return undefined; }
        const generation: number = this.heroGeneration;
        return { timeout: 1800,
          onTransitionEnd: (_success: boolean): void => { this.finishHero(generation); },
          transition: (proxy: NavigationTransitionProxy): void => { this.heroProxy = proxy; this.startHero(); }
        };
      })
      .mode(NavigationMode.Stack).hideNavBar(true).hideTitleBar(true).hideToolBar(true)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .width('100%').height('100%')
      .onAppear((): void => { this.mountRoot(); })
      .onAreaChange((_old: Area, area: Area): void => {
        this.hostX = Number(area.globalPosition.x); this.hostY = Number(area.globalPosition.y);
        this.shellW = Number(area.width); this.shellH = Number(area.height);
      })
  }
}
