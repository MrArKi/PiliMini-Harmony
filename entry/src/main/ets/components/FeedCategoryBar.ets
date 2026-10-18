/** 首页/动态共用Nara原生Index文字分类；选中程度由内容Tabs的真实位移驱动。 */
@Component
export struct FeedCategoryBar {
  @Prop labels: string[] = [];
  @Prop selected: number = 0;
  @Prop progress: number = 0;
  onSelect: (index: number) => void = () => {};

  private selectedOpacity(index: number): number {
    return Math.max(0, 1 - Math.abs(this.progress - index));
  }

  build() {
    Row({ space: 6 }) {
      ForEach(this.labels, (label: string, index: number) => {
        Stack() {
          // 两种字重共用固定布局宽度，滑动中淡变，避免结束时字重突跳。
          Text(label).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
          Text(label).fontSize(15).fontWeight(FontWeight.Bolder)
            .fontColor($r('app.color.brand_pink'))
            .opacity(this.selectedOpacity(index))
        }
        .height(28).padding({ left: 15, right: 15 })
        .accessibilityGroup(true).accessibilityText(label)
        .accessibilitySelected(this.selected === index)
        .onClick((): void => { this.onSelect(index); })
      }, (label: string) => label)
      Blank()
    }
    .width('100%').height(32).padding({ left: 8, right: 8 })
  }
}
