/**
 * spec-01 验收页：Cookie 持久化 / 错误模型 / -101 登出事件
 */
import { common } from '@kit.AbilityKit';
import { initPrefs } from '../../infra/storage/prefs';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { apiGet } from '../../infra/http/http';
import { AppError } from '../../infra/error/app_error';
import { onAuthLogout } from '../../infra/event/app_events';
import { API_BASE } from '../../config/constants';

interface NavData {
  isLogin: boolean;
}

@Entry
@Component
struct Spec01 {
  @State logText: string = '';
  @State eventCount: number = 0;
  private offAuth: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.Context;
    initPrefs(ctx).then(() => {
      this.append('[ok] prefs 初始化完成');
      this.refreshCookie('启动时');
    });
    this.offAuth = onAuthLogout(() => {
      this.eventCount = this.eventCount + 1;
      this.append('[event] auth:logout 已触发（累计 ' + this.eventCount + '）');
    });
  }

  aboutToDisappear(): void {
    if (this.offAuth !== undefined) {
      this.offAuth();
      this.offAuth = undefined;
    }
  }

  private append(line: string): void {
    this.logText = this.logText + line + '\n';
  }

  private async refreshCookie(tag: string): Promise<void> {
    const sess: string = await CookieStore.get('SESSDATA');
    const login: boolean = await CookieStore.isLogin();
    this.append('[' + tag + '] Cookie=' + (sess.length > 0 ? '已保存（不显示凭据）' : '（空）') + ' isLogin=' + login);
  }

  private async writeCookie(): Promise<void> {
    await CookieStore.save('SESSDATA=TEST_ABC123; bili_jct=xyz; DedeUserID=42');
    this.append('[ok] 已写入测试 Cookie');
    await this.refreshCookie('写入后');
  }

  private async readCookie(): Promise<void> {
    await this.refreshCookie('读取');
  }

  private async clearCookie(): Promise<void> {
    await CookieStore.clear();
    this.append('[ok] 已清除 Cookie');
    await this.refreshCookie('清除后');
  }

  private async testNav(): Promise<void> {
    this.append('== 调 nav（未登录应返回 -101 → 触发登出事件）');
    try {
      const data = await apiGet<NavData>(API_BASE + '/x/web-interface/nav');
      this.append('[ok] isLogin=' + data.isLogin);
    } catch (e) {
      const err = e as AppError;
      this.append('[err] type=' + err.type + ' code=' + err.code + ' msg=' + err.message);
    }
  }

  build() {
    Column({ space: 8 }) {
      Text('spec-01 验收：Cookie/错误/事件')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16 })

      Flex({ wrap: FlexWrap.Wrap }) {
        Button('写 Cookie')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.writeCookie();
          })
        Button('读 Cookie')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.readCookie();
          })
        Button('清 Cookie')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.clearCookie();
          })
        Button('调 nav（-101）')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.testNav();
          })
        Button('清日志')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.logText = '';
          })
      }
      .width('92%')

      Scroll() {
        Text(this.logText)
          .fontSize(11)
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('92%')
      .backgroundColor('#FAFAFA')
      .borderRadius(8)
      .padding(8)
    }
    .width('100%')
    .height('100%')
  }
}
