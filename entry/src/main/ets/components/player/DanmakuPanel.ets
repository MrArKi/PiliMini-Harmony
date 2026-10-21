/** 弹幕Pure局部深色面板；宿主负责方向/覆盖层和播放偏好持久化。 */
import { promptAction } from '@kit.ArkUI';
import { DanmakuItem } from '../../model/danmaku';
import { DanmakuPreferences, copyDanmakuPreferences } from '../../infra/danmaku/settings';
import { DanmakuRule, DanmakuRuleKind, DanmakuRuleStore } from '../../infra/danmaku/rules';
import { BasicDataSource } from '../../common/list_data_source';

const PANEL_BG: string = '#242424';
const PANEL_TEXT: string = '#F1F1F1';
const PANEL_MUTED: string = '#AAAAAA';

function itemTime(time: number): string {
  const seconds: number = Math.max(0, Math.floor(time / 1000));
  const minutes: string = Math.floor(seconds / 60).toString();
  const remain: string = (seconds % 60).toString();
  return (minutes.length < 2 ? '0' : '') + minutes + ':' + (remain.length < 2 ? '0' : '') + remain;
}

function itemType(mode: number): string { return mode === 5 ? '顶部' : (mode === 4 ? '底部' : '滚动'); }
interface NearbyDanmakuRow { key: string; revision: number; item: DanmakuItem; label: string; }

@Component
export struct DanmakuPanel {
  @Prop @Watch('onPreferencesChanged') preferences: DanmakuPreferences = new DanmakuPreferences();
  @Prop status: string = '';
  @Prop @Watch('onNearbyChanged') nearby: DanmakuItem[] = [];
  @Prop nearbyRange: string = '当前时间前后15秒，仅已加载弹幕';
  /** 0设置 / 1附近 / 2关键词 / 3发送者。 */
  @Prop initialTab: number = 0;
  onChange: (preferences: DanmakuPreferences) => void = () => {};
  onClose: () => void = () => {};
  onRetry: () => void = () => {};
  onRefreshNearby: () => void = () => {};
  onSelect: (item: DanmakuItem) => void = () => {};
  onRulesChanged: () => void = () => {};
  onRestoreHidden: () => void = () => {};
  @State private tab: number = 0;
  @State private draft: DanmakuPreferences = new DanmakuPreferences();
  @State private rules: DanmakuRule[] = [];
  @State private rulesReady: boolean = false;
  @State private rulesError: string = '';
  @State private saving: boolean = false;
  @State private input: string = '';
  @State private editingId: string = '';
  @State private keywordCount: number = 0;
  @State private senderCount: number = 0;
  @State private visibleRuleCount: number = 0;
  private destroyed: boolean = false;
  private contentScroller: Scroller = new Scroller();
  private nearbyScroller: Scroller = new Scroller();
  private rulesScroller: Scroller = new Scroller();
  private nearbyDs: BasicDataSource<NearbyDanmakuRow> = new BasicDataSource<NearbyDanmakuRow>();
  private rulesDs: BasicDataSource<DanmakuRule> = new BasicDataSource<DanmakuRule>();
  private nearbyRevision: number = 0;

  aboutToAppear(): void {
    this.destroyed = false;
    this.tab = Math.max(0, Math.min(3, this.initialTab));
    this.draft = copyDanmakuPreferences(this.preferences);
    this.onNearbyChanged();
    this.loadRules();
  }

