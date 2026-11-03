/**
 * 视频详情页（薄壳）
 *  - 只负责：读 router 入参、转发页面生命周期、保留 Cupertino 转场
 *  - 实现在 components/video/VideoDetailView.ets（同一份代码也供 NavDestination 复用，spec-33）
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router } from '@kit.ArkUI';
import { VideoDetailView } from '../../components/video/VideoDetailView';
import { VideoDetailHandle } from '../../components/video/video_detail_handle';

@Entry
@Component
struct VideoDetailPage {
  private handle: VideoDetailHandle = new VideoDetailHandle();
  @State bvid: string = '';
  @State title: string = '';
  @State cid: number = 0;
  @State localPath: string = '';
  @State localAudioPath: string = '';
  @State localCover: string = '';
  @State localArtist: string = '';
  @State localDuration: number = 0;
  @State offlineScope: string = 'all';
  @State offlineKey: string = '';

  aboutToAppear(): void {
    const pm: Record<string, string> | undefined = router.getParams() as Record<string, string> | undefined;
    if (pm !== undefined) {
      this.bvid = pm['bvid'] || '';
      this.title = pm['title'] || '';
      this.cid = Number(pm['cid'] || '0');
      const lp: string = pm['localPath'] || '';
      if (lp.length > 0) {
        this.localPath = lp;
        this.localAudioPath = pm['localAudioPath'] || '';
        this.localCover = pm['localCover'] || '';
        this.localArtist = pm['localArtist'] || '';
        this.localDuration = Number(pm['localDuration'] || '0');
        this.offlineScope = pm['offlineScope'] || 'all';
        this.offlineKey = pm['offlineKey'] || '';
      }
    }
    this.handle.exit = (toHome: boolean): void => {
      if (toHome) {
        try { router.back({ url: 'pages/main/MainShell' }); }
        catch (_) { router.replaceUrl({ url: 'pages/main/MainShell' }); }
      } else {
        router.back();
      }
    };
  }

  onPageShow(): void { this.handle.show(); }
  onPageHide(): void { this.handle.hide(); }
  onBackPress(): boolean { return this.handle.back(); }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '100%' })
      .onEnter((_type: RouteType, progress: number): void => { this.handle.routeEntry(progress); })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '100%' })
  }

  build() {
    Column() {
      VideoDetailView({
        handle: this.handle,
        inputBvid: this.bvid,
        inputTitle: this.title,
        inputCid: this.cid,
        inputLocalPath: this.localPath,
        inputLocalAudioPath: this.localAudioPath,
        inputLocalCover: this.localCover,
        inputLocalArtist: this.localArtist,
        inputLocalDuration: this.localDuration,
        inputOfflineScope: this.offlineScope,
        inputOfflineKey: this.offlineKey
      })
    }
    .width('100%')
    .height('100%')
  }
}
