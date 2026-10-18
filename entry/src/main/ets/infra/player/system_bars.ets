/** 透明系统栏文字按实际页面底色选择；异步完成时读取当前路由，避免旧页覆盖。 */
import { router, window } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';

export function syncSystemBars(win: window.Window, mode: ConfigurationConstant.ColorMode | undefined): void {
  let page: string = '';
  // 窗口创建早于loadContent，router在首个页面出现前会抛100001。
  // RouterState.path是目录（如pages/video/），name才是页面文件名。
  try { page = router.getState().name.replace(/\.ets$/, ''); } catch (e) {}
  const onBlack: boolean = page === 'VideoDetailPage';
  const light: boolean = onBlack || mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  const fullscreen: boolean = AppStorage.get<boolean>('imagePreviewVisible') === true ||
    (page === 'VideoDetailPage' && AppStorage.get<boolean>('playerFullscreen') === true);
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
