/**
 * 设置页（spec-09；路径对齐 PiliNara：音视频设置 / 缓存管理 / 账号 / 关于）
 *  - 默认清晰度/硬解/免登录1080P 移入「音视频设置」子页
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DownloadService } from '../../service/download_service';
import { AuthService, UserInfo } from '../../service/auth_service';
import { APP_VERSION } from '../../config/constants';
import { prefsGet, prefsPut } from '../../infra/storage/prefs';
import { imageCacheSize, clearImageCache, setDiskLimitMB } from '../../infra/image/image_loader';
import { MATERIAL_LEVEL_KEY } from '../main/MainShell';

/** 图片缓存上限（MB）存储键 */
const IMG_LIMIT_KEY: string = 'setting_img_cache_mb';

interface MaterialOption {
  name: string;
  level: number;
}

@Entry
@Component
struct SettingPage {
  @State ver: string = APP_VERSION;
  @State user: UserInfo | null = null;
  @State materialLevel: number = 10;
  @State materialSheetOn: boolean = false;
  @State imgCacheSize: number = 0;
  @State limitSheetOn: boolean = false;
  @State limitMB: number = 1024;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  private limitOptions: number[] = [256, 512, 1024, 2048];
  private materialOptions: MaterialOption[] = [
    { name: '自适应（跟随系统）', level: 10 },
    { name: '精美', level: 0 },
    { name: '轻柔', level: 1 },
    { name: '流畅', level: 2 }
  ];

  aboutToAppear(): void {
    this.init();
  }

  private async init(): Promise<void> {
    // 缓存管理行需要目录上下文才能统计占用
    DownloadService.init(getContext(this) as common.Context);
    // 版本号（常量维护，见 constants.APP_VERSION；模拟器 getBundleInfoForSelfSync 返回空）
    this.ver = APP_VERSION;
    // 账号
    this.user = await AuthService.fetchNav();
    // 沉浸光感材质等级
    const raw: string = await prefsGet(MATERIAL_LEVEL_KEY, '10');
    const n: number = parseInt(raw, 10);
    this.materialLevel = isNaN(n) ? 10 : n;
    // 图片缓存占用 + 上限
    this.imgCacheSize = imageCacheSize();
    const lim: string = await prefsGet(IMG_LIMIT_KEY, '1024');
    const limN: number = parseInt(lim, 10);
    this.limitMB = isNaN(limN) || limN <= 0 ? 1024 : limN;
    setDiskLimitMB(this.limitMB);
  }

  private limitName(): string {
    return this.limitMB >= 1024 ? (this.limitMB / 1024).toString() + ' GB' : this.limitMB.toString() + ' MB';
  }

  private async saveLimit(mb: number): Promise<void> {
    await prefsPut(IMG_LIMIT_KEY, mb.toString());
    this.limitMB = mb;
    setDiskLimitMB(mb);
    this.limitSheetOn = false;
    this.imgCacheSize = imageCacheSize();
    promptAction.showToast({ message: '图片缓存上限：' + this.limitName() });
  }

