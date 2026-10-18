/** 启动校验：自动进入主壳/扫码页，网络异常保留重试入口。 */
import { router } from '@kit.ArkUI';
import { AuthService, UserInfo } from '../service/auth_service';
import { AppError } from '../infra/error/app_error';

@Entry
@Component
struct Index {
  @State error: string = '';
  private destroyed: boolean = false;
  private entering: boolean = false;

  aboutToAppear(): void { this.enter(); }
  aboutToDisappear(): void { this.destroyed = true; }

  private async enter(): Promise<void> {
    if (this.entering || this.destroyed) { return; }
    this.entering = true;
    this.error = '';
    try {
      const user: UserInfo | null = await AuthService.fetchNav(true);
      if (this.destroyed) { return; }
      await router.replaceUrl({ url: user !== null ? 'pages/main/MainShell' : 'pages/login/LoginPage' });
    } catch (e) {
      if (this.destroyed) { return; }
      const err: AppError = e as AppError;
      if (err.type === 'auth') {
        try {
          await AuthService.logout();
          if (!this.destroyed) { await router.replaceUrl({ url: 'pages/login/LoginPage' }); }
        } catch (clearError) { this.error = (clearError as Error).message; }
      } else { this.error = '连接失败，请检查网络后重试'; }
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
