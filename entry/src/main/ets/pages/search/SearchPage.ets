/**
 * 搜索页（spec-04）：关键词搜索 + 联想词 + 结果分页 + 搜索历史
 * 联想与历史逻辑对齐 Nara `lib/pages/search`（见 spec-04 §2026-10-27）。
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router } from '@kit.ArkUI';
import { BasicDataSource } from '../../common/list_data_source';
import { Pager, PageData } from '../../common/paged_feed';
import { VideoCard } from '../../components/VideoCard';
import { LoadingFooter, ErrorRetry, EmptyState } from '../../components/StateViews';
import { VideoService, PageResult, SuggestItem } from '../../service/video_service';
import { VideoItem } from '../../model/video_item';
import { SearchHistory } from '../../infra/storage/search_history';
import { Em, EmPart } from '../../common/em';

/** 对齐 Nara `DebounceStreamMixin`：200ms trailing。 */
const SUGGEST_DEBOUNCE: number = 200;
/** 联想浮层最大高度（约 13 行），超出内滚。 */
const SUGGEST_MAX_HEIGHT: number = 420;

/** 联想行：请求返回时就把命中前缀与剩余文本拆好，渲染只用两个固定 Text（ForEach 生成的子节点样式不可靠）。 */
class SuggestRow {
  term: string = '';
  /** 命中前缀（服务端 <em> 在开头时才有值），为空表示整条按普通文本渲染 */
  hit: string = '';
  tail: string = '';
}

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State submitted: string = '';
  @State history: string[] = [];
  @State suggest: SuggestRow[] = [];
  @State suggestOpen: boolean = false;
  private destroyed: boolean = false;
  private input: TextInputController = new TextInputController();
  private initialFocusRequested: boolean = false;
  private focusTimer: number = -1;
  private suggestTimer: number = -1;
  private suggestSeq: number = 0;
  private ds: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  @State pager: Pager<VideoItem> = new Pager<VideoItem>();
  @StorageProp('statusBarHeight') statusBarH: number = 0;

  aboutToAppear(): void {
    this.pager.firstError = '搜索失败，请检查网络后重试';
    this.loadHistory();
    // 详情页标签/话题带 keyword 进入时直接搜，不再要求用户手动输入。
    let preset: string = '';
    try {
      const params = router.getParams() as Record<string, string>;
      if (params !== undefined && params !== null) { preset = params['keyword'] || ''; }
    } catch (_) { preset = ''; }
    if (preset.trim().length > 0) { this.doSearch(preset); }
  }

  onPageShow(): void {
    if (this.initialFocusRequested) { return; }
    this.initialFocusRequested = true;
    // 默认焦点先响应；入场结束后补一次焦点，避免路由动画与输入法抢占。
    this.focusTimer = setTimeout(() => {
      this.focusTimer = -1;
      if (!this.destroyed && this.submitted.length === 0) {
        this.getUIContext().getFocusController().requestFocus('home_search_input');
      }
    }, NARA_ROUTE_DURATION + 32);
  }

  onPageHide(): void { this.cancelFocus(); }

  private cancelFocus(): void {
    if (this.focusTimer >= 0) { clearTimeout(this.focusTimer); this.focusTimer = -1; }
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.cancelFocus();
    this.cancelSuggest();
    this.pager.cancel();
  }

  private async loadHistory(): Promise<void> {
    const history: string[] = await SearchHistory.load();
    if (!this.destroyed) { this.history = history; }
  }

  private async fetchResults(cursor: string): Promise<PageData<VideoItem>> {
    const r: PageResult = await VideoService.search(this.submitted, parseInt(cursor, 10));
    const out: PageData<VideoItem> = {
      items: r.items,
      hasMore: r.hasMore,
      nextCursor: r.nextCursor.toString()
    };
    return out;
  }

  private async doSearch(kw: string): Promise<void> {
    const used: string = kw.trim();
    if (used.length === 0) {
      return;
    }
    this.cancelFocus();
    this.cancelSuggest();
    this.suggest = [];
    this.suggestOpen = false;
    this.input.stopEditing();
    this.keyword = used;
    this.submitted = used;
    this.pager.cancel();
    // 新关键词：从头加载（旧结果清空由 reload 的 ds.reload 承担）
    this.pager.firstLoaded = false;
    // 记录历史
    this.history = await SearchHistory.add(used);
    if (this.destroyed || this.submitted !== used) { return; }
    await this.pager.reload(this.ds, (cursor: string): Promise<PageData<VideoItem>> => this.fetchResults(cursor), true);
  }

  private async loadMore(): Promise<void> {
    await this.pager.loadMore(this.ds, (cursor: string): Promise<PageData<VideoItem>> => this.fetchResults(cursor));
  }

  // ===== 联想（Nara search/controller.dart:143-221） =====

  private cancelSuggest(): void {
    this.suggestSeq++;
    if (this.suggestTimer >= 0) { clearTimeout(this.suggestTimer); this.suggestTimer = -1; }
  }

  private onKeywordChange(value: string): void {
    this.keyword = value;
    this.cancelSuggest();
    if (this.suggest.length > 0) { this.suggest = []; }
    this.suggestOpen = false;
    const term: string = value.trim();
    // 输入内容与上次搜索词不同 → 立刻回到输入态。否则联想浮层会盖在旧结果列表上
    // （输入法选词/继续打字都会走这里，用户看到的是"提示词压住搜索结果"）。
    if (this.submitted.length > 0 && term !== this.submitted) {
      this.pager.cancel();
      this.submitted = '';
    }
    if (term.length === 0) {
      // 清空输入回到历史视图（结果数据保留，下次搜索会整体覆盖）
      this.pager.cancel();
      this.submitted = '';
      return;
    }
    this.suggestTimer = setTimeout(() => {
      this.suggestTimer = -1;
      this.fetchSuggest(term);
    }, SUGGEST_DEBOUNCE);
  }

  /** 失败静默：不弹错误、不打断输入，只收掉浮层。 */
  private async fetchSuggest(term: string): Promise<void> {
    const seq: number = ++this.suggestSeq;
    try {
      const list: SuggestItem[] = await VideoService.suggest(term);
      if (this.destroyed || seq !== this.suggestSeq || this.keyword.trim() !== term) { return; }
      const rows: SuggestRow[] = [];
      for (let i: number = 0; i < list.length; i++) {
        const row: SuggestRow = new SuggestRow();
        row.term = list[i].term;
        const parts: EmPart[] = Em.parse(list[i].label);
        // 只在「命中段在开头」时拆高亮前缀；其余情况整条按普通文本，避免词序错乱。
        if (parts.length > 0 && parts[0].isEm) {
          row.hit = parts[0].text;
          let rest: string = '';
          for (let k: number = 1; k < parts.length; k++) { rest += parts[k].text; }
          row.tail = rest;
        } else {
          row.tail = Em.plain(list[i].label);
        }
        rows.push(row);
      }
      this.suggest = rows;
      this.suggestOpen = rows.length > 0;
    } catch (_) {
      if (!this.destroyed && seq === this.suggestSeq) {
        this.suggest = [];
        this.suggestOpen = false;
      }
    }
  }

  // ===== 历史（Nara search/controller.dart:166-237） =====

  private clearHistory(): void {
    if (this.history.length === 0) { return; }
    AlertDialog.show({
      title: '清空搜索历史',
      message: '确定清空搜索历史？',
      autoCancel: true,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '清空',
        fontColor: '#E54D42',
        action: () => { this.doClearHistory(); }
      }
    });
  }

  private async doClearHistory(): Promise<void> {
    await SearchHistory.clear();
    if (!this.destroyed) { this.history = []; }
  }

  private async removeHistory(kw: string): Promise<void> {
    const next: string[] = await SearchHistory.remove(kw);
    if (!this.destroyed) { this.history = next; }
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

  /** 联想浮层：Nara 顶部联想列表同规格（无背景、左 20、上下 9、命中粗体主色）。 */
  @Builder
  SuggestPanel() {
    List() {
      ForEach(this.suggest, (row: SuggestRow) => {
        ListItem() {
          Row() {
            if (row.hit.length > 0) {
              Text(row.hit)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.brand_pink'))
                .maxLines(1)
            }
            Text(row.tail)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 20, right: 16, top: 9, bottom: 9 })
          .id('search_suggest_' + row.term)
          .onClick(() => { this.doSearch(row.term); })
        }
      }, (row: SuggestRow) => 's:' + row.term)
    }
    .width('100%')
    .constraintSize({ maxHeight: SUGGEST_MAX_HEIGHT })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 10, color: '#1A000000', offsetX: 0, offsetY: 6 })
  }

  /** 搜索历史：Nara 标题行（16 bold + 清空）+ 30vp 胶囊项，长按删单条。 */
  @Builder
  HistoryPanel() {
    Column() {
      Row() {
        Text('搜索历史')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Row({ space: 4 }) {
          Image($r('app.media.icon_delete_all'))
            .width(18)
            .height(18)
            .fillColor($r('app.color.text_secondary'))
          Text('清空')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .id('search_history_clear')
        .onClick(() => { this.clearHistory(); })
      }
      .width('100%')
      .padding({ left: 6, right: 6, bottom: 6 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.history, (kw: string) => {
          Text(kw)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .height(30)
            .padding({ left: 11, right: 11 })
            .margin({ right: 8, bottom: 8 })
            .borderRadius(6)
            .backgroundColor($r('app.color.btn_soft_bg'))
            .id('search_history_' + kw)
            .onClick(() => { this.doSearch(kw); })
            .gesture(LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => { this.removeHistory(kw); }))
        }, (kw: string) => 'h:' + kw)
      }
      .width('100%')
      .padding({ left: 6 })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Image($r('app.media.icon_arrow_left'))
            .width(22).height(22)
          .fillColor($r('app.color.text_primary'))
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            router.back();
          })
        TextInput({ text: this.keyword, placeholder: '搜索', controller: this.input })
          .id('home_search_input')
          .defaultFocus(true)
          .enableKeyboardOnFocus(true)
          .enterKeyType(EnterKeyType.Search)
          .layoutWeight(1)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 0 })
          .onChange((v: string) => {
            this.onKeywordChange(v);
          })
          .onSubmit(() => {
            this.doSearch(this.keyword);
          })
        if (this.keyword.length > 0) {
          Image($r('app.media.icon_clear'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.text_secondary'))
            .margin({ right: 8 })
            .onClick(() => {
              this.onKeywordChange('');
            })
        }
        Image($r('app.media.icon_search'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.text_primary'))
          .margin({ right: 6 })
          .onClick(() => {
            this.doSearch(this.keyword);
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6 + this.statusBarH, bottom: 6 })
      .backgroundColor($r('app.color.card_bg'))
      .border({ width: { bottom: 0.5 }, color: { bottom: '#14000000' } })

      Stack({ alignContent: Alignment.TopStart }) {
        if (this.submitted.length === 0 && !this.pager.loading) {
          Scroll() {
            Column() {
              if (this.history.length > 0) { this.HistoryPanel() }
            }
            .width('100%')
          }
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
        } else if (this.pager.loading && !this.pager.firstLoaded) {
          Column() {
            LoadingFooter({ text: '搜索中…' })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.pager.error.length > 0 && !this.pager.firstLoaded) {
          Column() {
            ErrorRetry({
              text: this.pager.error,
              onRetry: () => {
                this.doSearch(this.submitted);
              }
            })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.pager.firstLoaded && this.ds.size() === 0) {
          Column() {
            EmptyState({ text: '没有找到相关视频' })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            LazyForEach(this.ds, (item: VideoItem) => {
              ListItem() {
                VideoCard({ model: item })
              }
              .width('100%')
            }, (item: VideoItem) => item.key)

            ListItem() {
              if (this.pager.footerText.length > 0) {
                Text(this.pager.footerText)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(20)
              } else if (this.pager.loadingMore) {
                LoadingFooter({ text: '加载中…' })
              }
            }
          }
          .cachedCount(3)
          .width('100%')
          .height('100%')
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 12, endMargin: 12 })
          .onReachEnd(() => {
            this.loadMore();
          })
        }

        // 联想浮层压在内容之上，不改变已有结果状态
        // 联想浮层只存在于输入态；有搜索结果时一律不渲染，避免压住列表
        if (this.suggestOpen && this.suggest.length > 0 && this.submitted.length === 0) {
          this.SuggestPanel()
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
  }
}
