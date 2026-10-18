import { window } from '@kit.ArkUI';

/** 主窗口保持亮屏按可见播放器所有权合并，避免旧页面退出覆盖新播放器。 */
export class PlayerScreen {
  private static owners: Set<string> = new Set<string>();
  private static requested: boolean | undefined = undefined;

  static update(win: window.Window, owner: string, wanted: boolean): void {
    if (wanted) { PlayerScreen.owners.add(owner); }
    else { PlayerScreen.owners.delete(owner); }
    const next: boolean = PlayerScreen.owners.size > 0;
    if (PlayerScreen.requested === next) { return; }
    PlayerScreen.requested = next;
    win.setWindowKeepScreenOn(next).catch((): void => { PlayerScreen.requested = undefined; });
  }
}
