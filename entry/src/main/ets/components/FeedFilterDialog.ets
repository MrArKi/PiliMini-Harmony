/** Nara首页菜单的原因/确认弹窗；首页宿主持有，移除卡片不会销毁操作。 */
import { promptAction } from '@kit.ArkUI';
import { VideoItem } from '../model/video_item';
import { FeedFilterService, FeedFilterRule } from '../service/feed_filter_service';
import { MemberService, MemberRelation, MemberRelationSession } from '../service/member_service';
import { CookieStore } from '../infra/cookie/cookie_store';

@CustomDialog
export struct FeedFilterDialog {
  controller: CustomDialogController;
  mode: string = 'manage';
  model: VideoItem | undefined = undefined;
  @State rules: FeedFilterRule[] = [];
  @State busy: boolean = false;
  @State loading: boolean = false;
  @State error: string = '';
  private destroyed: boolean = false;
  private accountRevision: number = -1;
  private changed: () => void = (): void => { if (!this.destroyed) { this.rules = FeedFilterService.snapshot(); } };

  aboutToAppear(): void {
    this.accountRevision = CookieStore.sessionRevision();
    FeedFilterService.subscribe(this.changed);
    if (this.mode === 'manage') { this.load(); }
  }

  aboutToDisappear(): void { this.destroyed = true; FeedFilterService.unsubscribe(this.changed); }

  private async load(): Promise<void> {
    this.loading = true; this.error = '';
    try {
      await FeedFilterService.ready();
      if (!this.destroyed) { this.rules = FeedFilterService.snapshot(); }
    } catch (e) { if (!this.destroyed) { this.error = (e as Error).message; } }
    finally { if (!this.destroyed) { this.loading = false; } }
  }

  private async add(kind: string): Promise<void> {
    if (this.busy || this.model === undefined) { return; }
    const item: VideoItem = this.model;
    const value: string = kind === 'up' ? (item.upMid || 0).toString() :
      kind === 'title' ? item.title : kind === 'zone' ? (item.zoneName || '') : item.bvid;
    const label: string = kind === 'up' ? 'UP主：' + item.upName + '（' + value + '）' :
      kind === 'title' ? '标题：' + item.title : kind === 'zone' ? '频道：' + value : '视频：' + item.title;
    this.busy = true;
    try {
      await FeedFilterService.add(kind, value, label);
      if (!this.destroyed) {
        promptAction.showToast({ message: '已在当前设备隐藏，可在屏蔽管理中撤销' });
        this.controller.close();
      }
    } catch (e) { if (!this.destroyed) { promptAction.showToast({ message: (e as Error).message || '保存失败，请重试' }); } }
    finally { if (!this.destroyed) { this.busy = false; } }
  }

