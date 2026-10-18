/**
 * 缓存管理／离线缓存（2026-10-12 对齐 Nara 实拍 31）：
 *  - 顶部「全部视频(N) / 文件夹(M)」分段 tab（下划线）
 *  - 列表行：封面 + 清晰度角标(右上) + 时长角标(右下) + 【视频】标题 + 分P 副标题 + 大小·UP名 + ⋮ 菜单
 *  - 文件夹页：文件夹行（数量）+ 长按重命名/删除 + 新建；点文件夹 → 回到列表并按其筛选
 *  - 「选择」进入多选：全选 / 删除(N)（确认弹窗）/ 移动到文件夹（含新建）
 *  - 条目点击：已完成 → 播放；多分P 可展开（分批展示）
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AsyncImage } from '../../components/AsyncImage';
import { EmptyState } from '../../components/StateViews';
import { DownloadService, DownloadTask, DlFolder, formatSize, qualityLabel } from '../../service/download_service';
import { formatDuration } from '../../components/VideoCard';
import { onAppBackground, onAppForeground } from '../../infra/event/app_events';

/** 按 bvid 聚合的条目（多分P 分批展示） */
class DlEntry {
  bvid: string = '';
  title: string = '';
  cover: string = '';
  folderId: string = '';
  tasks: DownloadTask[] = [];
}

@Entry
@Component
struct DownloadPage {
  @State tasks: DownloadTask[] = [];
  @State total: number = 0;
  @State folders: DlFolder[] = [];
  @State folderFilter: string = '';
  @State selMode: boolean = false;
  @State selCids: number[] = [];
  @State expandedBvids: string[] = [];
  @State sheetShown: boolean = false;
  @State sheetKind: number = 1; // 1=行菜单 2=移动 3=文件夹名称
  private returnToMove: boolean = false;

  @State folderName: string = '';
  /** 0=全部视频 1=文件夹 */
  @State tab: number = 0;
  /** 行内 ⋮ 菜单当前条目下标（-1 = 关闭） */
  private menuBvid: string = '';
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  private editingFolderId: string = '';
  private destroyed: boolean = false;
  private pageVisible: boolean = false;
  private appInBackground: boolean = false;
  private offBg: (() => void) | undefined = undefined;
  private offFg: (() => void) | undefined = undefined;
  private svcChange: () => void = () => {
    if (this.pageVisible && !this.appInBackground) { this.refresh(); }
  };

  aboutToAppear(): void {
    const ctx = getContext(this) as common.Context;
    DownloadService.init(ctx);
    DownloadService.load().then(() => {
      if (!this.destroyed && this.pageVisible && !this.appInBackground) {
        this.refresh();
      }
    });
    DownloadService.onChange(this.svcChange);
    // 服务层已在下载中按文件大小兜底并notify，页面不重复设置轮询。
    this.offBg = onAppBackground((): void => { this.appInBackground = true; });
    this.offFg = onAppForeground((): void => {
      this.appInBackground = false;
      if (this.pageVisible) { this.refresh(); }
    });
  }

  onPageShow(): void { this.pageVisible = true; this.refresh(); }
  onPageHide(): void { this.pageVisible = false; }

  aboutToDisappear(): void {
    this.destroyed = true;
    if (this.offBg !== undefined) { this.offBg(); this.offBg = undefined; }
    if (this.offFg !== undefined) { this.offFg(); this.offFg = undefined; }
    DownloadService.offChange(this.svcChange);
  }

  private refresh(): void {
    this.tasks = DownloadService.list().slice();
    this.folders = DownloadService.folderList().slice();
    this.total = DownloadService.totalBytes();
  }

  // ===== 聚合（按 bvid 分批） =====

  private entries(): DlEntry[] {
    const out: DlEntry[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      const t: DownloadTask = this.tasks[i];
      if (this.folderFilter.length > 0 && t.folderId !== this.folderFilter) {
        continue;
      }
      let e: DlEntry | undefined = undefined;
      for (let j = 0; j < out.length; j++) {
        if (out[j].bvid === t.bvid) {
          e = out[j];
          break;
        }
      }
      if (e === undefined) {
        e = new DlEntry();
        e.bvid = t.bvid;
        e.title = t.title;
        e.cover = t.cover;
        e.folderId = t.folderId;
        out.push(e);
      }
      e.tasks.push(t);
    }
    return out;
  }

