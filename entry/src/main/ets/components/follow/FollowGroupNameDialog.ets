import { promptAction } from '@kit.ArkUI';
import { FollowSession, FollowGroup } from '../../model/follow';
import { FollowService, FollowCreatePendingError } from '../../service/follow_service';

@CustomDialog
export struct FollowGroupNameDialog {
  controller: CustomDialogController;
  session: FollowSession = { cookie: '', csrf: '', account: '', revision: -1 };
  group: FollowGroup | undefined = undefined;
  onSaved: (created?: FollowGroup) => void = () => {};
  onBusyChange: (busy: boolean) => void = () => {};
  @State name: string = '';
  @State busy: boolean = false;
  @State error: string = '';
  private destroyed: boolean = false;
  @State submitted: boolean = false;
  aboutToAppear(): void { this.name = this.group?.name || ''; }
  aboutToDisappear(): void { this.destroyed = true; this.onBusyChange(false); }
  private setBusy(value: boolean): void { this.busy = value; this.onBusyChange(value); }
  private async save(): Promise<void> {
    if (this.destroyed || this.busy || this.submitted || !this.name.trim()) { return; }
    const session: FollowSession = this.session;
    const group: FollowGroup | undefined = this.group;
    const name: string = this.name.trim();
    let created: FollowGroup | undefined = undefined;
    this.setBusy(true); this.error = '';
    try {
      if (group) {
        await FollowService.rename(session, group.tagid, name);
        created = { tagid: group.tagid, name: name, count: group.count, tip: group.tip, custom: group.custom };
      }
      else { created = await FollowService.create(session, name); }
    } catch (e) {
      if (e instanceof FollowCreatePendingError) {
        this.submitted = true;
        if (this.destroyed) { return; }
        this.error = e.message; this.setBusy(false);
        try { FollowService.assertSession(session); }
        catch (_) { return; }
        try { this.onSaved(undefined); }
        catch (_) { /* 已提交的创建只读刷新失败，也不能解锁重复创建。 */ }
        return;
      }
      if (!this.destroyed) { this.error = (e as Error).message || '保存失败，请重试'; this.setBusy(false); }
      return;
    }
    // 远端成功后永久锁定本次提交；回调或关窗异常不能触发重复新建。
    this.submitted = true;
    if (this.destroyed) { return; }
    try { FollowService.assertSession(session); }
    catch (e) { this.error = (e as Error).message; this.setBusy(false); return; }
    try { this.onSaved(created); }
    catch (_) { /* 远端已成功，父页刷新异常不改写成保存失败。 */ }
    finally {
      if (!this.destroyed) {
        this.setBusy(false); this.controller.close();
        promptAction.showToast({ message: group ? '修改成功' : '新建成功' });
      }
    }
  }
  build() {
    Column({ space: 20 }) {
      Text(this.group ? '编辑分组名称' : '新建分组').fontSize(20).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary')).width('100%')
      TextInput({ text: this.name, placeholder: '分组名称' }).fontSize(16).height(52).maxLength(16)
        .defaultFocus(true).enabled(!this.busy && !this.submitted).id('follow_group_name_input')
        .fontColor($r('app.color.text_primary')).backgroundColor(Color.Transparent)
        .border({ width: 1, color: $r('app.color.text_secondary') }).borderRadius(4)
        .onChange((value: string): void => { this.name = value; }).onSubmit((): void => { this.save(); })
      if (this.error) { Text(this.error).fontSize(13).fontColor($r('app.color.brand_pink')).width('100%') }
      Row({ space: 8 }) {
        Blank()
        Button('取消', { type: ButtonType.Normal }).fontSize(14).fontColor($r('app.color.text_secondary'))
          .height(44).backgroundColor(Color.Transparent).enabled(!this.busy).onClick((): void => { this.controller.close(); })
        Button(this.busy ? '保存中…' : '确认', { type: ButtonType.Normal }).fontSize(14).fontColor($r('app.color.brand_pink'))
          .height(44).backgroundColor(Color.Transparent).enabled(!this.busy && !this.submitted && this.name.trim().length > 0)
          .id('follow_group_name_save').onClick((): void => { this.save(); })
      }.width('100%')
    }.padding(24).width('90%').constraintSize({ maxWidth: 440 }).borderRadius(24)
      .backgroundColor($r('app.color.card_bg'))
  }
}