  aboutToDisappear(): void { this.destroyed = true; }
  private onPreferencesChanged(): void { this.draft = copyDanmakuPreferences(this.preferences); }
  private toast(text: string): void { if (!this.destroyed) { promptAction.showToast({ message: text }); } }
  private title(): string { return this.tab === 1 ? '附近已加载弹幕' : (this.tab >= 2 ? '本机屏蔽管理' : '弹幕设置'); }
  private kind(): DanmakuRuleKind { return this.tab === 3 ? 'sender' : 'keyword'; }
  private ruleCount(kind: DanmakuRuleKind): number { return kind === 'sender' ? this.senderCount : this.keywordCount; }
  private onNearbyChanged(): void {
    const revision: number = ++this.nearbyRevision;
    const rows: NearbyDanmakuRow[] = [];
    for (let index: number = 0; index < this.nearby.length; index++) {
      const item: DanmakuItem = this.nearby[index];
      rows.push({ key: revision.toString() + ':' + item.key, revision: revision, item: item,
        label: itemTime(item.time) + ' · ' + itemType(item.mode) });
    }
    this.nearbyDs.reload(rows);
  }
  private selectNearby(row: NearbyDanmakuRow): void {
    if (!this.destroyed && row.revision === this.nearbyRevision) { this.onSelect(row.item); }
  }
  private updateRuleList(): void {
    const visible: DanmakuRule[] = [];
    let keywords: number = 0;
    for (let index: number = 0; index < this.rules.length; index++) {
      const rule: DanmakuRule = this.rules[index];
      if (rule.kind === 'keyword') { keywords++; }
      if (rule.kind === this.kind()) { visible.push(rule); }
    }
    this.keywordCount = keywords; this.senderCount = this.rules.length - keywords;
    this.visibleRuleCount = visible.length; this.rulesDs.reload(visible);
  }

  /** V1 Builder的基础值参数不追踪后续变化，选中样式直接读取本组件状态。 */
  private chipSelected(id: string): boolean {
    if (id === 'dm_rule_keywords') { return this.tab === 2; }
    if (id === 'dm_rule_senders') { return this.tab === 3; }
    if (id.startsWith('dm_area_')) { return Math.round(this.draft.area * 100) === Number(id.substring(8)); }
    if (id.startsWith('dm_density_')) { return this.draft.density === Number(id.substring(11)); }
    if (id === 'dm_type_scroll') { return this.draft.scroll; }
    if (id === 'dm_type_top') { return this.draft.top; }
    if (id === 'dm_type_bottom') { return this.draft.bottom; }
    return false;
  }

  private chipLabel(label: string, id: string): string {
    if (id === 'dm_rule_keywords') { return '关键词 (' + this.ruleCount('keyword').toString() + '/100)'; }
    if (id === 'dm_rule_senders') { return '发送者 (' + this.ruleCount('sender').toString() + '/200)'; }
    return label;
  }

  private booleanValue(field: string): boolean {
    if (field === 'enabled') { return this.draft.enabled; }
    if (field === 'scroll') { return this.draft.scroll; }
    if (field === 'top') { return this.draft.top; }
    if (field === 'bottom') { return this.draft.bottom; }
    return this.draft.white;
  }

  private numberValue(field: string): number {
    if (field === 'opacity') { return this.draft.opacity; }
    if (field === 'fontSize') { return this.draft.fontSize; }
    return this.draft.scrollSpeed;
  }

  private numberLabel(field: string): string {
    if (field === 'opacity') { return Math.round(this.draft.opacity * 100).toString() + '%'; }
    if (field === 'fontSize') { return this.draft.fontSize.toString(); }
    return this.draft.scrollSpeed.toString() + '×';
  }

  private go(tab: number): void {
    if (this.saving) { return; }
    // 先归零仍挂载的旧内容，避免V1复用Scroll时把偏移带到短子页。
    const scroller: Scroller = this.tab === 1 ? this.nearbyScroller : (this.tab >= 2 ? this.rulesScroller : this.contentScroller);
    scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
    if (tab === 1) { this.onRefreshNearby(); }
    this.tab = tab; this.input = ''; this.editingId = '';
    if (tab >= 2) { this.updateRuleList(); }
    if (this.rulesReady) { this.rulesError = ''; }
  }

  private async loadRules(): Promise<void> {
    this.rulesReady = false;
    this.rulesError = '';
    try {
      const rules: DanmakuRule[] = await DanmakuRuleStore.load();
      if (!this.destroyed) { this.rules = rules; this.updateRuleList(); this.rulesReady = true; }
    } catch (_) {
      if (!this.destroyed) { this.rulesError = '读取屏蔽规则失败，请重试'; }
    }
  }

