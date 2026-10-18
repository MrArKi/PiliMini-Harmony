/**
 * 搜索页（spec-04）：关键词搜索 + 结果分页 + 搜索历史
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router } from '@kit.ArkUI';
import { BasicDataSource } from '../../common/list_data_source';
import { Pager, PageData } from '../../common/paged_feed';
import { VideoCard } from '../../components/VideoCard';
import { LoadingFooter, ErrorRetry, EmptyState } from '../../components/StateViews';
import { VideoService, PageResult } from '../../service/video_service';
import { VideoItem } from '../../model/video_item';
import { SearchHistory } from '../../infra/storage/search_history';

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State submitted: string = '';
  @State history: string[] = [];
  private destroyed: boolean = false;
  private ds: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  @State pager: Pager<VideoItem> = new Pager<VideoItem>();
  @StorageProp('statusBarHeight') statusBarH: number = 0;

  aboutToAppear(): void {
    this.pager.firstError = '搜索失败，请检查网络后重试';
    this.loadHistory();
  }

  aboutToDisappear(): void { this.destroyed = true; this.pager.cancel(); }

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

  private async clearHistory(): Promise<void> {
    await SearchHistory.clear();
    this.history = [];
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
        TextInput({ text: this.keyword, placeholder: '搜索' })
          .layoutWeight(1)
          .fontSize(15)
          .backgroundColor(Color.Transparent)
          .padding({ left: 0 })
          .onChange((v: string) => {
            this.keyword = v;
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
              this.keyword = '';
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

      if (this.submitted.length === 0 && !this.pager.loading) {
        Column({ space: 12 }) {
          Row({ space: 4 }) {
            Text('搜索历史')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Blank()
            if (this.history.length > 0) {
              Row({ space: 4 }) {
                Image($r('app.media.icon_delete_all'))
                  .width(18)
                  .height(18)
                  .fillColor($r('app.color.text_secondary'))
                Text('清空')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              .onClick(() => {
                this.clearHistory();
              })
            }
          }
          .width('100%')
          .padding({ left: 6, right: 10, top: 18 })

          if (this.history.length === 0) {
            Text('暂无搜索历史')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 40 })
          } else {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.history, (kw: string) => {
                Text(kw)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                  .margin({ right: 8, bottom: 8 })
                  .borderRadius(6)
                  .backgroundColor($r('app.color.btn_soft_bg'))
                  .onClick(() => {
                    this.doSearch(kw);
                  })
              }, (kw: string) => kw)
            }
            .width('100%')
          }
          Blank()
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 10, right: 10 })
        .alignItems(HorizontalAlign.Start)
      } else if (this.pager.loading && !this.pager.firstLoaded) {
        Column() {
          LoadingFooter({ text: '搜索中…' })
        }
        .layoutWeight(1)
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
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.pager.firstLoaded && this.ds.size() === 0) {
        Column() {
          EmptyState({ text: '没有找到相关视频' })
        }
        .layoutWeight(1)
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
            } else {
              LoadingFooter({ text: '加载中…' })
            }
          }
        }
        .cachedCount(3)
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 12, endMargin: 12 })
        .onReachEnd(() => {
          this.loadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
  }
}