  /** Builder从页面State读取当前快照，行身份只用bvid，封面不随进度重建。 */
  private entryFor(bvid: string): DlEntry {
    return this.entries().find((entry: DlEntry): boolean => entry.bvid === bvid) || new DlEntry();
  }

  private statusText(t: DownloadTask): string {
    if (t.status === 'downloading') {
      if (t.totalSize > 0) {
        return '下载中 ' + t.progress.toString() + '% · ' + formatSize(t.receivedSize) + ' / ' + formatSize(t.totalSize);
      }
      return '下载中 · 已下载 ' + formatSize(t.receivedSize);
    }
    if (t.status === 'paused') {
      return '已暂停 ' + t.progress.toString() + '%';
    }
    if (t.status === 'done') {
      return '已完成 · ' + formatSize(t.totalSize);
    }
    if (t.status === 'failed') {
      return '失败 · ' + t.errMsg;
    }
    return '排队中';
  }

  /** 条目聚合状态行 */
  private entryStatus(e: DlEntry): string {
    let done: number = 0;
    let doneSize: number = 0;
    let downloading: DownloadTask | undefined = undefined;
    let paused: DownloadTask | undefined = undefined;
    let failed: number = 0;
    for (let i = 0; i < e.tasks.length; i++) {
      const t: DownloadTask = e.tasks[i];
      if (t.status === 'done') {
        done++;
        doneSize += t.totalSize;
      } else if (t.status === 'downloading') {
        downloading = t;
      } else if (t.status === 'paused') {
        paused = t;
      } else if (t.status === 'failed') {
        failed++;
      }
    }
    if (downloading !== undefined) {
      const prefix: string = e.tasks.length > 1
        ? ('下载中 (' + (done + 1).toString() + '/' + e.tasks.length.toString() + ') ')
        : '';
      return prefix + this.statusText(downloading);
    }
    if (done === e.tasks.length) {
      return '已完成 · ' + formatSize(doneSize)
        + (e.tasks.length > 1 ? ' · ' + e.tasks.length.toString() + ' 个分P' : '');
    }
    let parts: string[] = [];
    if (done > 0) {
      parts.push('已完成 ' + done.toString() + '/' + e.tasks.length.toString());
    }
    if (paused !== undefined) {
      parts.push('已暂停');
    }
    if (failed > 0) {
      parts.push('失败 ' + failed.toString());
    }
    if (parts.length === 0) {
      parts.push('排队中');
    }
    return parts.join(' · ');
  }

  /** 当前进行中的任务（进度条用） */
  private activeTask(e: DlEntry): DownloadTask | undefined {
    for (let i = 0; i < e.tasks.length; i++) {
      if (e.tasks[i].status === 'downloading') {
        return e.tasks[i];
      }
    }
    return undefined;
  }

  // ===== 条目操作 =====

  private playTask(t: DownloadTask, e: DlEntry): void {
    // 本地播放走视频详情页（与在线播放完全同一套播放器 UI/手势，用户指示 2026-10-11）
    const title: string = t.part.length > 0 ? (e.title + ' · ' + t.part) : e.title;
    const params: Record<string, string> = {
      'bvid': e.bvid,
      'localPath': t.filePath,
      'cid': t.cid.toString(),
      'title': title
    };
    router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
  }

  private toggleTask(t: DownloadTask, e: DlEntry): void {
    if (this.selMode) {
      this.toggleSelect(e);
      return;
    }
    if (t.status === 'done') {
      this.playTask(t, e);
    } else if (t.status === 'downloading') {
      DownloadService.pause(t.cid);
    } else if (t.status === 'paused' || t.status === 'failed') {
      DownloadService.resume(t.cid);
    }
  }

