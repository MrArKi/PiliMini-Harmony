/** Nara新版：下载中、文件夹、已缓存视频同页分区；范围各走独立路由。 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DownloadService, DownloadTask, DlFolder, formatSize } from '../../service/download_service';
import { DownloadFolderService } from '../../service/download_folder_service';
import { DownloadLibraryService, ContinueTarget } from '../../service/download_library_service';
import { DlEntry, OfflineContext, downloadKey } from '../../model/download';
import { BasicDataSource } from '../../common/list_data_source';
import { DownloadEntryCard } from '../../components/DownloadEntryCard';
import { AsyncImage } from '../../components/AsyncImage';
import { EmptyState, ErrorRetry } from '../../components/StateViews';
import { onAppBackground, onAppForeground } from '../../infra/event/app_events';
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
class LibraryRow {
  key: string = ''; kind: string = 'entry'; title: string = '';
  entry?: DlEntry; folder?: DlFolder; folderTasks: DownloadTask[] = [];
}
@Entry
@Component
struct DownloadPage {
  @State total: number = 0;
  @State error: string = '';
  @State loading: boolean = true;
  @State selecting: boolean = false;
  @State selected: number[] = [];
  @State rows: LibraryRow[] = [];
  @State continueTarget: ContinueTarget | undefined = undefined;
  @State sheetShown: boolean = false;
  @State sheetKind: string = 'menu';
  @State folderName: string = '';
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private ds: BasicDataSource<LibraryRow> = new BasicDataSource<LibraryRow>();
  private entries: DlEntry[] = [];
  private folders: DlFolder[] = [];
  private menu: DlEntry = new DlEntry();
  private editFolder: string = '';
  private nameFromPicker: boolean = false;
  private context: OfflineContext = new OfflineContext();
  private playContext: OfflineContext = new OfflineContext();
  private section: string = 'library';
  private pageTitle: string = '离线缓存';
  private signature: string = '';
  private activeTask: DownloadTask | undefined = undefined;
  private activeBytes: number = 0;
  private progressEntries: DlEntry[] = [];
  private destroyed: boolean = false;
  private visible: boolean = false;
  private appInBackground: boolean = false;
  private generation: number = 0;
  private offBg?: () => void;
  private offFg?: () => void;
  private changed: () => void = () => { if (this.visible && !this.appInBackground) { this.refresh(); } };
  aboutToAppear(): void {
    const pm = router.getParams() as Record<string, string> | undefined;
    this.section = pm?.['section'] || 'library';
    this.context = { scope: pm?.['scope'] || 'all', key: pm?.['key'] || '' };
    this.playContext = { scope: pm?.['playScope'] || this.context.scope, key: pm?.['playKey'] || this.context.key };
    this.pageTitle = pm?.['title'] || (this.section === 'tasks' ? '下载任务' : this.section === 'folders' ? '文件夹管理' : '离线缓存');
    DownloadService.init(getContext(this) as common.Context); DownloadService.onChange(this.changed);
    this.offBg = onAppBackground(() => { this.appInBackground = true; });
    this.offFg = onAppForeground(() => { this.appInBackground = false; if (this.visible) { this.refresh(); } });
    this.initialize();
  }
  onPageShow(): void { this.visible = true; this.refresh(); this.loadContinue(); }
  onPageHide(): void { this.visible = false; this.generation++; }
  aboutToDisappear(): void { this.destroyed = true; this.generation++; DownloadService.offChange(this.changed); this.offBg?.(); this.offFg?.(); }
  onBackPress(): boolean { if (this.selecting) { this.selecting = false; this.selected = []; return true; } return false; }
  private toast(message: string): void { promptAction.showToast({ message: message }); }
  private async initialize(): Promise<void> {
    try { await DownloadService.load(); if (this.destroyed) { return; } this.error = ''; this.loading = false; this.refresh(); this.loadContinue(); }
    catch (e) { if (!this.destroyed) { this.error = (e as Error).message; this.loading = false; } }
  }
  private async loadContinue(): Promise<void> {
    if (this.section !== 'library' || this.context.scope !== 'all') { return; }
    const generation: number = ++this.generation;
    try { await DownloadService.load(); const target = await DownloadLibraryService.continueTarget();
      if (!this.destroyed && this.visible && generation === this.generation) { this.continueTarget = target; }
    } catch (_) {}
  }
  private header(title: string): LibraryRow { const r = new LibraryRow(); r.key = 'header:' + title; r.kind = 'header'; r.title = title; return r; }
  private entryRow(e: DlEntry): LibraryRow { const r = new LibraryRow(); r.key = e.key; r.entry = e; return r; }
  private refresh(): void {
    if (this.destroyed || this.loading) { return; }
    const tasks: DownloadTask[] = DownloadService.list();
    // 进度不进入结构签名，不反复分组、扫描磁盘或销毁封面。
    const signature: string = DownloadService.structureRevision().toString();
    if (signature !== this.signature) {
      const folders = DownloadFolderService.list();
      this.total = tasks.reduce((n: number, t: DownloadTask): number => n + t.receivedSize, 0);
      this.activeTask = tasks.find((t: DownloadTask): boolean => t.status === 'downloading');
      this.activeBytes = this.activeTask?.receivedSize || 0;
      this.signature = signature; this.folders = folders;
      const filtered = tasks.filter((t: DownloadTask): boolean => this.section === 'tasks' ? t.status !== 'done' : t.status === 'done');
      this.entries = this.section === 'tasks' ? DownloadLibraryService.transfers(filtered) :
        DownloadLibraryService.groups(filtered, this.context, this.context.scope === 'all');
      const rows: LibraryRow[] = []; const root: boolean = this.section === 'library' && this.context.scope === 'all';
      if (root) {
        const active = tasks.find((t: DownloadTask): boolean => t.status === 'downloading') || tasks.find((t: DownloadTask): boolean => t.status !== 'done');
        if (active) { rows.push(this.header('下载中')); rows.push(this.entryRow(DownloadLibraryService.transfers([active])[0])); }
      }
      if (root || this.section === 'folders') {
        if (folders.length) { rows.push(this.header('文件夹')); }
        for (const f of folders) { const row = new LibraryRow(); row.key = 'folder:' + f.id; row.kind = 'folder'; row.folder = f;
          row.folderTasks = DownloadLibraryService.inScope(tasks.filter((t: DownloadTask): boolean => t.status === 'done'), { scope: 'folder', key: f.id }); rows.push(row); }
      }
      if (root && this.entries.length) { rows.push(this.header('已缓存视频')); }
      if (this.section !== 'folders') { for (const e of this.entries) { rows.push(this.entryRow(e)); } }
      this.progressEntries = [];
      for (const row of rows) { if (row.entry) {
        this.updateProgress(row.entry);
        if (this.activeTask && row.entry.tasks.includes(this.activeTask)) { this.progressEntries.push(row.entry); }
      } }
      this.rows = rows; this.ds.reload(rows); this.loadContinue();
    } else if (this.activeTask) {
      this.total += this.activeTask.receivedSize - this.activeBytes;
      this.activeBytes = this.activeTask.receivedSize;
      for (const e of this.progressEntries) { this.updateProgress(e); }
    }
  }
  private updateProgress(e: DlEntry): void {
    const t = e.tasks.find((v: DownloadTask): boolean => v.status === 'downloading') || e.tasks[0];
    const bytes = e.tasks.reduce((n: number, v: DownloadTask): number => n + v.receivedSize, 0);
    e.subtitle = formatSize(bytes) + (t.upName ? '  ' + t.upName : ''); e.progress = t.status === 'done' ? -1 : t.progress;
    e.statusText = t.status === 'done' ? (e.tasks.length > 1 ? e.tasks.length.toString() + '个视频 · 本地离线缓存' : '本地离线缓存') : t.status === 'downloading' ? '下载中 ' + t.progress.toString() + '%' : t.status === 'paused' ? '已暂停 · 点击继续' : t.status === 'failed' ? '失败 · ' + t.errMsg : '等待下载';
    if (this.context.scope === 'video') { e.title = t.part || t.title; }
  }
  private openPage(section: string, context: OfflineContext, title: string): void {
    const play: OfflineContext = context.scope === 'video' ? this.playContext : context;
    router.pushUrl({ url: 'pages/download/DownloadPage', params: { section: section, scope: context.scope, key: context.key, title: title, playScope: play.scope, playKey: play.key } });
  }
  private play(t: DownloadTask, context: OfflineContext = this.playContext): void {
    if (!DownloadLibraryService.available(t)) { this.toast('本地文件已失效，请重试下载'); return; }
    router.pushUrl({ url: 'pages/video/VideoDetailPage', params: DownloadLibraryService.params(t, context) });
  }
  private open(e: DlEntry): void {
    if (this.selecting) { this.setSelected(e, !this.isSelected(e)); return; }
    if (e.seasonId) { this.openPage('library', { scope: 'season', key: e.seasonId }, e.title); return; }
    if (e.tasks.length > 1) { this.openPage('library', { scope: 'video', key: e.bvid }, e.title); return; }
    const t = e.tasks[0];
    if (t.status === 'done') { this.play(t); }
    else if (t.status === 'downloading') { DownloadService.pause(t.cid).catch((e: Error) => { this.toast(e.message); }); }
    else { DownloadService.resume(t.cid).catch((e: Error) => { this.toast(e.message); }); }
  }
  private isSelected(e: DlEntry): boolean { return e.tasks.every((t: DownloadTask): boolean => this.selected.includes(t.cid)); }
  private setSelected(e: DlEntry, checked: boolean): void {
    const next = this.selected.filter((cid: number): boolean => !e.tasks.some((t: DownloadTask): boolean => t.cid === cid));
    if (checked) { for (const t of e.tasks) { if (!next.includes(t.cid)) { next.push(t.cid); } } } this.selected = next;
  }
  private refs(): string[] {
    const entries = this.entries.filter((e: DlEntry): boolean => this.isSelected(e));
    const refs = entries.map((e: DlEntry): string => e.key);
    for (const t of DownloadService.list()) { if (this.selected.includes(t.cid) && !entries.some((e: DlEntry): boolean => e.tasks.includes(t))) { refs.push('t:' + downloadKey(t)); } }
    return refs;
  }
  private confirmDelete(): void {
    const cids = this.selected.slice(); if (!cids.length) { return; }
    AlertDialog.show({ title: '删除缓存', message: '确认删除选中的' + cids.length.toString() + '个视频及本地文件？', primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '删除', fontColor: '#E54D42', action: () => {
      this.selecting = false; this.selected = []; DownloadService.removeMany(cids).then(() => { if (!this.destroyed) { this.refresh(); } }).catch((e: Error) => { this.toast(e.message); });
    } } });
  }
  private async addToFolder(id: string): Promise<void> {
    try { await DownloadService.addToFolder(id, this.refs()); this.sheetShown = false; this.selected = []; this.selecting = false; this.refresh(); this.toast('已添加到文件夹'); }
    catch (e) { this.toast((e as Error).message); }
  }
  private async submitName(): Promise<void> {
    try {
      if (this.editFolder) { await DownloadService.renameFolder(this.editFolder, this.folderName); }
      else { await DownloadService.addFolder(this.folderName); }
      this.refresh();
      if (this.nameFromPicker) { this.nameFromPicker = false; this.sheetKind = 'folders'; }
      else { this.sheetShown = false; }
    }
    catch (e) { this.toast((e as Error).message); }
  }
  private folderMenu(f: DlFolder): void {
    AlertDialog.show({ title: f.title, message: '管理文件夹', primaryButton: { value: '重命名', action: () => { this.editFolder = f.id; this.folderName = f.title; this.sheetKind = 'name'; this.sheetShown = true; } }, secondaryButton: { value: '删除文件夹', fontColor: '#E54D42', action: () => {
      AlertDialog.show({ title: '删除文件夹', message: '仅移除文件夹关联，本地视频保留。', primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '删除', action: () => { DownloadService.removeFolder(f.id).then(() => { this.refresh(); }).catch((e: Error) => { this.toast(e.message); }); } } });
    } } });
  }
  @Builder
  FolderCard(row: LibraryRow) {
    Row({ space: 10 }) {
      Stack() {
        if (row.folderTasks.length) { AsyncImage({ src: row.folderTasks[0].cover, w: 320, h: 200 }) }
        else { Image($r('app.media.icon_folder')).width(32).height(32).fillColor($r('app.color.text_secondary')) }
      }.width(160).height(100).backgroundColor($r('app.color.btn_soft_bg')).borderRadius(6).clip(true)
      Column({ space: 6 }) {
        Text(row.folder?.title || '').fontSize(14).letterSpacing(0.3).fontColor($r('app.color.text_primary')).maxLines(2).width('100%')
        Text(row.folderTasks.length.toString() + ' 个视频').fontSize(12).fontColor($r('app.color.text_secondary'))
        Blank()
        Text(row.folderTasks.length ? '本地离线缓存' : '空文件夹').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1).height(100).alignItems(HorizontalAlign.Start)
      Image($r('app.media.icon_more')).width(18).height(18).padding(4).fillColor($r('app.color.text_secondary'))
        .id('download_folder_menu_' + (row.folder?.id || '')).onTouch((e: TouchEvent) => { e.stopPropagation(); }).onClick(() => { if (row.folder) { this.folderMenu(row.folder); } })
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .id('download_folder_' + (row.folder?.id || '')).onClick(() => { if (row.folder) { this.openPage('library', { scope: 'folder', key: row.folder.id }, row.folder.title); } })
  }
  @Builder
  Action(text: string, id: string, action: () => void) { Text(text).fontSize(14).fontColor($r('app.color.text_primary')).width('100%').padding({ left: 20, right: 20, top: 14, bottom: 14 }).id(id).onClick(action) }
  private async moveMember(delta: number): Promise<void> { try { await DownloadService.moveMember(this.context.key, this.menu.key, delta); this.sheetShown = false; this.refresh(); } catch (e) { this.toast((e as Error).message); } }
  @Builder
  Sheet() {
    Scroll() { Column() {
      if (this.sheetKind === 'name') {
        Text(this.editFolder ? '重命名文件夹' : '新建文件夹').fontSize(16).padding(14).fontColor($r('app.color.text_primary'))
        TextInput({ text: this.folderName, placeholder: '文件夹名称' }).id('download_folder_name').fontColor($r('app.color.text_primary')).margin({ left: 16, right: 16 }).onChange((v: string) => { this.folderName = v; })
        this.Action('确定', 'download_folder_submit', () => { this.submitName(); })
      } else if (this.sheetKind === 'folders') {
        this.Action('新建文件夹', 'download_picker_new_folder', () => { this.editFolder = ''; this.folderName = ''; this.nameFromPicker = true; this.sheetKind = 'name'; })
        ForEach(this.folders, (f: DlFolder) => { this.Action(f.title, 'download_add_' + f.id, () => { this.addToFolder(f.id); }) }, (f: DlFolder): string => f.id)
        if (this.context.scope === 'folder') {
          this.Action('移出当前文件夹', 'download_unlink', () => { DownloadService.removeFromFolder(this.context.key, this.refs()).then(() => { this.sheetShown = false; this.selected = []; this.selecting = false; this.refresh(); }).catch((e: Error) => { this.toast(e.message); }); })
        }
      } else {
        this.Action(this.menu.tasks[0]?.status === 'done' ? '播放' : this.menu.tasks[0]?.status === 'downloading' ? '暂停' : '继续下载', 'download_play', () => { const t = this.menu.tasks.find((v: DownloadTask): boolean => v.status === 'done'); this.sheetShown = false; if (t) { this.play(t); } else { this.open(this.menu); } })
        this.Action('添加到文件夹', 'download_add_to_folder', () => { this.selected = this.menu.tasks.map((t: DownloadTask): number => t.cid); this.sheetKind = 'folders'; })
        if (this.context.scope === 'folder') { this.Action('上移', 'download_move_up', () => { this.moveMember(-1); }); this.Action('下移', 'download_move_down', () => { this.moveMember(1); }) }
        this.Action('删除', 'download_delete', () => { this.selected = this.menu.tasks.map((t: DownloadTask): number => t.cid); this.sheetShown = false; this.confirmDelete(); })
      }
    }.width('100%').padding({ bottom: 24 + this.navBarH }) }.width('100%')
  }
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
  }
  build() {
    Stack({ alignContent: Alignment.BottomEnd }) { Column() {
      Row({ space: 12 }) {
        Image($r('app.media.icon_arrow_left')).width(22).height(22).fillColor($r('app.color.text_primary')).padding(6).onClick(() => { router.back(); })
        Text(this.pageTitle).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.icon_folder_add')).width(24).height(24).fillColor($r('app.color.text_secondary'))
        }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('新建文件夹').id('download_new_folder')
          .onClick(() => { this.editFolder = ''; this.nameFromPicker = false; this.folderName = ''; this.sheetKind = 'name'; this.sheetShown = true; })
        Text(this.selecting ? '完成' : '选择').fontSize(13).fontColor($r('app.color.brand_pink')).padding(6).id('download_select').onClick(() => { this.selecting = !this.selecting; this.selected = []; })
      }.width('100%').padding({ left: 8, right: 12, top: this.statusBarH + 10, bottom: 10 })
      Text('已用空间 ' + formatSize(this.total)).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').padding({ left: 12, bottom: 8 })
      if (this.loading) { LoadingProgress().width(40).height(40).margin({ top: 50 }) }
      else if (this.error) { ErrorRetry({ text: this.error, onRetry: () => { this.initialize(); } }) }
      else if (!this.rows.length) { EmptyState({ text: this.section === 'tasks' ? '暂无下载任务' : '暂无缓存内容' }) }
      else {
        List() {
          LazyForEach(this.ds, (row: LibraryRow) => { ListItem() {
            if (row.kind === 'header') {
              Row() {
                Text(row.title).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
                if (row.title === '下载中') { Text('全部任务').fontSize(13).fontColor($r('app.color.brand_pink')).id('download_all_tasks').onClick(() => { this.openPage('tasks', new OfflineContext(), '下载任务'); }) }
                else if (row.title === '文件夹' && this.section !== 'folders') { Text('管理').fontSize(13).fontColor($r('app.color.brand_pink')).id('download_manage_folders').onClick(() => { this.openPage('folders', new OfflineContext(), '文件夹管理'); }) }
              }.width('100%').padding({ left: 12, right: 12, top: 7, bottom: 7 })
            } else if (row.folder) { this.FolderCard(row) }
            else if (row.entry) { DownloadEntryCard({ entry: row.entry, selecting: this.selecting, selected: this.isSelected(row.entry), onOpen: () => { this.open(row.entry as DlEntry); }, onSelect: (v: boolean) => { this.setSelected(row.entry as DlEntry, v); }, onMenu: () => { this.menu = row.entry as DlEntry; this.sheetKind = 'menu'; this.sheetShown = true; } }) }
          } }, (row: LibraryRow): string => row.key)
          ListItem() { Column().height(110 + this.navBarH) }
        }.width('100%').layoutWeight(1).cachedCount(1).id('download_library_list')
      }
      if (this.selecting) {
        Row() {
          Text('全选').fontSize(14).padding(12).onClick(() => { const all: number[] = []; if (!this.entries.every((e: DlEntry): boolean => this.isSelected(e))) { for (const e of this.entries) { for (const t of e.tasks) { if (!all.includes(t.cid)) { all.push(t.cid); } } } } this.selected = all; })
          Blank()
          Text('添加到文件夹').fontSize(14).padding(12).id('download_batch_folder').onClick(() => { if (this.selected.length) { this.sheetKind = 'folders'; this.sheetShown = true; } })
          Text('删除(' + this.selected.length.toString() + ')').fontSize(14).fontColor('#E54D42').padding(12).id('download_batch_delete').onClick(() => { this.confirmDelete(); })
        }.width('100%').padding({ bottom: this.navBarH }).backgroundColor($r('app.color.card_bg'))
      }
    }.width('100%').height('100%')
    if (this.continueTarget && !this.selecting) {
      Row({ space: 8 }) { Image($r('app.media.icon_play')).width(18).height(18).fillColor($r('app.color.brand_pink')); Text('继续观看').fontSize(14).fontColor($r('app.color.brand_pink')) }
        .height(48).padding({ left: 16, right: 16 }).backgroundColor($r('app.color.btn_soft_bg')).borderRadius(24).margin({ right: 16, bottom: 16 + this.navBarH }).id('download_continue').onClick(() => { if (this.continueTarget) { this.play(this.continueTarget.task, this.continueTarget.context); } })
    }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page')).bindSheet($$this.sheetShown, this.Sheet(), { height: this.sheetKind === 'name' ? 260 : 400, dragBar: true, showClose: true, backgroundColor: $r('app.color.card_bg') })
  }
}
