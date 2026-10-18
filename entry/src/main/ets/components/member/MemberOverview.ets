import { MemberService, MemberEntry, MemberFolder, MemberFolderResult, MemberResult } from '../../service/member_service';
import { MEMBER_NESTED } from './MemberFeed';
import { MemberOpusCard, MemberFolderCard, MemberHomeVideoCard } from './MemberCards';
import { router } from '@kit.ArkUI';
import { AppError } from '../../infra/error/app_error';
import { NARA_SCROLL_FRICTION } from '../../common/nara_motion';

@Component
export struct MemberOverview {
  listScroller: Scroller = new Scroller();
  @Prop mid: number = 0;
  onMore: (tab: number, sub: number) => void = () => {};
  @State videos: MemberEntry[] = [];
  @State opus: MemberEntry[] = [];
  @State folders: MemberFolder[] = [];
  @State likes: MemberEntry[] = [];
  @State coins: MemberEntry[] = [];
  @State likeError: string = '';
  @State coinError: string = '';
  @State busy: boolean = true;
  @State refreshing: boolean = false;
  @State videoError: string = '';
  @State opusError: string = '';
  @State folderError: string = '';
  @State pageWidth: number = 412;
  private destroyed: boolean = false;
  private generation: number = 0;
  aboutToAppear(): void { this.destroyed = false; this.load(); }
  aboutToDisappear(): void { this.destroyed = true; this.generation++; }
  private async load(): Promise<void> {
    const version: number = ++this.generation; this.busy = true;
    this.videoError = ''; this.opusError = ''; this.folderError = ''; this.likeError = ''; this.coinError = '';
    await Promise.all([
      MemberService.recent(this.mid, 'like').then((r: MemberResult) => {
        if (!this.destroyed && version === this.generation) { this.likes = r.items; }
      }).catch((e: Error) => { if (!this.destroyed && version === this.generation) {
        this.likes = []; if (!this.privateSection(e)) { this.likeError = e.message; }
      } }),
      MemberService.recent(this.mid, 'coin').then((r: MemberResult) => {
        if (!this.destroyed && version === this.generation) { this.coins = r.items; }
      }).catch((e: Error) => { if (!this.destroyed && version === this.generation) {
        this.coins = []; if (!this.privateSection(e)) { this.coinError = e.message; }
      } }),
      MemberService.videos(this.mid, 1, 'pubdate').then((r: MemberResult) => {
        if (!this.destroyed && version === this.generation) { this.videos = r.items.slice(0, 4); }
      }).catch((e: Error) => { if (!this.destroyed && version === this.generation) { this.videoError = e.message; } }),
      MemberService.opus(this.mid, '', 1).then((r: MemberResult) => {
        if (!this.destroyed && version === this.generation) { this.opus = r.items.slice(0, 2); }
      }).catch((e: Error) => { if (!this.destroyed && version === this.generation) { this.opusError = e.message; } }),
      MemberService.folders(this.mid, 1, false).then((r: MemberFolderResult) => {
        if (!this.destroyed && version === this.generation) { this.folders = r.items.slice(0, 1); }
      }).catch((e: Error) => { if (!this.destroyed && version === this.generation) { this.folderError = e.message; } })
    ]);
    if (!this.destroyed && version === this.generation) { this.busy = false; this.refreshing = false; }
  }
  private privateSection(error: Error): boolean {
    return error instanceof AppError && (error.code === 53013 || error.code === -403 || error.code === -404);
  }
  @Builder
  Heading(title: string, tab: number, sub: number) {
    Row() {
      Text(title).fontSize(14).fontColor($r('app.color.text_secondary'))
      Blank()
      Text('更多').fontSize(12).fontColor($r('app.color.text_secondary'))
      Image($r('app.media.icon_arrow_right')).width(16).height(16).fillColor($r('app.color.text_secondary'))
    }.width('100%').padding({ left: 12, right: 12, top: 14, bottom: 14 })
      .onClick(() => { this.onMore(tab, sub); })
  }
  @Builder
  Retry(error: string) {
    Text(error).fontSize(12).fontColor($r('app.color.brand_pink')).padding(16)
      .onClick(() => { this.load(); })
  }
  @Builder
  RecentHeader(title: string, kind: string) {
    Row() {
      Text(title).fontSize(14).fontColor($r('app.color.text_secondary'))
      Blank()
      Text('更多').fontSize(12).fontColor($r('app.color.text_secondary'))
      Image($r('app.media.icon_arrow_right')).width(16).height(16).fillColor($r('app.color.text_secondary'))
    }.width('100%').padding({ left: 12, right: 12, top: 14, bottom: 14 })
      .onClick(() => { router.pushUrl({ url: 'pages/member/MemberListPage',
        params: { 'mid': this.mid.toString(), 'kind': kind, 'title': title } }); })
  }
  @Builder
  RecentCards(entries: MemberEntry[]) {
    Row({ space: 10 }) {
      ForEach(entries.slice(0, 2), (e: MemberEntry) => {
        if (e.video) { MemberHomeVideoCard({ model: e.video, cardWidth: (this.pageWidth - 34) / 2 }) }
      }, (e: MemberEntry) => e.key)
    }.width('100%').padding({ left: 12, right: 12 }).alignItems(VerticalAlign.Top)
  }
  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      List({ scroller: this.listScroller }) {
        if (this.busy && this.videos.length === 0 && this.opus.length === 0) {
          ListItem() { Row() { LoadingProgress().width(30).height(30) }.width('100%').height(100).justifyContent(FlexAlign.Center) }
        }
        if (this.videos.length > 0 || this.videoError) {
          ListItem() { this.Heading('视频', 2, 0) }
          if (this.videoError) { ListItem() { this.Retry(this.videoError) } }
          ForEach([0, 2], (start: number) => {
            if (this.videos.length > start) {
              ListItem() {
                Row({ space: 10 }) {
                  if (this.videos[start]?.video) { MemberHomeVideoCard({ model: this.videos[start].video, cardWidth: (this.pageWidth - 34) / 2 }) }
                  if (this.videos[start + 1]?.video) { MemberHomeVideoCard({ model: this.videos[start + 1].video, cardWidth: (this.pageWidth - 34) / 2 }) }
                  else { Blank().layoutWeight(1) }
                }.padding({ left: 12, right: 12, bottom: 10 }).width('100%').alignItems(VerticalAlign.Top)
              }
            }
          }, (n: number) => n.toString())
        }
        if (this.folders.length > 0 || this.folderError) {
          ListItem() { this.Heading('收藏', 3, 0) }
          if (this.folderError) { ListItem() { this.Retry(this.folderError) } }
          ForEach(this.folders, (f: MemberFolder) => { ListItem() { MemberFolderCard({ model: f }) } }, (f: MemberFolder) => f.id.toString())
        }
        if (this.coins.length > 0 || this.coinError) {
          ListItem() { this.RecentHeader('最近投币的视频', 'coin') }
          if (this.coinError) { ListItem() { this.Retry(this.coinError) } }
          ListItem() { this.RecentCards(this.coins) }
        }
        if (this.likes.length > 0 || this.likeError) {
          ListItem() { this.RecentHeader('最近点赞的视频', 'like') }
          if (this.likeError) { ListItem() { this.Retry(this.likeError) } }
          ListItem() { this.RecentCards(this.likes) }
        }
        if (this.opus.length > 0 || this.opusError) {
          ListItem() { this.Heading('图文', 2, 1) }
          if (this.opusError) { ListItem() { this.Retry(this.opusError) } }
          ListItem() {
            Row({ space: 12 }) {
              ForEach(this.opus, (e: MemberEntry) => {
                if (e.opus) { MemberOpusCard({ model: e.opus, cardWidth: (this.pageWidth - 36) / 2 }) }
              }, (e: MemberEntry) => e.key)
            }.padding({ left: 12, right: 12 }).width('100%').alignItems(VerticalAlign.Top)
          }
        }
        ListItem() {
          Text(!this.busy && this.videos.length + this.opus.length + this.folders.length === 0
            && !this.videoError && !this.opusError && !this.folderError ? '暂无公开内容' : '')
            .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').height(140).textAlign(TextAlign.Center)
        }
      }.width('100%').height('100%').scrollBar(BarState.Off).nestedScroll(MEMBER_NESTED).edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
        .friction(NARA_SCROLL_FRICTION)
    }.width('100%').height('100%').onRefreshing(() => { this.refreshing = true; this.load(); })
      .onAreaChange((_old: Area, area: Area) => { this.pageWidth = Number(area.width); })
  }
}
