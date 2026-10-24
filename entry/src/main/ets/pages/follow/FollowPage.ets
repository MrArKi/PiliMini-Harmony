/** 我的关注：Nara分组Tab、45头像列表与右下服务端排序。 */
import { router, promptAction } from '@kit.ArkUI';
import { FollowService } from '../../service/follow_service';
import { FollowSession, FollowGroup, FollowItem } from '../../model/follow';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { onFollowChanged, FollowChanged } from '../../infra/event/app_events';
import { prefsGet, prefsPut } from '../../infra/storage/prefs';
import { FollowList } from '../../components/follow/FollowList';
import { FollowGroupNameDialog } from '../../components/follow/FollowGroupNameDialog';
import { LoadingFooter, ErrorRetry } from '../../components/StateViews';
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';

const ALL_FOLLOW: number = -999;

@Entry
@Component
struct FollowPage {
  @State ready: boolean = false;
  @State loading: boolean = true;
  @State error: string = '';
  @State needLogin: boolean = false;
  @State groups: FollowGroup[] = [];
  @State groupsError: string = '';
  @State tab: number = 0;
  @State orderType: string = '';
  @State refreshTick: number = 0;
  @State visible: boolean = true;
  @State sheetShown: boolean = false;
  @State groupLoading: boolean = false;
  @State groupBusy: boolean = false;
  @State groupError: string = '';
  @State groupReady: boolean = false;
  @State relationBusyMid: number = 0;
  @State nameBusy: boolean = false;
  @State selectedGroups: number[] = [];
  @State groupOptions: FollowGroup[] = [];
  @StorageProp('statusBarHeight') statusH: number = 0;
  @StorageProp('navBarHeight') navH: number = 0;
  private session: FollowSession | undefined = undefined;
  private generation: number = 0;
  private groupsGeneration: number = 0;
  private sheetGeneration: number = 0;
  private destroyed: boolean = false;
  private initRevision: number = -1;
  private orderWrite: Promise<void> = Promise.resolve();
  private relationOpen: boolean = false;
  private groupMenuOpen: boolean = false;
  private groupsDirty: boolean = false;
  private groupScroller: ListScroller = new ListScroller();
  private tabs: TabsController = new TabsController();
  private offFollow: (() => void) | undefined = undefined;
  private target: FollowItem | undefined = undefined;
  private nameDialog: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    this.offFollow = onFollowChanged((event: FollowChanged): void => {
      if (event.revision !== this.session?.revision) { return; }
      this.groupsDirty = true;
      if (this.visible) { this.loadGroups(); }
    });
  }
  onPageShow(): void {
    this.visible = true;
    if (!this.session || this.session.revision !== CookieStore.sessionRevision()) { this.initialize(); }
    else if (this.groupsDirty) { this.loadGroups(); }
  }
  onPageHide(): void { this.visible = false; }
  aboutToDisappear(): void {
    this.destroyed = true; this.generation++; this.groupsGeneration++; this.sheetGeneration++;
    this.nameDialog?.close(); this.sheetShown = false; this.session = undefined;
    if (this.offFollow) { this.offFollow(); }
  }
  private async initialize(): Promise<void> {
    const revision: number = CookieStore.sessionRevision();
    if (this.loading && this.initRevision === revision) { return; }
    this.initRevision = revision; const generation: number = ++this.generation;
    this.groupsGeneration++; this.sheetGeneration++; this.groupsDirty = false;
    this.groupBusy = false; this.groupLoading = false; this.groupReady = false; this.groupError = ''; this.groupOptions = []; this.target = undefined;
    this.ready = false; this.loading = true; this.error = ''; this.needLogin = false;
    this.sheetShown = false; this.nameDialog?.close(); this.session = undefined; this.groups = []; this.tab = 0;
    try {
      const session: FollowSession = await FollowService.captureSession(revision);
      const order: string = await prefsGet('follow_order_' + session.account, '');
      if (this.destroyed || generation !== this.generation) { return; }
      FollowService.assertSession(session); this.session = session; this.orderType = order === 'attention' ? 'attention' : '';
      this.groups = [{ tagid: ALL_FOLLOW, name: '全部关注', count: -1, tip: '', custom: false }];
      this.ready = true; this.loading = false; this.loadGroups();
    } catch (e) {
      if (!this.destroyed && generation === this.generation) {
        const loggedIn: boolean = await CookieStore.isLogin();
        if (this.destroyed || generation !== this.generation) { return; }
        this.needLogin = !loggedIn; this.error = (e as Error).message || '加载失败，请重试';
      }
    } finally { if (!this.destroyed && generation === this.generation) { this.initRevision = -1; this.loading = false; } }
  }
  private async loadGroups(): Promise<void> {
    const session: FollowSession | undefined = this.session;
    if (!session) { return; }
    const generation: number = ++this.groupsGeneration; this.groupsError = '';
    try {
      const result: FollowGroup[] = await FollowService.groups(session);
      if (this.destroyed || generation !== this.groupsGeneration) { return; }
      FollowService.assertSession(session);
      const selected: number = this.groups[this.tab]?.tagid ?? ALL_FOLLOW;
      const all: FollowGroup = this.groups[0] || { tagid: ALL_FOLLOW, name: '全部关注', count: -1, tip: '', custom: false };
      this.groups = [all].concat(result); this.tab = Math.max(0, this.groups.findIndex((group: FollowGroup): boolean => group.tagid === selected));
      this.groupsDirty = false;
    } catch (e) {
      if (!this.destroyed && generation === this.groupsGeneration) { this.groupsError = '分组加载失败，点击重试'; }
    }
  }
  private setTotal(tagid: number, total: number): void {
    if (this.destroyed) { return; }
    this.groups = this.groups.map((group: FollowGroup): FollowGroup => ({ tagid: group.tagid, name: group.name,
      count: group.tagid === tagid ? total : group.count, tip: group.tip, custom: group.custom }));
  }
  private toggleOrder(): void {
    this.orderType = this.orderType === '' ? 'attention' : '';
    const session: FollowSession | undefined = this.session;
    const order: string = this.orderType;
    if (session) {
      this.orderWrite = this.orderWrite.catch((): void => {}).then(async (): Promise<void> => {
        if (session.revision !== CookieStore.sessionRevision()) { return; }
        await prefsPut('follow_order_' + session.account, order);
      }).catch((): void => {
        if (!this.destroyed) { promptAction.showToast({ message: '排序偏好保存失败，本次排序仍生效' }); }
      });
    }
  }
  private editName(group?: FollowGroup): void {
    if (!this.session) { return; }
    this.nameBusy = false; this.nameDialog = new CustomDialogController({
      builder: FollowGroupNameDialog({ session: this.session, group: group, onBusyChange: (busy: boolean): void => { this.nameBusy = busy; }, onSaved: (created?: FollowGroup): void => {
        if (!created) { this.loadGroups(); return; }
        this.groupsGeneration++;
        const exists: boolean = this.groups.some((item: FollowGroup): boolean => item.tagid === created.tagid);
        this.groups = exists ? this.groups.map((item: FollowGroup): FollowGroup => item.tagid === created.tagid ? created : item) : this.groups.concat([created]);
        this.groupsDirty = true;
        if (this.sheetShown) {
          const included: boolean = this.groupOptions.some((item: FollowGroup): boolean => item.tagid === created.tagid);
          this.groupOptions = included ? this.groupOptions.map((item: FollowGroup): FollowGroup => item.tagid === created.tagid ? created : item) : this.groupOptions.concat([created]);
          if (!included) { this.selectGroup(created.tagid, true); }
        }
      } }), customStyle: true, autoCancel: false,
      onWillDismiss: (action: DismissDialogAction): void => { if (!this.nameBusy) { action.dismiss(); } }
    });
    this.nameDialog.open();
  }

  private async groupMenu(group: FollowGroup): Promise<void> {
    if (!group.custom || !this.session || this.groupMenuOpen) { return; }
    this.groupMenuOpen = true;
    const session: FollowSession = this.session;
    try {
      const choice = await promptAction.showActionMenu({ title: group.name, buttons: [{ text: '修改名称', color: $r('app.color.text_primary') }, { text: '删除分组', color: $r('app.color.brand_pink') }] });
      if (this.destroyed) { return; } FollowService.assertSession(session);
      if (choice.index === 0) { this.editName(group); return; }
      const confirm = await promptAction.showDialog({ title: '删除分组', message: '删除后，该分组下的用户依旧保留。',
        buttons: [{ text: '取消', color: $r('app.color.text_secondary') }, { text: '确认', color: $r('app.color.brand_pink') }] });
      if (confirm.index !== 1 || this.destroyed) { return; }
      await FollowService.delete(session, group.tagid);
      if (!this.destroyed) {
        this.groupsGeneration++;
        const selected: number = this.groups[this.tab]?.tagid ?? ALL_FOLLOW;
        this.groups = this.groups.filter((item: FollowGroup): boolean => item.tagid !== group.tagid);
        this.tab = Math.max(0, this.groups.findIndex((item: FollowGroup): boolean => item.tagid === selected));
        this.tabs.changeIndex(this.tab); this.groupsDirty = true; promptAction.showToast({ message: '删除成功' });
      }
    } catch (e) { if (!this.destroyed && (e as Error).message) { promptAction.showToast({ message: (e as Error).message }); } }
    finally { this.groupMenuOpen = false; }
  }
  private async relation(item: FollowItem): Promise<void> {
    const session: FollowSession | undefined = this.session;
    if (!session || this.relationOpen || this.relationBusyMid > 0) { return; }
    this.relationOpen = true;
    try {
      const choice = await promptAction.showActionMenu({ title: item.name, buttons: [{ text: '设置分组', color: $r('app.color.text_primary') }, { text: '取消关注', color: $r('app.color.brand_pink') }] });
      if (this.destroyed) { return; } FollowService.assertSession(session);
      if (choice.index === 0) {
        this.target = item; this.groupReady = false; this.groupOptions = []; this.selectedGroups = [];
        this.sheetShown = true; this.loadGroupSelection(true); return;
      }
      this.relationBusyMid = item.mid;
      await FollowService.cancelFollow(session, item.mid);
      if (!this.destroyed) { promptAction.showToast({ message: '已取消关注' }); }
    } catch (e) { if (!this.destroyed && (e as Error).message) { promptAction.showToast({ message: (e as Error).message }); } }
    finally { this.relationOpen = false; if (!this.destroyed) { this.relationBusyMid = 0; } }
  }
  private async loadGroupSelection(readMembership: boolean): Promise<void> {
    const session: FollowSession | undefined = this.session; const target: FollowItem | undefined = this.target;
    if (!session || !target) { return; }
    const generation: number = ++this.sheetGeneration; this.groupLoading = true; this.groupReady = false; this.groupError = '';
    try {
      const options: FollowGroup[] = await FollowService.groups(session);
      const selected: number[] = readMembership ? await FollowService.memberGroups(session, target.mid) : this.selectedGroups;
      if (this.destroyed || !this.sheetShown || generation !== this.sheetGeneration) { return; }
      this.groupOptions = options.filter((group: FollowGroup): boolean => group.tagid !== 0 && (group.tagid > 0 || group.tagid === -10 || group.tagid === -2));
      this.selectedGroups = selected.filter((id: number): boolean => id !== 0);
      this.groupReady = true;
    } catch (e) { if (!this.destroyed && generation === this.sheetGeneration) { this.groupError = (e as Error).message || '加载分组失败'; } }
    finally { if (!this.destroyed && generation === this.sheetGeneration) { this.groupLoading = false; } }
  }
  private selectGroup(id: number, checked: boolean): void {
    if (this.groupBusy || !this.groupReady || (this.selectedGroups.indexOf(id) >= 0) === checked) { return; }
    this.groupOptions = this.groupOptions.map((group: FollowGroup): FollowGroup => ({ tagid: group.tagid, name: group.name,
      count: group.tagid === id ? Math.max(0, group.count + (checked ? 1 : -1)) : group.count, tip: group.tip, custom: group.custom }));
    this.selectedGroups = checked ? this.selectedGroups.concat([id]).filter((v: number, index: number, all: number[]): boolean => all.indexOf(v) === index) :
      this.selectedGroups.filter((v: number): boolean => v !== id);
  }
  private async saveGroups(): Promise<void> {
    const session: FollowSession | undefined = this.session; const target: FollowItem | undefined = this.target;
    if (!session || !target || this.groupBusy || this.groupLoading || !this.groupReady) { return; }
    this.groupBusy = true; this.groupError = ''; const generation: number = this.sheetGeneration;
    try {
      await FollowService.setGroups(session, target.mid, this.selectedGroups);
      if (this.destroyed || generation !== this.sheetGeneration) { return; }
      this.sheetShown = false; this.refreshTick++; this.loadGroups(); promptAction.showToast({ message: '设置成功' });
    } catch (e) { if (!this.destroyed && generation === this.sheetGeneration && session.revision === CookieStore.sessionRevision()) { this.groupError = (e as Error).message || '保存失败，请重试'; } }
    finally { if (!this.destroyed && generation === this.sheetGeneration) { this.groupBusy = false; } }
  }
  @Builder
  GroupSheet() {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.icon_clear')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .enabled(!this.groupBusy).onClick((): void => { this.sheetShown = false; })
        Text('设置关注分组').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Image($r('app.media.icon_follow_add')).width(18).height(18).fillColor($r('app.color.brand_pink'))
            Text('新建分组').fontSize(14).fontColor($r('app.color.brand_pink'))
          }
        }.backgroundColor(Color.Transparent).padding({ left: 18, right: 18 }).height(48)
          .enabled(!this.groupBusy && this.groupReady).onClick((): void => { this.editName(); }).id('follow_sheet_create')
      }.width('100%').padding({ right: 16 })
      if (this.groupLoading) { LoadingFooter({ text: '正在加载…' }) }
      else if (this.groupError && !this.groupReady) {
        ErrorRetry({ text: this.groupError, onRetry: (): void => { this.loadGroupSelection(true); } })
      } else {
        List() {
          ForEach(this.groupOptions, (group: FollowGroup) => {
            ListItem() {
              Row({ space: 12 }) {
                Image($r('app.media.icon_follow_group')).width(24).height(24).fillColor($r('app.color.text_secondary'))
                Column({ space: 4 }) {
                  Text(group.name + ' (' + group.count.toString() + ')').fontSize(16).fontColor($r('app.color.text_primary'))
                  if (group.tip) { Text(group.tip).fontSize(12).fontColor($r('app.color.text_secondary')) }
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Checkbox().select(group.tagid === 0 ? this.selectedGroups.length === 0 : this.selectedGroups.indexOf(group.tagid) >= 0)
                  .selectedColor($r('app.color.brand_pink')).width(22).height(22).enabled(!this.groupBusy)
                  .id('follow_group_check_' + group.tagid.toString())
                  .onChange((checked: boolean): void => { this.selectGroup(group.tagid, checked); })
              }.width('100%').padding({ left: 16, right: 20, top: 12, bottom: 12 })
                .onClick((): void => { this.selectGroup(group.tagid, this.selectedGroups.indexOf(group.tagid) < 0); })
            }
          }, (group: FollowGroup): string => group.tagid.toString() + ':' + group.name + ':' + group.count.toString())
        }.layoutWeight(1).width('100%')
        if (this.groupError) { Text(this.groupError).fontSize(13).fontColor($r('app.color.brand_pink')).padding(12) }
      }
      Blank().layoutWeight(this.groupLoading || (this.groupError && !this.groupReady) ? 1 : 0)
      Divider().color($r('app.color.divider')).strokeWidth(1)
      Row() {
        Blank()
        Button(this.groupBusy ? '保存中…' : this.selectedGroups.length === 0 ? '保存至默认分组' : '保存', { type: ButtonType.Normal })
          .fontSize(14).height(44).backgroundColor($r('app.color.member_secondary_container')).fontColor($r('app.color.member_on_secondary_container'))
          .borderRadius(22).padding({ left: 20, right: 20 })
          .enabled(!this.groupBusy && !this.groupLoading && this.groupReady)
          .id('follow_group_save').onClick((): void => { this.saveGroups(); })
      }.width('100%').padding({ right: 20, top: 12, bottom: 12 + this.navH })
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
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
          .onClick((): void => { router.back(); }).accessibilityText('返回')
        Text('我的关注').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Image($r('app.media.icon_follow_add')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .enabled(this.ready).onClick((): void => { this.editName(); }).id('follow_create').accessibilityText('新建分组')
        Image($r('app.media.icon_follow_sort')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .enabled(this.ready).onClick((): void => { this.groupsDirty = true; router.pushUrl({ url: 'pages/follow/FollowGroupSortPage' }); })
          .id('follow_sort_groups').accessibilityText('分组排序')
        Image($r('app.media.icon_search')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .enabled(this.ready).onClick((): void => { router.pushUrl({ url: 'pages/follow/FollowSearchPage' }); })
          .id('follow_search').accessibilityText('搜索')
      }.width('100%').height(56 + this.statusH).padding({ top: this.statusH, right: 6 })
      if (this.loading) { Column() { LoadingFooter({ text: '正在加载…' }) }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center) }
      else if (!this.ready) {
        Column() {
          if (this.needLogin) {
            Text('登录后可查看我的关注').fontSize(14).fontColor($r('app.color.text_secondary'))
            Button('去登录').margin(16).backgroundColor($r('app.color.brand_pink'))
              .onClick((): void => { router.pushUrl({ url: 'pages/login/LoginPage' }); })
          } else { ErrorRetry({ text: this.error, onRetry: (): void => { this.initialize(); } }) }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.session !== undefined) {
        if (this.groupsError) {
          Text(this.groupsError).fontSize(12).fontColor($r('app.color.brand_pink')).padding(8).width('100%')
            .onClick((): void => { this.loadGroups(); })
        }
        List({ scroller: this.groupScroller }) {
          ForEach(this.groups, (group: FollowGroup, index: number) => {
            ListItem() { this.GroupTab(group, index) }
              .onClick((): void => { const selected: number = this.groups.findIndex((value: FollowGroup): boolean => value.tagid === group.tagid); if (selected >= 0) { this.tab = selected; this.tabs.changeIndex(selected); } })
          }, (group: FollowGroup): string => group.tagid.toString() + ':' + group.name + ':' + group.count.toString())
        }.listDirection(Axis.Horizontal).height(48).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
        Stack({ alignContent: Alignment.BottomEnd }) {
          Tabs({ index: this.tab, controller: this.tabs }) {
            ForEach(this.groups, (group: FollowGroup, index: number) => {
              TabContent() {
                FollowList({ session: this.session!, tagid: group.tagid, active: this.visible && this.groups[this.tab]?.tagid === group.tagid,
                  orderType: this.orderType, refreshTick: this.refreshTick, busyMid: this.relationBusyMid,
                  onRelation: (item: FollowItem): void => { this.relation(item); },
                  onTotal: (id: number, total: number): void => { this.setTotal(id, total); } })
              }
            }, (group: FollowGroup): string => this.generation.toString() + ':' + group.tagid.toString())
          }.barHeight(0).width('100%').height('100%').edgeEffect(EdgeEffect.None)
            .onChange((index: number): void => { this.tab = index; this.groupScroller.scrollToIndex(index, true, ScrollAlign.CENTER); })
          Button({ type: ButtonType.Normal }) {
            Row({ space: 10 }) {
              Image($r('app.media.icon_follow_list')).width(20).height(20).fillColor($r('app.color.text_primary'))
              Text(this.orderType === '' ? '最近关注' : '最常访问').fontSize(14).fontColor($r('app.color.text_primary'))
            }.padding({ left: 16, right: 20, top: 16, bottom: 16 })
          }.borderRadius(16).backgroundColor($r('app.color.member_secondary_container')).margin({ right: 16, bottom: 16 + this.navH })
            .onClick((): void => { this.toggleOrder(); }).id('follow_order_toggle')
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
      .bindSheet($$this.sheetShown, this.GroupSheet(), { height: '70%', showClose: false, dragBar: false,
        onWillDismiss: (action: SheetDismiss): void => { if (!this.groupBusy) { action.dismiss(); } },
        onDisappear: (): void => { this.sheetGeneration++; this.target = undefined; this.groupOptions = []; this.groupError = ''; } })
  }
  @Builder
  GroupTab(group: FollowGroup, index: number) {
    Row({ space: 4 }) {
        Text(group.name + (group.count >= 0 ? '(' + group.count.toString() + ')' : '')).fontSize(14)
          .fontColor(this.groups[this.tab]?.tagid === group.tagid ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
        if (group.custom) {
          Image($r('app.media.icon_follow_menu')).width(18).height(18)
            .fillColor(this.groups[this.tab]?.tagid === group.tagid ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
            .onClick((): void => { this.groupMenu(group); }).id('follow_group_menu_' + group.tagid.toString())
        }
    }.height(48).border({ width: { bottom: 3 }, color: this.groups[this.tab]?.tagid === group.tagid ? $r('app.color.brand_pink') : Color.Transparent })
      .padding({ left: 16, right: 16 }).id('follow_tab_' + group.tagid.toString())
      .gesture(LongPressGesture().onAction((): void => { this.groupMenu(group); }))
  }
}
