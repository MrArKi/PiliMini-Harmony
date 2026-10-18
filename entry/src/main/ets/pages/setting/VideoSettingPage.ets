/**
 * 音视频设置（设置路径对齐 PiliNara：设置 → 音视频设置）
 *  - 开启硬解（libmpv自动选择可用硬解；保留用户已有设置）
 *  - 免登录1080P（默认开；playurl 附加 try_look=1）
 *  - 默认清晰度（播放/下载初始 qn）
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router } from '@kit.ArkUI';
import { prefsGet, prefsPut } from '../../infra/storage/prefs';
import { VideoQuality, QualityEntry } from '../../model/video_quality';

const KEY_HA: string = 'setting_enable_ha';
const KEY_P1080: string = 'setting_p1080';
const KEY_QN: string = 'setting_default_qn';

@Entry
@Component
struct VideoSettingPage {
  @State haOn: boolean = true;
  @State p1080On: boolean = true;
  @State qnLabel: string = '1080P';
  @State qn: number = 80;
  @State qnSheet: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;

  // Nara 全表（高 → 低，Bug1：原仅到 1080P）
  private qnOptions: QualityEntry[] = VideoQuality.all();

  aboutToAppear(): void {
    this.init();
  }

  private async init(): Promise<void> {
    try {
      const ha: string = await prefsGet(KEY_HA, '1');
      this.haOn = ha !== '0';
      const p1080: string = await prefsGet(KEY_P1080, '1');
      this.p1080On = p1080 !== '0';
      const qnStr: string = await prefsGet(KEY_QN, '80');
      const qn: number = parseInt(qnStr, 10);
      this.qn = isNaN(qn) ? 80 : qn;
      this.qnLabel = VideoQuality.shortLabel(this.qn);
    } catch (e) {
      // 读取失败用默认值
    }
  }

  private async pickQn(o: QualityEntry): Promise<void> {
    this.qn = o.qn;
    this.qnLabel = o.shortDesc;
    this.qnSheet = false;
    await prefsPut(KEY_QN, o.qn.toString());
  }

  /** 开关行（标题 + 说明 + Switch）；isOn 用闭包按引用取值（@Builder 按值传参不刷新） */
  @Builder
  SwitchRow(title: string, subtitle: string, isOn: () => boolean, onChanged: (v: boolean) => void) {
    Row() {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: isOn() })
        .selectedColor($r('app.color.brand_pink'))
        .onChange((v: boolean) => {
          onChanged(v);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  QnSheet() {
    Column() {
      Text('默认清晰度')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 12 })
      ForEach(this.qnOptions, (o: QualityEntry) => {
        Row() {
          Text(o.desc)
            .fontSize(15)
            .fontColor(o.qn === this.qn ? $r('app.color.brand_pink') : $r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 11, bottom: 11 })
        }
        .width('100%')
        .onClick(() => {
          this.pickQn(o);
        })
      }, (o: QualityEntry) => o.qn.toString())
    }
    .width('100%')
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

  build() {
    Column() {
      // 顶栏
      Row({ space: 8 }) {
        Image($r('app.media.icon_arrow_left'))
            .width(22).height(22)
          .fillColor($r('app.color.text_primary'))
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            router.back();
          })
        Text('音视频设置')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
      .backgroundColor($r('app.color.card_bg'))

      Column() {
        this.SwitchRow('开启硬解', '优先使用设备支持的硬件解码', (): boolean => this.haOn,
          (v: boolean): void => {
            this.haOn = v;
            prefsPut(KEY_HA, v ? '1' : '0');
          })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16 })
        this.SwitchRow('免登录1080P', '免登录查看1080P视频', (): boolean => this.p1080On,
          (v: boolean): void => {
            this.p1080On = v;
            prefsPut(KEY_P1080, v ? '1' : '0');
          })
      }
      .width('100%')
      .backgroundColor($r('app.color.card_bg'))
      .margin({ top: 8 })

      Column() {
        Row() {
          Text('默认清晰度')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text(this.qnLabel)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Image($r('app.media.icon_arrow_right'))
            .width(22).height(22)
            .fillColor($r('app.color.text_secondary'))
            .margin({ left: 6 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 15, bottom: 15 })
        .onClick(() => {
          this.qnSheet = true;
        })
      }
      .width('100%')
      .backgroundColor($r('app.color.card_bg'))
      .margin({ top: 8 })

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .bindSheet($$this.qnSheet, this.QnSheet(), {
      height: 320,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_bg')
    })
  }
}
