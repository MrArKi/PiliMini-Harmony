/** 后台验证从正式详情页进行，复用相同控制器/媒体会话。 */
import { router } from '@kit.ArkUI';

@Entry
@Component
struct SpikeAudio {
  build() {
    Column({ space: 16 }) {
      Text('后台播放验证').fontSize(20)
      Text('在视频详情起播后退到后台，10秒进入只听；使用系统媒体卡暂停、定位、继续，再回前台。')
        .fontSize(14).padding(20)
      Button('打开播放验证').onClick((): void => { router.replaceUrl({ url: 'pages/debug/SpikePlayer' }); })
      Button('返回').onClick((): void => { router.back(); })
    }.width('100%').height('100%').padding({ top: 50 })
  }
}
