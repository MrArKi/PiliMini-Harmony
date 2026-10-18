/**
 * 通用状态组件（spec-02 任务 2.3）：空态 / 错误重试 / 加载脚注
 */

@Component
export struct EmptyState {
  @Prop text: string = '暂无内容';

  build() {
    Column({ space: 8 }) {
      Text(this.text)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding(48)
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct ErrorRetry {
  @Prop text: string = '加载失败，请检查网络';
  onRetry: () => void = () => {
  };

  build() {
    Column({ space: 12 }) {
      Text(this.text)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
      Button('重试')
        .fontSize(13)
        .backgroundColor($r('app.color.brand_pink'))
        .onClick(() => {
          this.onRetry();
        })
    }
    .width('100%')
    .padding(48)
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct LoadingFooter {
  @Prop text: string = '加载中…';

  build() {
    Row({ space: 8 }) {
      LoadingProgress()
        .width(18)
        .height(18)
        .color($r('app.color.text_secondary'))
      Text(this.text)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding(16)
    .justifyContent(FlexAlign.Center)
  }
}
