/**
 * 主壳（复刻 Nara 沉浸光感）：
 *  - 底部页签用 ArkUI Tabs + 悬浮样式 + systemMaterial（沉浸式系统材质）
 *  - 内容 barOverlap 从栏下穿过（各列表底部留白 110）
 *  - 首页 / 动态 / 我的 三页由 Tabs 保活
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import { HomeTab } from '../home/HomeTab';
import { DynamicTab } from '../dynamic/DynamicTab';
import { MineTab } from '../mine/MineTab';
import { AuthService } from '../../service/auth_service';
import { onAuthLogout } from '../../infra/event/app_events';
import { prefsGet } from '../../infra/storage/prefs';

/** 材质等级存储键：0=精美 1=轻柔 2=流畅 10=自适应（默认） */
export const MATERIAL_LEVEL_KEY: string = 'setting_material_level';

@Entry
@Component
struct MainShell {
  @State currentIndex: number = 0;
  @State shownTick: number = 0;
  @State pageVisible: boolean = true;
  /** 回首页时让首页滚到顶（系统返回键 / 手势返回触发） */
  @State homeTopTick: number = 0;
  @State materialLevel: number = 10;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private tabsCtrl: HdsTabsController = new HdsTabsController();
  private offAuth: (() => void) | undefined = undefined;
  private firstShow: boolean = true;
  private logoutPending: boolean = false;
  private touchX: number = 0;
  private touchY: number = 0;
  private barsHidden: boolean = false;

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
    // -101 全局登出 → 清失效 Cookie + 回登录页（spec-03 验收 6）
    this.offAuth = onAuthLogout(() => {
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
    this.loadMaterialLevel();
  }

  aboutToDisappear(): void {
    if (this.offAuth !== undefined) {
      this.offAuth();
      this.offAuth = undefined;
    }
  }

  private async loadMaterialLevel(): Promise<void> {
    const raw: string = await prefsGet(MATERIAL_LEVEL_KEY, '10');
    const n: number = parseInt(raw, 10);
    this.materialLevel = isNaN(n) ? 10 : n;
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
    this.loadMaterialLevel();
    if (this.firstShow) {
      this.firstShow = false;
      return;
    }
    this.shownTick++;
  }

  onPageHide(): void { this.pageVisible = false; }

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
    if (this.currentIndex !== 0) {
      this.currentIndex = 0;
      this.homeTopTick++;
      this.onScrollHidden(false);
      return true;
    }
    return false;
  }

  @Builder
  NavItem(label: string, icon: Resource, index: number) {
    Column({ space: 2 }) {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.currentIndex === index ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
      Text(label)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.currentIndex === index ? '#1FFB7299' : Color.Transparent)
    .borderRadius(28)
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
    HdsTabs({ barPosition: BarPosition.End, controller: this.tabsCtrl, index: this.currentIndex }) {
      TabContent() {
        Stack() {
          HomeTab({
            refreshTick: this.shownTick,
            topTick: this.homeTopTick,
            onGoMine: () => {
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
          DynamicTab({ active: this.currentIndex === 1 })
        }
        .width('100%')
        .height('100%')
      }
      .tabBar(this.NavItem('动态', $r('app.media.icon_lightning'), 1))

      TabContent() {
        Stack() {
          MineTab({ refreshTick: this.shownTick, active: this.pageVisible && this.currentIndex === 2 })
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
    .onChange((index: number) => {
      this.currentIndex = index;
      this.onScrollHidden(false);
    })
  }
}
