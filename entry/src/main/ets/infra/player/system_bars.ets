/** 透明系统栏文字按实际页面底色选择；异步完成时读取当前路由，避免旧页覆盖。 */
import { router, window } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';

export function syncSystemBars(win: window.Window, mode: ConfigurationConstant.ColorMode | undefined): void {
  let page: string = '';
  // 窗口创建早于loadContent，router在首个页面出现前会抛100001。
  // RouterState.path是目录（如pages/video/），name才是页面文件名。
  try { page = router.getState().name.replace(/\.ets$/, ''); } catch (e) {}
  // 首页详情由Navigation承载，router仍停在MainShell。同时限制宿主名，
  // 避免旧详情异步刷新迟到时把覆盖其上的搜索/UP页面误当成视频页。
  const onBlack: boolean = page === 'VideoDetailPage' ||
    (page === 'MainShell' && AppStorage.get<boolean>('navVideoDetailVisible') === true);
  const light: boolean = onBlack || mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  const fullscreen: boolean = AppStorage.get<boolean>('imagePreviewVisible') === true ||
    (onBlack && AppStorage.get<boolean>('playerFullscreen') === true);
  win.setWindowSystemBarEnable(fullscreen ? [] : ['status', 'navigation']).catch((err: Error): void => {
    console.warn('[SystemBars] ' + err.message);
  });
  win.setWindowSystemBarProperties({
    statusBarColor: '#00000000', navigationBarColor: '#00000000',
    statusBarContentColor: light ? '#FFFFFFFF' : '#FF000000',
    navigationBarContentColor: light ? '#FFFFFFFF' : '#FF000000'
  }).catch((err: Error): void => { console.warn('[SystemBars] ' + err.message); });
}

export function refreshSystemBars(ctx: common.UIAbilityContext): void {
  window.getLastWindow(ctx).then((win: window.Window): void => {
    syncSystemBars(win, ctx.config.colorMode);
  }).catch((err: Error): void => { console.warn('[SystemBars] ' + err.message); });
}
