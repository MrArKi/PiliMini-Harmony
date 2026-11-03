/**
 * LazyForEach 数据源（spec-02 任务 2.3 通用封装）
 */
export class BasicDataSource<T> implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: T[] = [];
  private batchNotifications: boolean = false;

  /** 同一LazyForEach始终使用同一套通知API，批量模式供高频评论分页使用。 */
  constructor(batchNotifications: boolean = false) {
    this.batchNotifications = batchNotifications;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** 整体替换并通知刷新 */
  reload(items: T[]): void {
    this.items = this.batchNotifications ? items.slice() : items;
    for (let i = 0; i < this.listeners.length; i++) {
      if (this.batchNotifications) {
        this.listeners[i].onDatasetChange([{ type: DataOperationType.RELOAD }]);
      } else {
        this.listeners[i].onDataReloaded();
      }
    }
  }

  /** 追加（用于分页加载）：按增量通知，避免整表重建导致长列表卡顿 */
  append(items: T[]): void {
    if (items.length === 0) { return; }
    const start: number = this.items.length;
    if (this.batchNotifications) {
      for (let i: number = 0; i < items.length; i++) { this.items.push(items[i]); }
    } else {
      this.items = this.items.concat(items);
    }
    for (let i = 0; i < this.listeners.length; i++) {
      if (this.batchNotifications) {
        this.listeners[i].onDatasetChange([{ type: DataOperationType.ADD, index: start, count: items.length }]);
      } else {
        for (let j = 0; j < items.length; j++) {
          this.listeners[i].onDataAdd(start + j);
        }
      }
    }
  }

  /** 向前分页只通知插入区间，保留已有条目和定位锚点。 */
  prepend(items: T[]): void {
    if (items.length === 0) { return; }
    this.items = items.concat(this.items);
    for (let i: number = 0; i < this.listeners.length; i++) {
      if (this.batchNotifications) {
        this.listeners[i].onDatasetChange([{ type: DataOperationType.ADD, index: 0, count: items.length }]);
      } else {
        for (let j: number = 0; j < items.length; j++) { this.listeners[i].onDataAdd(j); }
      }
    }
  }

  /** 单条数据变化通知（如展开楼中楼） */
  notifyChange(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      if (this.batchNotifications) {
        this.listeners[i].onDatasetChange([{ type: DataOperationType.CHANGE, index: index }]);
      } else {
        this.listeners[i].onDataChange(index);
      }
    }
  }

  size(): number {
    return this.items.length;
  }

  /** 查找条目下标（-1 = 不在本数据源） */
  indexOf(item: T): number {
    return this.items.indexOf(item);
  }
}