  private async remove(rule: FeedFilterRule): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      await FeedFilterService.remove(rule.id);
      if (!this.destroyed) { promptAction.showToast({ message: '已解除本地屏蔽' }); }
    } catch (e) { if (!this.destroyed) { promptAction.showToast({ message: (e as Error).message || '解除失败，请重试' }); } }
    finally { if (!this.destroyed) { this.busy = false; } }
  }

  private async blockAccount(): Promise<void> {
    if (this.busy || this.model === undefined || (this.model.upMid || 0) <= 0) { return; }
    this.busy = true;
    const mid: number = this.model.upMid || 0;
    try {
      const session: MemberRelationSession = await MemberService.captureRelationSession(this.accountRevision);
      if (this.destroyed) { return; }
      MemberService.assertRelationSession(session);
      if (Number(session.account) === mid) { throw new Error('不能拉黑自己'); }
      const relation: MemberRelation = await MemberService.relationForSession(mid, session);
      if (this.destroyed) { return; }
      MemberService.assertRelationSession(session);
      if (relation.attribute !== 128) { await MemberService.modifyRelationForSession(mid, 5, session); }
      if (this.destroyed) { return; }
      MemberService.assertRelationSession(session);
      FeedFilterService.markBlocked(mid, session.revision);
      if (!this.destroyed) {
        promptAction.showToast({ message: '已拉黑，可在该UP主空间解除拉黑' });
        this.controller.close();
      }
    } catch (e) { if (!this.destroyed) { promptAction.showToast({ message: (e as Error).message || '拉黑失败，请重试' }); } }
    finally { if (!this.destroyed) { this.busy = false; } }
  }

  @Builder
  Reason(label: string, kind: string) {
    Text(label).fontSize(14).fontColor($r('app.color.text_primary')).maxLines(3)
      .padding({ left: 11, right: 11, top: 6, bottom: 6 }).borderRadius(6)
      .backgroundColor($r('app.color.btn_soft_bg')).margin({ right: 8, bottom: 8 })
      .enabled(!this.busy).onClick(() => { this.add(kind); })
  }

  @Builder
  LocalReasons() {
    Text('屏蔽原因').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      .width('100%').margin({ bottom: 8 })
    Flex({ wrap: FlexWrap.Wrap }) {
      if (this.model !== undefined) {
        if ((this.model.upMid || 0) > 0) { this.Reason('UP主：' + this.model.upName, 'up') }
        if (this.model.title.trim().length > 0) { this.Reason('标题：' + this.model.title, 'title') }
        if ((this.model.zoneName || '').trim().length > 0) { this.Reason('频道：' + this.model.zoneName, 'zone') }
      }
    }.width('100%')
    Text('仅在当前设备的首页推荐和热门生效，可在屏蔽管理中撤销。')
      .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 8 })
  }

  @Builder
  Management() {
    Text('以下规则仅在当前设备的首页推荐和热门生效。')
      .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').margin({ bottom: 12 })
    if (this.loading) {
      LoadingProgress().width(28).height(28).color($r('app.color.brand_pink')).margin(20)
    } else if (this.error.length > 0) {
      Text(this.error).fontSize(14).fontColor($r('app.color.text_secondary'))
      Button('重试').onClick(() => { this.load(); })
    } else if (this.rules.length === 0) {
      Text('暂无本地屏蔽规则').fontSize(14).fontColor($r('app.color.text_secondary')).padding({ top: 24, bottom: 24 })
    } else {
      List() {
        ForEach(this.rules, (rule: FeedFilterRule) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(rule.label).fontSize(13).fontColor($r('app.color.text_primary')).maxLines(3).layoutWeight(1)
              Button('解除', { type: ButtonType.Normal }).fontSize(13)
                .fontColor($r('app.color.brand_pink')).backgroundColor(Color.Transparent)
                .height(44).padding({ left: 8, right: 8 }).enabled(!this.busy)
                .onClick(() => { this.remove(rule); })
            }.width('100%').padding({ top: 6, bottom: 6 })
          }
        }, (rule: FeedFilterRule) => rule.id)
      }.width('100%').height(300).scrollBar(BarState.Auto)
    }
  }

  build() {
    Column() {
      Text(this.mode === 'manage' ? '屏蔽管理' : this.mode === 'block' ? '本地屏蔽' :
        this.mode === 'dislike' ? '不感兴趣' : '拉黑用户')
        .fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .width('100%').margin({ bottom: 20 })
      if (this.mode === 'manage') {
        this.Management()
      } else if (this.mode === 'block') {
        this.LocalReasons()
      } else {
        Text(this.mode === 'dislike' ? '仅在当前设备隐藏该视频，不会反馈给B站。可在“屏蔽管理”中撤销。' :
          '确定拉黑 ' + (this.model !== undefined ? this.model.upName : '') + '？将取消关注并限制与你的互动，可在该UP主空间解除拉黑。')
          .fontSize(14).lineHeight(22).fontColor($r('app.color.text_primary')).width('100%')
      }
      Row({ space: 8 }) {
        Blank()
        Button(this.mode === 'manage' ? '完成' : this.mode === 'black' ? '点错了' : '取消', { type: ButtonType.Normal })
          .fontSize(14).fontColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent)
          .height(44).padding({ left: 12, right: 12 }).enabled(!this.busy).onClick(() => { this.controller.close(); })
        if (this.mode === 'dislike' || this.mode === 'black') {
          Button(this.busy ? '正在处理…' : this.mode === 'dislike' ? '隐藏视频' : '确认', { type: ButtonType.Normal })
            .fontSize(14).fontColor($r('app.color.brand_pink')).backgroundColor(Color.Transparent)
            .height(44).padding({ left: 12, right: 12 }).enabled(!this.busy)
            .onClick(() => { if (this.mode === 'dislike') { this.add('video'); } else { this.blockAccount(); } })
        }
      }.width('100%').margin({ top: 16 })
    }.width('90%').constraintSize({ maxWidth: 440 }).padding(24).borderRadius(24)
      .backgroundColor($r('app.color.card_bg')).alignItems(HorizontalAlign.Start)
  }
}
