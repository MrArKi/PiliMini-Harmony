/** 与正式详情页复用单内核视图，不保留旧ijk验证实现。 */
import { router } from '@kit.ArkUI';
import { PlayerView } from '../../components/player/PlayerView';

@Entry
@Component
struct SpikePlayer {
  @State bvid: string = 'BV1gveN6WEpC';
  @State cid: number = 0;
  @State playing: boolean = false;
  aboutToAppear(): void {
    const params: Record<string, string> = router.getParams() as Record<string, string>;
    if (params !== undefined && params['bvid']) { this.bvid = params['bvid']; }
    if (params !== undefined && params['cid']) { this.cid = parseInt(params['cid'], 10); }
  }
  build() {
    Column({ space: 12 }) {
      Text('单内核播放验证').fontSize(20)
      TextInput({ text: this.bvid }).onChange((text: string): void => { this.bvid = text; })
      TextInput({ text: this.cid.toString(), placeholder: 'CID' })
        .onChange((text: string): void => { this.cid = parseInt(text, 10) || 0; })
      Button('播放').onClick((): void => { this.playing = true; })
      if (this.playing && this.cid > 0) {
        PlayerView({ bvid: this.bvid, cid: this.cid, autoPlay: true, viewHeight: '260vp',
          onExit: (): void => { router.back(); } })
      }
      Button('返回').onClick((): void => { router.back(); })
    }.width('100%').height('100%').padding({ top: 40 })
  }
}