  /** 只有已成功落盘的规则才发布给当前播放会话。 */
  private async changeRule(action: string, id: string = ''): Promise<void> {
    if (this.saving || !this.rulesReady) { return; }
    this.saving = true;
    this.rulesError = '';
    try {
      let next: DanmakuRule[];
      if (action === 'remove') { next = DanmakuRuleStore.remove(this.rules, id); }
      else if (action === 'toggle') { next = DanmakuRuleStore.toggle(this.rules, id); }
      else if (this.editingId.length > 0) { next = DanmakuRuleStore.edit(this.rules, this.editingId, this.input); }
      else { next = DanmakuRuleStore.add(this.rules, this.kind(), this.input); }
      await DanmakuRuleStore.save(next);
      // 即使面板刚关闭，成功保存仍需通知宿主重筛当前弹幕。
      this.onRulesChanged();
      if (!this.destroyed) {
        this.rules = next;
        this.updateRuleList();
        if (action === 'save') { this.input = ''; this.editingId = ''; }
        if (action === 'remove' && this.editingId === id) { this.input = ''; this.editingId = ''; }
        this.toast(action === 'remove' ? '已删除规则' : '已保存，仅本机生效');
      }
    } catch (error) {
      if (!this.destroyed) {
        const message: string = (error as Error).message;
        this.rulesError = message.length > 0 ? message : '保存失败，请重试';
      }
    } finally { if (!this.destroyed) { this.saving = false; } }
  }

  private changeNumber(field: string, value: number, publish: boolean = true): void {
    const next: DanmakuPreferences = copyDanmakuPreferences(this.draft);
    if (field === 'area') { next.area = value; }
    else if (field === 'opacity') { next.opacity = value; }
    else if (field === 'fontSize') { next.fontSize = value; }
    else if (field === 'scrollSpeed') { next.scrollSpeed = value; }
    else if (field === 'density') { next.density = value; }
    this.draft = next;
    if (publish) { this.onChange(copyDanmakuPreferences(next)); }
  }

  private changeBoolean(field: string): void {
    const next: DanmakuPreferences = copyDanmakuPreferences(this.draft);
    if (field === 'enabled') { next.enabled = !next.enabled; }
    else if (field === 'scroll') { next.scroll = !next.scroll; }
    else if (field === 'top') { next.top = !next.top; }
    else if (field === 'bottom') { next.bottom = !next.bottom; }
    else if (field === 'white') { next.white = !next.white; }
    this.draft = next;
    this.onChange(copyDanmakuPreferences(next));
  }

  private reset(): void {
    const next: DanmakuPreferences = new DanmakuPreferences();
    next.enabled = this.draft.enabled;
    this.draft = next;
    this.onChange(copyDanmakuPreferences(next));
    this.toast('已恢复默认样式，开关与规则保留');
  }

  @Builder
  Chip(label: string, id: string, action: () => void) {
    Text(this.chipLabel(label, id)).fontSize(12).fontColor(this.chipSelected(id) ? $r('app.color.brand_pink') : PANEL_TEXT)
      .height(34).layoutWeight(1).textAlign(TextAlign.Center)
      .backgroundColor(this.chipSelected(id) ? '#22FB7299' : '#343434').borderRadius(8)
      .border({ width: 0.5, color: this.chipSelected(id) ? $r('app.color.brand_pink') : '#555555' })
      .id(id).onClick(action)
  }

  @Builder
  Action(label: string, id: string, action: () => void) {
    Row() {
      Text(id === 'dm_rules' ? '本机屏蔽管理 (' + this.rules.length.toString() + ')' : label)
        .fontSize(13).fontColor(PANEL_TEXT).layoutWeight(1)
      Image($r('app.media.icon_arrow_right')).width(16).height(16).fillColor(PANEL_MUTED)
    }.width('100%').height(44).id(id).onClick(action)
  }

