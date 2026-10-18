/**
 * LazyForEach 数据源（spec-02 任务 2.3 通用封装）
 */
export class BasicDataSource<T> implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: T[] = [];

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
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  /** 追加（用于分页加载）：按增量通知，避免整表重建导致长列表卡顿 */
  append(items: T[]): void {
    const start: number = this.items.length;
    this.items = this.items.concat(items);
    for (let i = 0; i < this.listeners.length; i++) {
      for (let j = 0; j < items.length; j++) {
        this.listeners[i].onDataAdd(start + j);
      }
    }
  }

  /** 单条数据变化通知（如展开楼中楼） */
  notifyChange(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataChange(index);
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
