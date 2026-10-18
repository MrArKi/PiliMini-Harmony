/**
 * 通用分页状态机（代码质量重构 2026-10-11）
 * 消除首页/搜索/动态/收藏 4 个列表页重复的 loading/firstLoaded/error/hasMore/footer 逻辑。
 * 用法：页面以 @State pager: Pager<T> 持有（V1 状态可观测顶层属性变更），
 *       reload/loadMore 传入本页的取数闭包（游标统一为字符串，数字页码自行 parseInt）。
 */
import { BasicDataSource } from './list_data_source';

/** 单页返回（nextCursor 为字符串游标；数字页码用 toString/parseInt 转换） */
export interface PageData<T> {
  items: T[];
  hasMore: boolean;
  nextCursor: string;
}

export class Pager<T> {
  private generation: number = 0;
  /** 页面退场或数据源切换后，迟到结果不得再写入列表。 */
  cancel(): void {
    this.generation++;
    this.loading = false;
    this.loadingMore = false;
  }
  loading: boolean = false;
  firstLoaded: boolean = false;
  error: string = '';
  lastError: string = '';
  hasMore: boolean = true;
  footerText: string = '';
  loadingMore: boolean = false;
  cursor: string = '1';
  /** 首页游标（动态流为 ''）；reload 时回到该值 */
  initialCursor: string = '1';
  /** 错误文案（errorDetail=true 时用异常信息，否则用固定文案） */
  firstError: string = '加载失败，请检查网络';
  refreshError: string = '刷新失败，请稍后重试';
  moreError: string = '加载失败，滑动重试';
  noMoreText: string = '没有更多了';
  errorDetail: boolean = false;

  /**
   * 重置并加载首页。
   * @param force true 时忽略"加载中"保护（搜索等需要"后发起者覆盖"的场景）
   * @returns 是否成功
   */
  async reload(ds: BasicDataSource<T>, fetch: (cursor: string) => Promise<PageData<T>>,
    force: boolean = false): Promise<boolean> {
    if (this.loading && !force) {
      return false;
    }
    const generation: number = ++this.generation;
    this.loadingMore = false;
    this.loading = true;
    this.error = '';
    this.lastError = '';
    this.cursor = this.initialCursor;
    try {
      const r: PageData<T> = await fetch(this.cursor);
      if (generation !== this.generation) { return false; }
      ds.reload(r.items);
      this.hasMore = r.hasMore;
      this.cursor = r.nextCursor;
      this.firstLoaded = true;
      this.footerText = r.hasMore ? '' : this.noMoreText;
      return true;
    } catch (e) {
      if (generation !== this.generation) { return false; }
      const msg: string = (e as Error).message !== undefined ? (e as Error).message : '';
      this.lastError = msg;
      if (this.firstLoaded) {
        this.footerText = this.refreshError;
      } else {
        this.error = this.errorDetail && msg.length > 0 ? msg : this.firstError;
      }
      return false;
    } finally {
      if (generation === this.generation) { this.loading = false; }
    }
  }

  /** 触底加载下一页；成功返回 true，失败/被跳过返回 false */
  async loadMore(ds: BasicDataSource<T>, fetch: (cursor: string) => Promise<PageData<T>>): Promise<boolean> {
    if (this.loadingMore || this.loading || !this.hasMore || !this.firstLoaded) {
      return false;
    }
    this.loadingMore = true;
    const generation: number = this.generation;
    try {
      const r: PageData<T> = await fetch(this.cursor);
      if (generation !== this.generation) { return false; }
      ds.append(r.items);
      this.hasMore = r.hasMore;
      this.cursor = r.nextCursor;
      this.footerText = r.hasMore ? '' : this.noMoreText;
      return true;
    } catch (e) {
      if (generation !== this.generation) { return false; }
      const msg: string = (e as Error).message !== undefined ? (e as Error).message : '';
      this.lastError = msg;
      this.footerText = this.moreError;
      return false;
    } finally {
      if (generation === this.generation) { this.loadingMore = false; }
    }
  }
}