  @Builder
  ToggleRow(label: string, field: string) {
    Row() {
      Text(label).fontSize(13).fontColor(PANEL_TEXT).layoutWeight(1)
      Image(field === 'enabled' && this.booleanValue(field) ? $r('app.media.icon_dm_on') :
        (field === 'enabled' ? $r('app.media.icon_dm_off') : $r('app.media.icon_done_all')))
        .width(22).height(22).fillColor(this.booleanValue(field) ? $r('app.color.brand_pink') : PANEL_MUTED)
        .opacity(this.booleanValue(field) || field === 'enabled' ? 1 : 0.25)
    }.width('100%').height(44).id('dm_setting_' + field)
      .accessibilityText(label + (this.booleanValue(field) ? '，已开启' : '，已关闭'))
      .onClick(() => { this.changeBoolean(field); })
  }

  @Builder
  NumberSlider(label: string, field: string, min: number, max: number, step: number) {
    Row() {
      Text(label).fontSize(13).fontColor(PANEL_TEXT).layoutWeight(1)
      Text(this.numberLabel(field)).fontSize(12).fontColor(PANEL_MUTED)
    }.width('100%').height(28)
    Slider({ value: this.numberValue(field), min: min, max: max, step: step, style: SliderStyle.OutSet })
      .selectedColor($r('app.color.brand_pink')).trackColor('#555555').blockColor('#FB7299')
      .trackThickness(10).blockSize({ width: 12, height: 12 }).height(28)
      .id('dm_slider_' + field)
      .onChange((number: number, mode: SliderChangeMode): void => {
        this.changeNumber(field, number, mode === SliderChangeMode.End || mode === SliderChangeMode.Click);
      })
  }

  @Builder
  Settings() {
    if (this.status.length > 0) {
      Row() {
        Text(this.status).fontSize(12).fontColor(PANEL_MUTED).layoutWeight(1)
        if (this.status.includes('失败') || this.status.includes('重试')) {
          Text('重试').fontSize(12).fontColor($r('app.color.brand_pink')).padding(10)
            .id('dm_retry').onClick(() => { this.onRetry(); })
        }
      }.width('100%').padding(10).backgroundColor('#18FFFFFF').borderRadius(8).margin({ bottom: 6 })
    }
    this.ToggleRow('显示弹幕', 'enabled')
    Text('显示区域').fontSize(13).fontColor(PANEL_TEXT).width('100%').margin({ top: 8 })
    Row({ space: 8 }) {
      ForEach([0.25, 0.5, 0.75, 1], (value: number) => {
        this.Chip(Math.round(value * 100).toString() + '%',
          'dm_area_' + Math.round(value * 100).toString(), () => { this.changeNumber('area', value); })
      })
    }.width('100%').margin({ top: 8, bottom: 12 })
    this.NumberSlider('透明度', 'opacity', 0.2, 1, 0.05)
    this.NumberSlider('字号', 'fontSize', 12, 24, 1)
    this.NumberSlider('滚动速度', 'scrollSpeed', 0.5, 1.5, 0.25)
    Text('密度').fontSize(13).fontColor(PANEL_TEXT).width('100%').margin({ top: 8 })
    Row({ space: 8 }) {
      this.Chip('稀疏', 'dm_density_1', () => { this.changeNumber('density', 1); })
      this.Chip('标准', 'dm_density_2', () => { this.changeNumber('density', 2); })
      this.Chip('较多', 'dm_density_3', () => { this.changeNumber('density', 3); })
    }.width('100%').margin({ top: 8, bottom: 6 })
    Text('过密时保持清晰与流畅，超出显示预算的弹幕不排队补发。')
      .fontSize(11).fontColor(PANEL_MUTED).width('100%').margin({ bottom: 14 })
    Text('显示类型（关闭后屏蔽该类型）').fontSize(12).fontColor(PANEL_MUTED).width('100%')
    Row({ space: 8 }) {
      this.Chip('滚动', 'dm_type_scroll', () => { this.changeBoolean('scroll'); })
      this.Chip('顶部', 'dm_type_top', () => { this.changeBoolean('top'); })
      this.Chip('底部', 'dm_type_bottom', () => { this.changeBoolean('bottom'); })
    }.width('100%').margin({ top: 8 })
    this.ToggleRow('统一白色', 'white')
    this.Action('附近已加载弹幕', 'dm_nearby', () => { this.go(1); })
    this.Action('本机屏蔽管理 (' + this.rules.length.toString() + ')', 'dm_rules', () => { this.go(2); })
    this.Action('恢复本视频隐藏项', 'dm_restore_hidden', () => { this.onRestoreHidden(); })
    Text('恢复默认样式').fontSize(13).fontColor($r('app.color.brand_pink'))
      .width('100%').height(44).id('dm_reset').onClick(() => { this.reset(); })
    Text('重置保留开关和本机规则。全屏字号同步放大1.2倍。')
      .fontSize(11).fontColor(PANEL_MUTED).width('100%')
  }