  /** 普通模式点条目：完成 → 播放第一个完成的分P；下载中 → 暂停；暂停/失败 → 继续 */
  private onEntryTap(e: DlEntry): void {
    if (this.selMode) {
      this.toggleSelect(e);
      return;
    }
    for (let i = 0; i < e.tasks.length; i++) {
      if (e.tasks[i].status === 'done') {
        this.playTask(e.tasks[i], e);
        return;
      }
    }
    const first: DownloadTask = e.tasks[0];
    this.toggleTask(first, e);
  }

  private isSelected(e: DlEntry): boolean {
    for (let i = 0; i < e.tasks.length; i++) {
      if (this.selCids.indexOf(e.tasks[i].cid) < 0) {
        return false;
      }
    }
    return e.tasks.length > 0;
  }

  private toggleSelect(e: DlEntry): void {
    this.setSelected(e, !this.isSelected(e));
  }

  private setSelected(e: DlEntry, selected: boolean): void {
    if (this.isSelected(e) === selected) { return; }
    const next: number[] = this.selCids.slice();
    for (let i = 0; i < e.tasks.length; i++) {
      const cid: number = e.tasks[i].cid;
      const idx: number = next.indexOf(cid);
      if (!selected) {
        if (idx >= 0) {
          next.splice(idx, 1);
        }
      } else if (idx < 0) {
        next.push(cid);
      }
    }
    this.selCids = next;
  }

  private selectAll(): void {
    const es: DlEntry[] = this.entries();
    let all: boolean = es.length > 0;
    for (let i = 0; i < es.length; i++) {
      if (!this.isSelected(es[i])) {
        all = false;
        break;
      }
    }
    const next: number[] = [];
    if (!all) {
      for (let i = 0; i < es.length; i++) {
        for (let j = 0; j < es[i].tasks.length; j++) {
          next.push(es[i].tasks[j].cid);
        }
      }
    }
    this.selCids = next;
  }

