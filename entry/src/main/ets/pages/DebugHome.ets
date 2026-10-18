/**
 * 预研调试台（SP-1 入口）
 * 调试页不作为正式功能，仅用于预研验证与证据采集。
 */
import { router } from '@kit.ArkUI';

interface DebugEntry {
  title: string;
  desc: string;
  url: string;
}

@Entry
@Component
struct DebugHome {
  private entries: DebugEntry[] = [
    { title: 'SP-Net 网络与取流', desc: 'view 信息 → playurl（durl / DASH）', url: 'pages/debug/SpikeNet' },
    { title: 'SP-Player 播放验证', desc: 'libmpv单内核：分离音画 / 暂停 / seek / 倍速', url: 'pages/debug/SpikePlayer' },
    { title: 'SP-2 wbi 签名', desc: 'mixinKey / rcmd 首页 / 搜索', url: 'pages/debug/SpikeWbi' },
    { title: 'T3 纯音频 + 后台', desc: '同一媒体vid切轨 / 长时任务 / AVSession', url: 'pages/debug/SpikeAudio' },
    { title: 'spec-01 验收', desc: 'Cookie 持久化 / 错误模型 / -101 事件', url: 'pages/debug/Spec01' }
  ];

  build() {
    Column({ space: 12 }) {
      Text('预研调试台')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 32, bottom: 8 })

      ForEach(this.entries, (item: DebugEntry) => {
        Column({ space: 4 }) {
          Text(item.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          Text(item.desc)
            .fontSize(12)
            .fontColor('#999999')
        }
        .width('90%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .borderRadius(12)
        .backgroundColor('#F5F5F5')
        .onClick(() => {
          router.pushUrl({ url: item.url });
        })
      }, (item: DebugEntry) => item.url)

      Button('返回')
        .margin({ top: 24 })
        .onClick(() => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
  }
}