  @Builder
  NearbyHeader() {
    Row({ space: 8 }) {
      Text(this.nearbyRange + '，非全视频历史。').fontSize(11).fontColor(PANEL_MUTED).layoutWeight(1)
      Text('刷新当前附近').fontSize(12).fontColor($r('app.color.brand_pink')).height(44)
        .id('dm_nearby_refresh').onClick(() => { this.onRefreshNearby(); })
    }.width('100%').margin({ bottom: 12 })
    if (this.nearby.length === 0) {
      Text('当前附近暂无已加载弹幕').fontSize(13).fontColor(PANEL_MUTED)
        .width('100%').textAlign(TextAlign.Center).padding({ top: 36, bottom: 36 })
    }
  }

  @Builder
  NearbyRow(row: NearbyDanmakuRow) {
    Column({ space: 5 }) {
      Text(row.label).fontSize(11).fontColor(PANEL_MUTED).width('100%')
      Text(row.item.text).fontSize(13).fontColor(PANEL_TEXT).width('100%').maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 12 })
      .border({ width: { bottom: 0.5 }, color: '#444444' })
      .onClick(() => { this.selectNearby(row); })
  }

  @Builder
  RulesHeader() {
    Row({ space: 8 }) {
      this.Chip('关键词', 'dm_rule_keywords', () => { this.go(2); })
      this.Chip('发送者', 'dm_rule_senders', () => { this.go(3); })
    }.width('100%').margin({ bottom: 12 })
    Text(this.tab === 2 ? '区分大小写的包含匹配，每条1至50个字符，仅本机生效。' :
      '从画面或附近弹幕选择发送者后屏蔽，仅本机生效，不影响B站账号。')
      .fontSize(11).fontColor(PANEL_MUTED).width('100%').margin({ bottom: 12 })
    if (!this.rulesReady && this.rulesError.length === 0) {
      Text('正在读取规则…').fontSize(12).fontColor(PANEL_MUTED).padding(16)
    }
    if (this.rulesError.length > 0) {
      Text(this.rulesError).fontSize(12).fontColor('#FFB4AB').width('100%').margin({ bottom: 8 })
      if (!this.rulesReady) {
        Text('重新读取').fontSize(13).fontColor($r('app.color.brand_pink')).height(44)
          .id('dm_rules_retry').onClick(() => { this.loadRules(); })
      }
    }
    if (this.rulesReady) {
      if (this.tab === 2) {
      TextInput({ text: this.input, placeholder: '输入要屏蔽的关键词' })
        .fontSize(13).fontColor(PANEL_TEXT).placeholderColor(PANEL_MUTED).backgroundColor('#343434')
        .maxLength(100).borderRadius(10).height(42)
        .id('dm_rule_input').enabled(!this.saving).onChange((value: string): void => { this.input = value; })
      Row() {
        if (this.editingId.length > 0) {
          Text('取消编辑').fontSize(12).fontColor(PANEL_MUTED).height(42)
            .onClick(() => { if (!this.saving) { this.editingId = ''; this.input = ''; } })
        }
        Blank()
        Text(this.saving ? '正在保存…' : (this.editingId.length > 0 ? '保存修改' : '添加规则'))
          .fontSize(13).fontColor($r('app.color.brand_pink')).height(42).padding({ left: 12 })
          .id('dm_rule_save').onClick(() => { this.changeRule('save'); })
      }.width('100%')
      }
      if (this.visibleRuleCount === 0) {
        Text('暂无屏蔽规则').fontSize(13).fontColor(PANEL_MUTED).width('100%')
          .textAlign(TextAlign.Center).padding({ top: 30, bottom: 30 })
      }
    }
  }

  @Builder
  RuleRow(rule: DanmakuRule) {
    Column({ space: 4 }) {
          Text(rule.value).fontSize(13).fontColor(rule.enabled ? PANEL_TEXT : PANEL_MUTED)
            .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 12 }) {
            Text(rule.enabled ? '已启用' : '已停用').fontSize(11)
              .fontColor(rule.enabled ? $r('app.color.brand_pink') : PANEL_MUTED)
              .height(36).onClick(() => { this.changeRule('toggle', rule.id); })
            Blank()
            if (rule.kind === 'keyword') {
              Text('编辑').fontSize(12).fontColor(PANEL_MUTED).height(36)
                .onClick(() => { if (!this.saving) { this.editingId = rule.id; this.input = rule.value; } })
            }
            Text('删除').fontSize(12).fontColor('#FFB4AB').height(36)
              .onClick(() => { this.changeRule('remove', rule.id); })
          }.width('100%')
    }.width('100%').padding({ top: 10, bottom: 4 }).border({ width: { bottom: 0.5 }, color: '#444444' })
  }

  build() {
    Column() {
      Row() {
        Row() { Image($r('app.media.icon_arrow_left')).width(18).height(18).fillColor(PANEL_TEXT) }
          .width(32).height(45).justifyContent(FlexAlign.Center)
          .visibility(this.tab === 0 ? Visibility.Hidden : Visibility.Visible)
          .id('dm_panel_back').onClick(() => { this.go(0); })
        Text(this.title()).fontSize(14).fontColor(PANEL_TEXT).layoutWeight(1).textAlign(TextAlign.Center)
        Row() { Image($r('app.media.icon_clear')).width(18).height(18).fillColor(PANEL_TEXT) }
          .width(32).height(45).justifyContent(FlexAlign.Center).id('dm_panel_close').onClick(() => { this.onClose(); })
      }.width('100%').height(45)
      if (this.tab === 1) {
        List({ scroller: this.nearbyScroller }) {
          ListItem() { Column() { this.NearbyHeader() }.width('100%').alignItems(HorizontalAlign.Start) }
          LazyForEach(this.nearbyDs, (row: NearbyDanmakuRow) => {
            ListItem() { this.NearbyRow(row) }
          }, (row: NearbyDanmakuRow): string => row.key)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).cachedCount(2)
          .padding({ top: 10, bottom: 20 })
      } else if (this.tab >= 2) {
        List({ scroller: this.rulesScroller }) {
          ListItem() { Column() { this.RulesHeader() }.width('100%').alignItems(HorizontalAlign.Start) }
          LazyForEach(this.rulesDs, (rule: DanmakuRule) => {
            ListItem() { this.RuleRow(rule) }
          }, (rule: DanmakuRule): string => rule.id + '_' + rule.enabled.toString() + '_' + rule.value)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).cachedCount(2)
          .padding({ top: 10, bottom: 20 })
      } else {
        Scroll(this.contentScroller) {
          Column() { this.Settings() }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 10, bottom: 20 })
        }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
      }
    }.width('100%').height('100%').padding({ left: 14, right: 14 })
      .backgroundColor(PANEL_BG).borderRadius(12).clip(true)
  }
}