  private confirmDelete(): void {
    const n: number = this.selCids.length;
    if (n === 0) {
      return;
    }
    AlertDialog.show({
      title: '删除缓存',
      message: '确认删除选中的 ' + n.toString() + ' 个视频？对应文件将一并删除。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E54D42',
        action: () => {
          this.doDelete();
        }
      }
    });
  }

  private async doDelete(): Promise<void> {
    const cids: number[] = this.selCids.slice();
    this.selMode = false;
    this.selCids = [];
    for (let i = 0; i < cids.length; i++) {
      await DownloadService.remove(cids[i]);
    }
    promptAction.showToast({ message: '已删除 ' + cids.length.toString() + ' 个视频' });
    this.refresh();
  }

  private selectedBvids(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      const t: DownloadTask = this.tasks[i];
      if (this.selCids.indexOf(t.cid) >= 0 && out.indexOf(t.bvid) < 0) {
        out.push(t.bvid);
      }
    }
    return out;
  }

  private async moveTo(folderId: string): Promise<void> {
    const bvids: string[] = this.selectedBvids();
    await DownloadService.setFolder(bvids, folderId);
    promptAction.showToast({ message: folderId.length > 0 ? '已移动到文件夹' : '已移出文件夹' });
    this.sheetShown = false;
    this.exitSelect();
  }

  private exitSelect(): void {
    this.selMode = false;
    this.selCids = [];
  }

  private async submitFolderName(): Promise<void> {
    const name: string = this.folderName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '请输入文件夹名称' });
      return;
    }
    if (this.editingFolderId.length > 0) {
      await DownloadService.renameFolder(this.editingFolderId, name);
    } else {
      await DownloadService.addFolder(name);
    }
    this.sheetKind = this.returnToMove ? 2 : 3;
    this.sheetShown = this.returnToMove;
    this.returnToMove = false;
    this.folderName = '';
    this.editingFolderId = '';
  }

  private confirmRemoveFolder(f: DlFolder): void {
    AlertDialog.show({
      title: '删除文件夹',
      message: '删除「' + f.title + '」后，其中的视频将移出文件夹（不删除文件）。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E54D42',
        action: () => {
          if (this.folderFilter === f.id) {
            this.folderFilter = '';
          }
          DownloadService.removeFolder(f.id);
          promptAction.showToast({ message: '已删除文件夹' });
        }
      }
    });
  }

  private onFolderLongPress(f: DlFolder): void {
    AlertDialog.show({
      title: f.title,
      message: '重命名或删除该文件夹',
      autoCancel: true,
      primaryButton: {
        value: '重命名',
        action: () => {
          this.returnToMove = false;
          this.editingFolderId = f.id;
          this.folderName = f.title;
          this.sheetKind = 3;
          this.sheetShown = true;
        }
      },
      secondaryButton: {
        value: '删除文件夹',
        fontColor: '#E54D42',
        action: () => {
          this.confirmRemoveFolder(f);
        }
      }
    });
  }

  // ===== UI =====

  @Builder
  TabBar() {
    Row() {
      Column() {
        Text('全部视频(' + this.entries().length.toString() + ')')
          .fontSize(14)
          .fontWeight(this.tab === 0 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.tab === 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        Divider()
          .strokeWidth(2)
          .color(this.tab === 0 ? $r('app.color.brand_pink') : Color.Transparent)
          .width(26)
          .margin({ top: 6 })
      }
      .layoutWeight(1)
      .onClick(() => {
        this.tab = 0;
      })

      Column() {
        Text('文件夹(' + this.folders.length.toString() + ')')
          .fontSize(14)
          .fontWeight(this.tab === 1 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.tab === 1 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        Divider()
          .strokeWidth(2)
          .color(this.tab === 1 ? $r('app.color.brand_pink') : Color.Transparent)
          .width(26)
          .margin({ top: 6 })
      }
      .layoutWeight(1)
      .onClick(() => {
        this.tab = 1;
      })
    }
    .width('100%')
    .height(46)
    .padding({ top: 6 })
    .backgroundColor($r('app.color.card_bg'))
  }

  private folderCount(f: DlFolder): number {
    let n: number = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].folderId === f.id) {
        n++;
      }
    }
    return n;
  }

  @Builder
  FolderRowItem(f: DlFolder) {
    Row({ space: 12 }) {
      Image($r('app.media.icon_folder'))
        .width(26)
        .height(26)
        .fillColor($r('app.color.text_secondary'))
      Column({ space: 3 }) {
        Text(f.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.folderCount(f).toString() + ' 个视频')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Image($r('app.media.icon_arrow_right'))
            .width(22).height(22)
        .fillColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      this.folderFilter = f.id;
      this.tab = 0;
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.onFolderLongPress(f);
        })
    )
  }

  @Builder
  FolderList() {
    List() {
      ForEach(this.folders, (f: DlFolder) => {
        ListItem() {
          this.FolderRowItem(f)
        }
      }, (f: DlFolder) => 'fl_' + f.id + ':' + f.title)

      ListItem() {
        Row({ space: 8 }) {
          Image($r('app.media.icon_folder_add')).width(20).height(20).fillColor($r('app.color.brand_pink'))
          Text('新建文件夹')
            .fontSize(14)
            .fontColor($r('app.color.brand_pink'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          this.returnToMove = false;
          this.editingFolderId = '';
          this.folderName = '';
          this.sheetKind = 3;
          this.sheetShown = true;
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 54, endMargin: 16 })

  }

  /** 行内 ⋮ 菜单（播放 / 移入文件夹 / 删除） */
  @Builder
  SheetContent() {
    Column() {
      if (this.sheetKind === 1) { this.RowMenu() }
      else if (this.sheetKind === 2) { this.MoveSheet() }
      else { this.FolderNameSheet() }
    }.width('100%')
  }

  @Builder
  RowMenu() {
    Column() {
      Text('播放')
        .fontSize(15).fontColor($r('app.color.text_primary')).width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          const bvid: string = this.menuBvid;
          this.sheetShown = false;
          this.playEntry(bvid);
        })
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
      Text('移入文件夹')
        .fontSize(15).fontColor($r('app.color.text_primary')).width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          const e: DlEntry | undefined = this.entries().find((item: DlEntry): boolean => item.bvid === this.menuBvid);
          if (e !== undefined) {
            this.selCids = e.tasks.map((t: DownloadTask): number => t.cid);
            this.sheetKind = 2;
          }
        })
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
      Text('删除')
        .fontSize(15).fontColor('#E54D42').width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          const e: DlEntry | undefined = this.entries().find((item: DlEntry): boolean => item.bvid === this.menuBvid);
          this.sheetShown = false;
          if (e !== undefined) {
            this.selCids = e.tasks.map((t: DownloadTask): number => t.cid);
            this.confirmDelete();
          }
        })
    }.width('100%').backgroundColor($r('app.color.card_bg'))
  }

  /** ⋮ → 播放该条目的第一个已完成分P */
  private playEntry(bvid: string): void {
    const e: DlEntry | undefined = this.entries().find((item: DlEntry): boolean => item.bvid === bvid);
    if (e === undefined) { return; }
    for (let i = 0; i < e.tasks.length; i++) {
      if (e.tasks[i].status === 'done') {
        if (e.tasks.length > 1) {
          const next: string[] = this.expandedBvids.slice();
          if (next.indexOf(e.bvid) < 0) {
            next.push(e.bvid);
          }
          this.expandedBvids = next;
        }
        this.playTask(e.tasks[i], e);
        return;
      }
    }
    promptAction.showToast({ message: '该视频尚未下载完成' });
  }

  /** 分P 行（分批展开后的子项） */
  @Builder
  PartRow(t: DownloadTask, e: DlEntry) {
    Row({ space: 8 }) {
      Image($r('app.media.icon_play'))
        .width(14)
        .height(14)
        .fillColor(t.status === 'done' ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
        .opacity(t.status === 'done' ? 1 : 0.35)
      Column({ space: 2 }) {
        Text(t.part.length > 0 ? t.part : '分P')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.statusText(t))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (t.status === 'downloading') {
        Text('暂停')
          .fontSize(12)
          .fontColor($r('app.color.brand_pink'))
          .padding({ left: 8, right: 4 })
          .onClick(() => {
            DownloadService.pause(t.cid);
          })
      } else if (t.status === 'paused' || t.status === 'failed') {
        Text('继续')
          .fontSize(12)
          .fontColor($r('app.color.brand_pink'))
          .padding({ left: 8, right: 4 })
          .onClick(() => {
            DownloadService.resume(t.cid);
          })
      }
    }
    .width('100%')
    .padding({ left: 24, right: 0, top: 8, bottom: 8 })
    .onClick(() => {
      this.toggleTask(t, e);
    })
  }

  @Builder
  EntryItem(bvid: string) {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        if (this.selMode) {
          Checkbox()
            .select(this.isSelected(this.entryFor(bvid)))
            .selectedColor($r('app.color.brand_pink'))
            .width(20)
            .height(20)
            .onChange((selected: boolean) => {
              this.setSelected(this.entryFor(bvid), selected);
            })
            .onTouch((event: TouchEvent) => {
              event.stopPropagation();
            })
        }
        // 封面：右上清晰度角标 + 右下时长角标
        Stack({ alignContent: Alignment.TopEnd }) {
          Stack({ alignContent: Alignment.BottomEnd }) {
            Column() {
              AsyncImage({ src: this.entryFor(bvid).cover, w: 224, h: 126 })
            }
            .width('100%')
            .height('100%')

            if (this.entryFor(bvid).tasks.length > 0 && this.entryFor(bvid).tasks[0].duration > 0) {
              Text(formatDuration(this.entryFor(bvid).tasks[0].duration))
                .fontSize(10)
                .fontColor('#FFFFFF')
                .backgroundColor('#80000000')
                .borderRadius(4)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ right: 6, bottom: 6 })
            }
          }
          .width('100%')
          .height('100%')

          if (this.entryFor(bvid).tasks.length > 0) {
            Text(qualityLabel(this.entryFor(bvid).tasks[0].quality))
              .fontSize(10)
              .fontColor('#FFFFFF')
              .backgroundColor('#80000000')
              .borderRadius(4)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ right: 6, top: 6 })
          }
        }
        .width(112)
        .height(63)
        .borderRadius(6)
        .clip(true)
        .backgroundColor($r('app.color.btn_soft_bg'))

        Column({ space: 4 }) {
          Text('【视频】' + this.entryFor(bvid).title)
            .fontSize(14)
            .lineHeight(19)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.entryFor(bvid).tasks.length > 0 && this.entryFor(bvid).tasks[0].part.length > 0) {
            Text(this.entryFor(bvid).tasks[0].part)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          Text(this.entryMeta(this.entryFor(bvid)))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.entryStatus(this.entryFor(bvid)))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.activeTask(this.entryFor(bvid)) !== undefined) {
            Progress({ value: (this.activeTask(this.entryFor(bvid)) as DownloadTask).progress, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(4)
              .color($r('app.color.brand_pink'))
              .backgroundColor($r('app.color.divider'))
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (!this.selMode) {
          Image($r('app.media.icon_more'))
            .width(22).height(22)
            .fillColor($r('app.color.text_secondary'))
            .padding({ left: 4, right: 2, top: 2, bottom: 2 })
            .onClick(() => {
              this.menuBvid = this.entryFor(bvid).bvid;
              this.sheetKind = 1;
              this.sheetShown = true;
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 多分P：分批展开
      if (this.entryFor(bvid).tasks.length > 1) {
        Text(this.expandedBvids.indexOf(this.entryFor(bvid).bvid) >= 0
          ? ('收起分P（共 ' + this.entryFor(bvid).tasks.length.toString() + ' 个）')
          : ('共 ' + this.entryFor(bvid).tasks.length.toString() + ' 个分P，点击展开'))
          .fontSize(12)
          .fontColor($r('app.color.brand_pink'))
          .width('100%')
          .onClick(() => {
            const next: string[] = this.expandedBvids.slice();
            const idx2: number = next.indexOf(this.entryFor(bvid).bvid);
            if (idx2 >= 0) {
              next.splice(idx2, 1);
            } else {
              next.push(this.entryFor(bvid).bvid);
            }
            this.expandedBvids = next;
          })
        if (this.expandedBvids.indexOf(this.entryFor(bvid).bvid) >= 0) {
          ForEach(this.entryFor(bvid).tasks, (t: DownloadTask) => {
            this.PartRow(t, this.entryFor(bvid))
          }, (t: DownloadTask) => 'pt_' + t.cid.toString() + '_' + t.status)
        }
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .onClick(() => {
      this.onEntryTap(this.entryFor(bvid));
    })
  }

  /** 行内元信息：大小 + UP 名（Nara 「258.45M 小仙听国学」） */
  private entryMeta(e: DlEntry): string {
    let size: number = 0;
    for (let i = 0; i < e.tasks.length; i++) {
      const t: DownloadTask = e.tasks[i];
      size += t.totalSize > 0 ? t.totalSize : t.receivedSize;
    }
    const up: string = e.tasks.length > 0 ? e.tasks[0].upName : '';
    const sz: string = formatSize(size);
    return up.length > 0 ? (sz + '  ' + up) : sz;
  }

  /** 文件夹 id → 名称 */
  private folderTitle(id: string): string {
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].id === id) {
        return this.folders[i].title;
      }
    }
    return '未分组';
  }

  @Builder
  MoveSheet() {
    Column() {
      Text('移动到文件夹')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 12 })
      if (this.folderFilter.length > 0 || this.selHasFolder()) {
        Row() {
          Text('移出文件夹')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14, bottom: 14 })
        .onClick(() => {
          this.moveTo('');
        })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 20 })
      }
      ForEach(this.folders, (f: DlFolder) => {
        Row() {
          Text(f.title)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Image($r('app.media.icon_arrow_right'))
            .width(22).height(22)
            .fillColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14, bottom: 14 })
        .onClick(() => {
          this.moveTo(f.id);
        })
      }, (f: DlFolder) => 'mv_' + f.id + ':' + f.title)

      Row({ space: 8 }) {
        Image($r('app.media.icon_folder_add')).width(20).height(20).fillColor($r('app.color.brand_pink'))
        Text('新建文件夹')
          .fontSize(15)
          .fontColor($r('app.color.brand_pink'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 14 })
      .onClick(() => {
        this.returnToMove = true;
        this.editingFolderId = '';
        this.folderName = '';
        this.sheetKind = 3;
        this.sheetShown = true;
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
  }

  private selHasFolder(): boolean {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.selCids.indexOf(this.tasks[i].cid) >= 0 && this.tasks[i].folderId.length > 0) {
        return true;
      }
    }
    return false;
  }

  @Builder
  FolderNameSheet() {
    Column({ space: 12 }) {
      Text(this.editingFolderId.length > 0 ? '重命名文件夹' : '新建文件夹')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14 })

      TextInput({ text: this.folderName, placeholder: '文件夹名称' })
        .fontSize(15)
        .width('90%')
        .onChange((v: string) => {
          this.folderName = v;
        })

      Button('确定')
        .fontSize(14)
        .width('90%')
        .height(38)
        .borderRadius(19)
        .backgroundColor($r('app.color.brand_pink'))
        .onClick(() => {
          this.submitFolderName();
        })
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
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
      // 顶栏
      Row({ space: 8 }) {
        Image($r('app.media.icon_arrow_left'))
            .width(22).height(22)
          .fillColor($r('app.color.text_primary'))
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            router.back();
          })
        Text('离线缓存')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.tasks.length > 0) {
          Text(this.selMode ? '完成' : '选择')
            .fontSize(13)
            .fontColor($r('app.color.brand_pink'))
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              if (this.selMode) {
                this.exitSelect();
              } else {
                this.selMode = true;
              }
            })
        }
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
      .backgroundColor($r('app.color.card_bg'))

      // 全部视频 / 文件夹 分段 tab
      this.TabBar()

      // 占用统计
      Row() {
        Text('已用空间 ' + formatSize(this.total))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(this.tasks.length.toString() + ' 个视频')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.card_bg'))

      // 当前筛选提示（从文件夹 tab 点入）
      if (this.tab === 0 && this.folderFilter.length > 0) {
        Row({ space: 8 }) {
          Text('筛选：' + this.folderTitle(this.folderFilter))
            .fontSize(12)
            .fontColor($r('app.color.brand_pink'))
          Text('清除')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .onClick(() => {
              this.folderFilter = '';
            })
          Blank()
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.card_bg'))
      }

      if (this.tab === 1) {
        this.FolderList()
      } else if (this.entries().length === 0) {
        EmptyState({
          text: this.folderFilter.length > 0 ? '该文件夹暂无视频' : '暂无缓存任务\n可在视频详情页点「缓存」添加'
        })
      } else {
        List() {
          ForEach(this.entries(), (e: DlEntry, idx: number) => {
            ListItem() {
              this.EntryItem(e.bvid)
            }
          }, (e: DlEntry) => e.bvid)
        }
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 134 })
      }

      // 多选操作栏
      if (this.selMode) {
        Row({ space: 10 }) {
          Text('全选')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .onClick(() => {
              this.selectAll();
            })
          Blank()
          Text('移动到')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .onClick(() => {
              if (this.selCids.length > 0) {
                this.sheetKind = 2;
                this.sheetShown = true;
              }
            })
          Text('删除(' + this.selCids.length.toString() + ')')
            .fontSize(14)
            .fontColor(this.selCids.length > 0 ? '#E54D42' : $r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .onClick(() => {
              this.confirmDelete();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.card_bg'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .bindSheet($$this.sheetShown, this.SheetContent(), {
      height: this.sheetKind === 1 ? 178 : (this.sheetKind === 2 ? 420 : 260),
      dragBar: true,
      showClose: this.sheetKind !== 1,
      backgroundColor: $r('app.color.card_bg')
    })
  }
}
