import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { initPrefs, prefsGet, prefsPut } from '../infra/storage/prefs';
import { initImageLoader, setDiskLimitMB, trimImageMemory } from '../infra/image/image_loader';
import { emitAppBackground, emitAppForeground } from '../infra/event/app_events';
import { syncSystemBars } from '../infra/player/system_bars';

const DOMAIN = 0x0000;
const TAG = 'PiliMini';

/** 一次性迁移：默认清晰度拉到最高 1080P（用户指示 2026-10-11；迁移标记保证只执行一次） */
async function migrateQn1080(): Promise<void> {
  const done: string = await prefsGet('mig_qn1080', '0');
  if (done === '1') {
    return;
  }
  await prefsPut('setting_default_qn', '80');
  await prefsPut('mig_qn1080', '1');
}

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    trimImageMemory();
    hilog.info(DOMAIN, TAG, 'image memory cache dropped at level %{public}d', level);
  }

  private syncSystemBarTheme(mode: ConfigurationConstant.ColorMode | undefined): void {
    const win: window.Window | undefined = this.mainWindow;
    if (win === undefined) { return; }
    syncSystemBars(win, mode);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.syncSystemBarTheme(newConfig.colorMode === undefined ? this.context.config.colorMode : newConfig.colorMode);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 外观跟随系统：不做主题设置（已确认）
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
    // 全局初始化：存储 / 图片缓存
    initImageLoader(this.context.cacheDir);
    initPrefs(this.context).then(async () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'prefs ready');
      // 图片缓存上限（设置页可改，默认 1GB）在启动时生效
      const lim: string = await prefsGet('setting_img_cache_mb', '1024');
      const mb: number = parseInt(lim, 10);
      setDiskLimitMB(isNaN(mb) || mb <= 0 ? 1024 : mb);
      return migrateQn1080();
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'prefs init failed: %{public}s', err.message);
    });
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    // 沉浸式布局（Nara 同款）：全屏布局 + 透明系统栏 + 安全区高度入 AppStorage
    try {
      const win = windowStage.getMainWindowSync();
      this.mainWindow = win;
      win.setWindowLayoutFullScreen(true);
      this.syncSystemBarTheme(this.context.config.colorMode);
      const sysArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate('statusBarHeight', px2vp(sysArea.topRect.height));
      const navArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('navBarHeight', px2vp(navArea.bottomRect.height));
      hilog.info(DOMAIN, TAG, 'immersive ready: %{public}s', JSON.stringify({
        top: AppStorage.get<number>('statusBarHeight'),
        bottom: AppStorage.get<number>('navBarHeight')
      }));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'immersive setup failed: %{public}s', JSON.stringify(err));
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    this.mainWindow = undefined;
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    this.syncSystemBarTheme(this.context.config.colorMode);
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    emitAppForeground();
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    emitAppBackground();
  }
}
