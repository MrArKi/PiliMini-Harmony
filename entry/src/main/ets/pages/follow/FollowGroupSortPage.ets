/** Nara关注分组排序：系统组固定，自定义组长按拖动，完成后才写账号。 */
import { router, promptAction } from '@kit.ArkUI';
import { FollowService } from '../../service/follow_service';
import { FollowSession, FollowGroup } from '../../model/follow';
import { LoadingFooter, ErrorRetry } from '../../components/StateViews';
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';

@Entry
@Component
struct FollowGroupSortPage {
  @State fixed: FollowGroup[] = [];
  @State custom: FollowGroup[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  @State busy: boolean = false;
  @StorageProp('statusBarHeight') statusH: number = 0;
  @StorageProp('navBarHeight') navH: number = 0;
  private session: FollowSession | undefined = undefined;
  private destroyed: boolean = false;
  private visible: boolean = true;
  private generation: number = 0;
  private submitted: boolean = false;
  private reading: boolean = false;
  aboutToAppear(): void { this.load(); }
  onPageShow(): void {
    this.visible = true;
    if (this.destroyed || this.loading) { return; }
    if (this.session && !this.submitted) {
      try { FollowService.assertSession(this.session); return; } catch (_) {}
    }
    this.session = undefined; this.fixed = []; this.custom = [];
    if (this.busy) { return; }
    this.load();
  }
  onPageHide(): void {
    this.visible = false; this.generation++; this.reading = false;
    if (this.loading) { this.loading = false; this.session = undefined; }
  }
  aboutToDisappear(): void { this.destroyed = true; this.visible = false; this.generation++; this.session = undefined; }
  private async load(): Promise<void> {
    if (this.destroyed || !this.visible || this.busy || this.reading) { return; }
    const generation: number = ++this.generation;
    this.reading = true;
    this.loading = true; this.error = '';
    this.session = undefined; this.fixed = []; this.custom = []; this.submitted = false;
    try {
      const session: FollowSession = await FollowService.captureSession();
      if (this.destroyed || !this.visible || generation !== this.generation) { return; }
      FollowService.assertSession(session);
      const groups: FollowGroup[] = await FollowService.groups(session);
      if (this.destroyed || !this.visible || generation !== this.generation) { return; }
      FollowService.assertSession(session);
      this.session = session;
      const all: FollowGroup[] = [{ tagid: -999, name: '全部关注', count: -1, tip: '', custom: false }];
      this.fixed = all.concat(groups.filter((g: FollowGroup): boolean => !g.custom));
      this.custom = groups.filter((g: FollowGroup): boolean => g.custom);
    } catch (e) { if (!this.destroyed && generation === this.generation) { this.error = (e as Error).message || '加载失败'; } }
    finally { if (!this.destroyed && generation === this.generation) { this.reading = false; this.loading = false; } }
  }
  private async save(): Promise<void> {
    if (this.destroyed || !this.visible || !this.session || this.busy || this.loading || this.error || this.submitted || this.custom.length === 0) { return; }
    const session: FollowSession = this.session;
    const tagids: number[] = this.custom.map((group: FollowGroup): number => group.tagid);
    this.busy = true;
    try {
      await FollowService.sortGroups(session, tagids);
      this.submitted = true;
      if (!this.destroyed && this.visible) {
        FollowService.assertSession(session);
        promptAction.showToast({ message: '排序完成' }); router.back();
      }
    } catch (e) { if (!this.destroyed && this.visible) { promptAction.showToast({ message: (e as Error).message || '排序失败，请重试' }); } }
    finally {
      if (!this.destroyed) {
        this.busy = false;
        if (this.visible && !this.session) { this.load(); }
      }
    }
  }
  private move(from: number, to: number): void {
    if (this.destroyed || !this.visible || this.busy || this.loading || this.error || !this.session || this.submitted || from < 0 || to < 0 || from >= this.custom.length || to >= this.custom.length) { return; }
    try { FollowService.assertSession(this.session); } catch (_) { this.load(); return; }
    const groups: FollowGroup[] = this.custom.slice(); const item: FollowGroup = groups.splice(from, 1)[0];
    groups.splice(to, 0, item); this.custom = groups;
  }
  @Builder
  GroupRow(group: FollowGroup) {
    Row({ space: 16 }) {
      Image(group.custom ? $r('app.media.icon_follow_group') : $r('app.media.icon_lock')).width(23).height(23)
        .fillColor($r('app.color.text_secondary'))
      Column({ space: 4 }) {
        Text(group.name + (group.count >= 0 ? ' (' + group.count.toString() + ')' : '')).fontSize(16)
          .fontColor(group.custom ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        if (group.tip) { Text(group.tip).fontSize(13).fontColor($r('app.color.text_secondary')) }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (group.custom) { Image($r('app.media.icon_follow_drag')).width(22).height(22).fillColor($r('app.color.text_secondary')) }
    }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 }).constraintSize({ minHeight: 56 })
      .backgroundColor($r('app.color.bg_page')).id('follow_sort_item_' + group.tagid.toString())
  }
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
  }
  build() {
    Column() {
      Row() {
        Image($r('app.media.icon_arrow_left')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .enabled(!this.busy).onClick((): void => { router.back(); })
        Text('关注分组排序').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        if (this.custom.length > 0) {
          Button(this.busy ? '保存中…' : '完成', { type: ButtonType.Normal }).fontSize(14).height(44)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.brand_pink')).margin({ right: 16 })
            .enabled(!this.busy && !this.loading && !this.error && this.session !== undefined && !this.submitted)
            .onClick((): void => { this.save(); }).id('follow_sort_save')
        }
      }.width('100%').height(56 + this.statusH).padding({ top: this.statusH })
      if (this.loading) { LoadingFooter({ text: '正在加载…' }) }
      else if (this.error) { ErrorRetry({ text: this.error, onRetry: (): void => { this.load(); } }) }
      else {
        List() {
          ForEach(this.fixed, (group: FollowGroup) => { ListItem() { this.GroupRow(group) } }, (group: FollowGroup): string => group.tagid.toString())
          ForEach(this.custom, (group: FollowGroup) => { ListItem() { this.GroupRow(group) }.enabled(!this.busy) }, (group: FollowGroup): string => group.tagid.toString())
            .onMove((from: number, to: number): void => { this.move(from, to); })
          ListItem() { Column().height(100 + this.navH) }
        }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