  /** 图片缓存上限选择面板 */
  @Builder
  LimitSheet() {
    Column() {
      Text('图片缓存上限')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 6 })
      Text('只缓存小尺寸图片，超限淘汰较早缓存（不影响收藏 / 下载）')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ bottom: 8 })

      ForEach(this.limitOptions, (mb: number) => {
        Row() {
          Text(mb >= 1024 ? (mb / 1024).toString() + ' GB' : mb.toString() + ' MB')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          if (this.limitMB === mb) {
            Text('✓')
              .fontSize(15)
              .fontColor($r('app.color.brand_pink'))
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14, bottom: 14 })
        .onClick(() => {
          this.saveLimit(mb);
        })
      }, (mb: number) => 'lim_' + mb.toString())
    }
    .width('100%')
  }

  /** 清除图片缓存（二次确认） */
  private confirmClearImageCache(): void {
    if (this.imgCacheSize <= 0) {
      promptAction.showToast({ message: '暂无图片缓存' });
      return;
    }
    AlertDialog.show({
      title: '清除图片缓存',
      message: '将删除已缓存的图片（当前 ' + formatSizeLocal(this.imgCacheSize) + '），下次浏览会重新下载。收藏/下载的文件不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清除',
        fontColor: '#E54D42',
        action: () => {
          const freed: number = clearImageCache();
          this.imgCacheSize = imageCacheSize();
          promptAction.showToast({ message: '已清除 ' + formatSizeLocal(freed) });
        }
      }
    });
  }

  private materialName(): string {
    for (let i = 0; i < this.materialOptions.length; i++) {
      if (this.materialOptions[i].level === this.materialLevel) {
        return this.materialOptions[i].name;
      }
    }
    return '自适应（跟随系统）';
  }

  private async saveMaterialLevel(level: number): Promise<void> {
    await prefsPut(MATERIAL_LEVEL_KEY, level.toString());
    this.materialLevel = level;
    this.materialSheetOn = false;
    promptAction.showToast({ message: '已设置：' + this.materialName() });
  }

  @Builder
  Row(title: string, right: () => string, onTap?: () => void, showArrow: boolean = true) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      // right 用闭包按引用取值：@Builder 按值传参时状态变化不会刷新 UI
      Text(right())
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      if (showArrow) {
        Image($r('app.media.icon_arrow_right'))
            .width(22).height(22)
          .fillColor($r('app.color.text_secondary'))
          .margin({ left: 6 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 15, bottom: 15 })
    .onClick(() => {
      if (onTap !== undefined) {
        onTap();
      }
    })
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
        Text('设置')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
      .backgroundColor($r('app.color.card_bg'))

      Column() {
        this.Row('音视频设置', (): string => '', (): void => {
          router.pushUrl({ url: 'pages/setting/VideoSettingPage' });
        })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16 })
        this.Row('缓存管理', (): string => '已用 ' + formatSizeLocal(DownloadService.totalBytes()), (): void => {
          router.pushUrl({ url: 'pages/download/DownloadPage' });
        })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16 })
        this.Row('清除图片缓存', (): string => formatSizeLocal(this.imgCacheSize), (): void => {
          this.confirmClearImageCache();
        })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16 })
        this.Row('图片缓存上限', (): string => this.limitName(), (): void => {
          this.limitSheetOn = true;
        })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16 })
        this.Row('沉浸光感底栏材质', (): string => this.materialName(), (): void => {
          this.materialSheetOn = true;
        })
      }
      .width('100%')
      .backgroundColor($r('app.color.card_bg'))
      .margin({ top: 8 })
      // Bug5：同一节点链式两个 bindSheet 会相互覆盖（后挂生效）→ 拆到不同节点
      .bindSheet($$this.limitSheetOn, this.LimitSheet(), {
        height: 320,
        dragBar: true,
        showClose: true,
        backgroundColor: $r('app.color.card_bg')
      })

      Column() {
        this.Row('账号信息', (): string => this.user !== null ? (this.user as UserInfo).uname : '未登录',
          (): void => {
            router.back();
          })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16 })
        this.Row('关于 PiliMini', (): string => 'v' + this.ver, (): void => {
          promptAction.showToast({ message: 'PiliMini 极简 B 站客户端 v' + this.ver });
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
    .bindSheet($$this.materialSheetOn, this.MaterialSheet(), {
      height: 300,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_bg')
    })
  }

  /** 沉浸光感底栏材质等级（HDS 三档 + 自适应，对齐 Nara） */
  @Builder
  MaterialSheet() {
    Column() {
      Text('沉浸光感底栏材质')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 10 })

      ForEach(this.materialOptions, (opt: MaterialOption) => {
        Row() {
          Text(opt.name)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          if (this.materialLevel === opt.level) {
            Text('✓')
              .fontSize(15)
              .fontColor($r('app.color.brand_pink'))
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14, bottom: 14 })
        .onClick(() => {
          this.saveMaterialLevel(opt.level);
        })
      }, (opt: MaterialOption) => 'ml_' + opt.level.toString())
    }
    .width('100%')
  }
}

function formatSizeLocal(n: number): string {
  if (n <= 0) {
    return '0B';
  }
  const units: string[] = ['B', 'K', 'M', 'G', 'T'];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v = v / 1024;
    i++;
  }
  return (i === 0 ? v.toString() : v.toFixed(1)) + units[i];
}
