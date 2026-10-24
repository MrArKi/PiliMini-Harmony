/** 一个分组只在首次选中时取数；离开分组保留游标、数据源和滚动位置。 */
import { FollowSession, FollowItem, FollowPage } from '../../model/follow';
import { FrameCallback } from '@ohos.arkui.UIContext';
import { FollowService } from '../../service/follow_service';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { onFollowChanged, FollowChanged } from '../../infra/event/app_events';
import { BasicDataSource } from '../../common/list_data_source';
import { FollowItemView } from './FollowItemView';
import { EmptyState, ErrorRetry, LoadingFooter } from '../StateViews';

class FollowListFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(_time: number): void { this.action(); this.action = () => {}; }
}
interface FollowListRequest { generation: number; session: FollowSession; tagid: number; order: string; relations: number; }

@Component
export struct FollowList {
  session: FollowSession = { cookie: '', csrf: '', account: '', revision: -1 };
  @Prop @Watch('resetSource') tagid: number = -999;
  @Prop @Watch('activate') active: boolean = false;
  @Prop @Watch('resetOrder') orderType: string = '';
  @Prop @Watch('refreshRequested') refreshTick: number = 0;
  onRelation: (item: FollowItem) => void = () => {};
  onTotal: (tagid: number, total: number) => void = () => {};
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State firstLoaded: boolean = false;
  @State count: number = 0;
  @State error: string = '';
  @State footerError: string = '';
  @State rangeHint: string = '';
  @State hasMore: boolean = true;
  @State manualMore: boolean = false;
  @Prop busyMid: number = 0;
  @StorageProp('navBarHeight') navH: number = 0;
  private ds: BasicDataSource<FollowItem> = new BasicDataSource<FollowItem>();
  private rows: FollowItem[] = [];
  private scroller: Scroller = new Scroller();
  private nextPage: number = 1;
  private generation: number = 0;
  private destroyed: boolean = false;
  private reloading: boolean = false;
  private dirty: boolean = false;
  private rawCount: number = 0;
  private relationVersion: number = 0;
  private excluded: Set<number> = new Set<number>();
  private seen: Set<number> = new Set<number>();
  private offRelation: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.destroyed = false;
    this.offRelation = onFollowChanged((event: FollowChanged): void => {
      if (this.destroyed || event.revision !== this.session.revision
        || event.revision !== CookieStore.sessionRevision()) { return; }
      this.relationVersion++;
      if (event.followed) {
        this.excluded.delete(event.mid);
        this.refreshRequested();
        return;
      }
      this.excluded.add(event.mid);
      if (this.rows.some((item: FollowItem): boolean => item.mid === event.mid)) {
        this.removeRow(event.mid);
      }
    });
    this.activate();
  }
  aboutToDisappear(): void {
    this.destroyed = true; this.generation++;
    if (this.offRelation) { this.offRelation(); this.offRelation = undefined; }
  }
  private activate(): void {
    if (this.active && !this.reloading && (!this.firstLoaded || this.dirty)) { this.reload(); }
  }
  private invalidate(): void {
    this.generation++;
    this.reloading = false; this.loading = false; this.refreshing = false; this.loadingMore = false; this.dirty = true;
  }
  private resetSource(): void {
    this.invalidate(); this.firstLoaded = false; this.rows = []; this.count = 0;
    this.ds.reload([]); this.seen.clear(); this.excluded.clear();
    this.nextPage = 1; this.rawCount = 0;
    if (this.active) { this.reload(); }
  }
  private resetOrder(): void {
    this.invalidate(); this.firstLoaded = false; this.rows = []; this.count = 0;
    this.ds.reload([]); this.seen.clear(); this.nextPage = 1; this.rawCount = 0;
    if (this.active) { this.reload(); }
  }
  private refreshRequested(): void {
    // 隐藏分组的在途响应也必须作废，不能在返回时覆盖分组编辑后的名单。
    this.invalidate(); if (this.active) { this.reload(); }
  }
  private request(): FollowListRequest {
    return { generation: this.generation, session: this.session, tagid: this.tagid, order: this.orderType,
      relations: this.relationVersion };
  }
  private valid(request: FollowListRequest): boolean {
    return !this.destroyed && request.generation === this.generation
      && request.session.revision === CookieStore.sessionRevision()
      && request.session.revision === this.session.revision && request.session.account === this.session.account
      && request.tagid === this.tagid && request.order === this.orderType;
  }
  private page(page: number, request: FollowListRequest): Promise<FollowPage> {
    return request.tagid === -999 ? FollowService.list(request.session, page, request.order) :
      FollowService.groupMembers(request.session, request.tagid, page, request.order);
  }
  private resetPosition(request: FollowListRequest): void {
    this.getUIContext().postFrameCallback(new FollowListFrame((): void => {
      if (this.valid(request)) { try { this.scroller.scrollTo({ xOffset: 0, yOffset: 0 }); } catch (_) {} }
    }));
  }
  private removeRow(mid: number): void {
    const index: number = this.rows.findIndex((item: FollowItem): boolean => item.mid === mid);
    if (index < 0) { return; }
    let offset: number = 0;
    try { offset = this.scroller.currentOffset().yOffset; } catch (_) {}
    const request: FollowListRequest = this.request();
    this.rows.splice(index, 1);
    this.count = this.rows.length;
    this.ds.reload(this.rows);
    this.getUIContext().postFrameCallback(new FollowListFrame((): void => {
      if (this.valid(request)) { try { this.scroller.scrollTo({ xOffset: 0, yOffset: offset }); } catch (_) {} }
    }));
  }
  private async reload(): Promise<void> {
    if (this.destroyed || this.reloading || this.session.revision !== CookieStore.sessionRevision()) { return; }
    this.generation++;
    this.reloading = true;
    const request: FollowListRequest = this.request();
    this.loading = !this.firstLoaded; this.refreshing = this.firstLoaded; this.loadingMore = false;
    this.error = ''; this.footerError = ''; this.rangeHint = ''; this.manualMore = false;
    this.dirty = true;
    try {
      const result: FollowPage = await this.page(1, request);
      if (!this.valid(request)) { return; }
      this.seen.clear();
      this.rows = this.unique(result.items); this.ds.reload(this.rows); this.count = this.rows.length;
      this.rawCount = result.items.length;
      this.nextPage = result.nextPage; this.hasMore = result.hasMore; this.firstLoaded = true; this.dirty = false;
      this.manualMore = result.hasMore && this.rows.length === 0;
      if (this.manualMore) {
        this.rangeHint = '本页未返回新的有效关注，可手动继续加载';
      } else if (!result.hasMore && result.total >= 0 && this.rawCount < result.total) {
        this.rangeHint = '接口报告共' + result.total.toString() + '项，已显示当前可获取范围';
      }
      this.resetPosition(request);
      // 请求期间取消关注后的总数由父页成功事件刷新，不能再被旧首页统计覆盖。
      if (result.total >= 0 && request.relations === this.relationVersion) { this.onTotal(request.tagid, result.total); }
    } catch (e) { if (this.valid(request)) { this.error = (e as Error).message || '加载失败，请重试'; } }
    finally { if (this.valid(request)) { this.reloading = false; this.loading = false; this.refreshing = false; } }
  }
  private unique(items: FollowItem[]): FollowItem[] {
    return items.filter((item: FollowItem): boolean => {
      if (this.seen.has(item.mid)) { return false; }
      this.seen.add(item.mid); return !this.excluded.has(item.mid);
    });
  }
  private async more(manual: boolean = false): Promise<void> {
    if (this.loading || this.refreshing || this.loadingMore || !this.firstLoaded || !this.hasMore || !this.active
      || (this.manualMore && !manual)) { return; }
    this.loadingMore = true; this.footerError = ''; const request: FollowListRequest = this.request();
    const page: number = this.nextPage;
    try {
      const result: FollowPage = await this.page(page, request);
      if (!this.valid(request)) { return; }
      const extra: FollowItem[] = this.unique(result.items);
      this.rows = this.rows.concat(extra); this.ds.append(extra); this.count = this.rows.length;
      this.rawCount += result.items.length;
      this.hasMore = result.hasMore && result.nextPage > page;
      this.manualMore = this.hasMore && extra.length === 0; this.rangeHint = '';
      if (this.manualMore) {
        this.rangeHint = '本页未返回新的有效关注，可手动继续加载';
      } else if (!this.hasMore && result.total >= 0 && this.rawCount < result.total) {
        this.rangeHint = '接口报告共' + result.total.toString() + '项，已显示当前可获取范围';
      }
      this.nextPage = result.nextPage;
    } catch (e) { if (this.valid(request)) { this.footerError = (e as Error).message || '加载失败，点击重试'; } }
    finally { if (this.valid(request)) { this.loadingMore = false; } }
  }
  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      List({ scroller: this.scroller }) {
        if (this.loading) {
          ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], (n: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Column().width(45).height(45).borderRadius(23).backgroundColor($r('app.color.btn_soft_bg'))
                Column({ space: 8 }) {
                  Column().width(96).height(14).borderRadius(3).backgroundColor($r('app.color.btn_soft_bg'))
                  Column().width('75%').height(13).borderRadius(3).backgroundColor($r('app.color.btn_soft_bg'))
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.padding({ left: 12, right: 12, top: 10, bottom: 10 }).width('100%')
            }
          }, (n: number): string => 'follow_skeleton_' + n.toString())
        } else if (this.error.length > 0 && !this.firstLoaded) {
          ListItem() { ErrorRetry({ text: this.error, onRetry: (): void => { this.reload(); } }) }
        } else {
          if (this.error.length > 0) {
            ListItem() { Text(this.error + '，点击重试').fontSize(13).fontColor($r('app.color.brand_pink'))
              .width('100%').padding(12).onClick((): void => { this.reload(); }) }
          }
          LazyForEach(this.ds, (item: FollowItem) => {
            ListItem() { FollowItemView({ item: item, owner: true, busy: item.mid === this.busyMid,
              onRelation: (value: FollowItem): void => { this.onRelation(value); } }) }
          }, (item: FollowItem): string => item.mid.toString())
          if (this.count === 0) { ListItem() { EmptyState({ text: this.hasMore ? '当前页没有可显示的关注' : '暂无关注' }) } }
          ListItem() {
            if (this.footerError.length > 0) {
              Text(this.footerError).fontSize(12).fontColor($r('app.color.brand_pink')).padding(20).width('100%')
                .textAlign(TextAlign.Center).onClick((): void => { this.more(true); })
            } else if (this.rangeHint) {
              Column({ space: 8 }) {
                Text(this.rangeHint).fontSize(12).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
                if (this.hasMore) {
                  Button(this.loadingMore ? '加载中…' : '继续加载下一页').fontSize(13).enabled(!this.loadingMore)
                    .onClick((): void => { this.more(true); })
                }
              }.padding(20).width('100%')
            } else {
              LoadingFooter({ loading: this.loadingMore, text: this.loadingMore ? '加载中…' : this.hasMore ? '继续加载' : '没有更多了' })
                .onClick((): void => { this.more(true); })
            }
          }
          ListItem() { Column().height(100 + this.navH) }
        }
      }.width('100%').height('100%').cachedCount(2).edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
        .onReachEnd((): void => { if (!this.footerError) { this.more(); } }).id('follow_list_' + this.tagid.toString())
    }.width('100%').height('100%').onRefreshing((): void => { this.reload(); })
  }
}
