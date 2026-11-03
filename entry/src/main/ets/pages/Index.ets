/**
 * 启动分流：只读本地登录态，不联网。
 *  - 旧实现 await /x/web-interface/nav 才进主壳，弱网/接口抖动时冷启动被整个网络往返拖住。
 *  - 现在：有 SESSDATA → 直接进主壳（头像/昵称由主壳后台补），无 → 登录页。
 *  - Cookie 失效由 http 层 -101 全局登出兜底（MainShell 已监听）。
 */
import { router } from '@kit.ArkUI';
import { CookieStore } from '../infra/cookie/cookie_store';
import { markStartup } from '../infra/startup_trace';

@Entry
@Component
struct Index {
  @State error: string = '';
  private destroyed: boolean = false;
  private entering: boolean = false;

  aboutToAppear(): void { markStartup('indexAppear'); this.enter(); }
  aboutToDisappear(): void { this.destroyed = true; }

  private async enter(): Promise<void> {
    if (this.entering || this.destroyed) { return; }
    this.entering = true;
    this.error = '';
    try {
      const logged: boolean = await CookieStore.isLogin();
      markStartup('localSessionReady');
      if (this.destroyed) { return; }
      await router.replaceUrl({ url: logged ? 'pages/main/MainShell' : 'pages/login/LoginPage' });
      markStartup('indexRouted');
    } catch (e) {
      markStartup('indexRouteFailed');
      if (!this.destroyed) { this.error = '启动失败，请重试'; }
    } finally { this.entering = false; }
  }

  build() {
    Column({ space: 18 }) {
      if (this.error.length > 0) {
        Text(this.error).fontSize(14).fontColor($r('app.color.text_secondary'))
        Button('重试').fontSize(14).backgroundColor($r('app.color.brand_pink'))
          .onClick(() => { this.enter(); })
      } else {
        LoadingProgress().width(36).height(36).color($r('app.color.brand_pink'))
      }
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }
}
