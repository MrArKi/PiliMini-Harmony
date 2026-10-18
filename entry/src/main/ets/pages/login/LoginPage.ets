/**
 * 登录页（spec-03）：二维码展示 + 轮询状态机 + 过期自动刷新
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { AuthService, QrGenerateResult, QrPollResult } from '../../service/auth_service';
import { generateQrPixelMap } from '../../infra/qr/qr_generator';

const QR_TTL_SEC: number = 180;

@Entry
@Component
struct LoginPage {
  @State qrPm: image.PixelMap | undefined = undefined;
  @State statusText: string = '正在获取二维码…';
  @State expired: boolean = false;
  @State remainSec: number = QR_TTL_SEC;
  private qrcodeKey: string = '';
  private timer: number = -1;
  private navTimer: number = -1;
  /** 轮询代际：newQr 后丢弃旧二维码的迟到结果 */
  private gen: number = 0;
  private startTs: number = 0;
  private polling: boolean = false;
  private pollBusy: boolean = false;
  private destroyed: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;

  aboutToAppear(): void {
    this.newQr();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.gen++;
    this.polling = false;
    this.stopTimer();
    if (this.navTimer !== -1) {
      clearTimeout(this.navTimer);
      this.navTimer = -1;
    }
  }

  private stopTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /** 登录成功 / 先逛逛：栈内已有主壳则返回（触发主壳刷新），否则替换为主壳 */
  private enterMain(): void {
    let stackSize: number = 1;
    try {
      stackSize = this.getUIContext().getRouter().getStackSize();
    } catch (e) {
      stackSize = 1;
    }
    if (stackSize > 1) {
      router.back();
    } else {
      router.replaceUrl({ url: 'pages/main/MainShell' });
    }
  }

  private async newQr(): Promise<void> {
    if (this.destroyed) { return; }
    this.gen++;
    const myGen: number = this.gen;
    this.polling = false;
    this.stopTimer();
    this.expired = false;
    this.statusText = '正在获取二维码…';
    try {
      const qr: QrGenerateResult = await AuthService.qrcodeGenerate();
      if (myGen !== this.gen) {
        return;
      }
      this.qrcodeKey = qr.qrcodeKey;
      const pm: image.PixelMap | undefined = generateQrPixelMap(qr.url, 240);
      this.qrPm = pm;
      this.startTs = Date.now();
      this.remainSec = QR_TTL_SEC;
      this.statusText = '请使用 B 站 App 扫码';
      this.polling = true;
      this.timer = setInterval(() => {
        this.tick();
      }, 2000);
    } catch (e) {
      if (myGen !== this.gen) {
        return;
      }
      this.statusText = '二维码获取失败，点击重试';
    }
  }

  private tick(): void {
    const elapsed: number = Math.floor((Date.now() - this.startTs) / 1000);
    this.remainSec = Math.max(0, QR_TTL_SEC - elapsed);
    if (this.remainSec <= 0 && !this.expired && this.polling) {
      this.expired = true;
      this.statusText = '二维码已过期，自动刷新中…';
      this.newQr();
      return;
    }
    this.pollOnce();
  }

  private async pollOnce(): Promise<void> {
    if (this.destroyed || this.pollBusy || !this.polling || this.qrcodeKey.length === 0) {
      return;
    }
    const myGen: number = this.gen;
    this.pollBusy = true;
    try {
      const r: QrPollResult = await AuthService.qrcodePoll(this.qrcodeKey,
        (): boolean => !this.destroyed && myGen === this.gen);
      if (myGen !== this.gen) {
        return;
      }
      console.info('[Login] poll code=' + r.code.toString() + ' msg=' + r.message);
      if (r.success) {
        console.info('[Login] 登录成功，Cookie 已落盘');
        this.polling = false;
        this.stopTimer();
        this.statusText = '登录成功，正在进入…';
        if (this.navTimer !== -1) {
          clearTimeout(this.navTimer);
        }
        this.navTimer = setTimeout(() => {
          this.navTimer = -1;
          this.enterMain();
        }, 600);
        return;
      }
      if (r.code === 86090) {
        this.statusText = '已扫码，请在手机上确认';
      } else if (r.code === 86101) {
        this.statusText = '请使用 B 站 App 扫码';
      } else if (r.code === 86038) {
        this.expired = true;
        this.statusText = '二维码已过期，自动刷新中…';
        this.newQr();
      } else {
        this.statusText = '状态码 ' + r.code.toString() + '：' + r.message;
      }
    } catch (e) {
      // 网络抖动，继续轮询
    } finally {
      this.pollBusy = false;
    }
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
    Column({ space: 14 }) {
      Text('扫码登录')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 24 + this.statusBarH })

      Text('使用哔哩哔哩客户端扫码登录')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))

      Stack({ alignContent: Alignment.Center }) {
        Column() {
          if (this.qrPm !== undefined) {
            Image(this.qrPm)
              .width(240)
              .height(240)
              .interpolation(ImageInterpolation.None)
          } else {
            LoadingProgress()
              .width(48)
              .height(48)
              .color($r('app.color.text_secondary'))
          }
        }
        .width(260)
        .height(260)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .justifyContent(FlexAlign.Center)

        if (this.expired) {
          Column({ space: 6 }) {
            Text('二维码已过期')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
            Text('点击刷新')
              .fontSize(12)
              .fontColor('#DDDDDD')
          }
          .width(260)
          .height(260)
          .borderRadius(16)
          .backgroundColor('#CC000000')
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.newQr();
          })
        }
      }
      .onClick(() => {
        if (this.expired) {
          this.newQr();
        }
      })

      Text(this.statusText)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
      Text('有效期剩余 ' + this.remainSec.toString() + ' 秒')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))

      Button('刷新二维码')
        .fontSize(14)
        .width(200)
        .backgroundColor($r('app.color.brand_pink'))
        .onClick(() => {
          this.newQr();
        })

      Text('先逛逛（稍后可登录）')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .decoration({ type: TextDecorationType.Underline, color: $r('app.color.text_secondary') })
        .onClick(() => {
          this.enterMain();
        })

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
