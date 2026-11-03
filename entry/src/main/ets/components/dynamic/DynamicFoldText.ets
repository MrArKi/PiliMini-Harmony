/**
 * 动态列表正文：原生Text限制6行，末行渐隐＋“全文”在原卡展开。
 * SDK TextOverflow没有自定义渐隐尾缀，组合官方测量/混合能力完成，不裁切原始字符串。
 */
import { text as graphicsText } from '@kit.ArkGraphics2D';
import { RichKind, RichSegment, RichText } from '../../common/rich_text';
import { InlineRichText } from '../InlineRichText';

@Component
export struct DynamicFoldText {
  @Prop @Watch('resetContent') contentId: string = '';
  @Prop @Watch('resetContent') text: string = '';
  @Prop @Watch('measureOverflow') segments: RichSegment[] = [];
  @Prop @Watch('measureOverflow') textSize: number = 15;
  @Prop @Watch('measureOverflow') textLineHeight: number = 24;
  @Prop @Watch('measureOverflow') availableWidth: number = 340;

  @State private expanded: boolean = false;
  @State private overflowing: boolean = false;
  @State private moreWidth: number = 48;
  @State private fadeHeight: number = 24;
  private actualWidth: number = 0;
  private measuredText: string = '';
  private measuredSegments: RichSegment[] | undefined = undefined;
  private measuredWidth: number = -1;
  private measuredFontPx: number = -1;
  private measuredLinePx: number = -1;

  aboutToAppear(): void { this.measureOverflow(); }

  private resetContent(): void {
    this.expanded = false;
    this.measuredWidth = -1;
    this.measureOverflow();
  }

  /** 比较原生6/7行测量：只需知道第7行是否存在，无需为长文铺开隐藏Text子树。 */
  private measureOverflow(): void {
    const width: number = this.actualWidth > 0 ? this.actualWidth : this.availableWidth;
    if (width <= 0 || this.text.length === 0) {
      this.measuredWidth = -1;
      if (this.overflowing) { this.overflowing = false; }
      return;
    }
    try {
      const ui = this.getUIContext();
      const fontPx: number = ui.fp2px(this.textSize);
      const linePx: number = ui.fp2px(this.textLineHeight);
      if (this.measuredText === this.text && this.measuredSegments === this.segments && Math.abs(this.measuredWidth - width) < 0.5 &&
        this.measuredFontPx === fontPx && this.measuredLinePx === linePx) { return; }
      const measure = ui.getMeasureUtils();
      if (!Number.isFinite(linePx) || linePx <= 0) { throw new Error('Invalid text measure'); }
      // 官方排版占位与实际ImageSpan同为20/40vp，不再把[表情名]宽度当图片宽度。
      const builder = new graphicsText.ParagraphBuilder({ maxLines: 7,
        textStyle: { fontSize: fontPx, heightScale: linePx / fontPx, heightOnly: true } },
        graphicsText.FontCollection.getGlobalInstance());
      const segments: RichSegment[] = this.segments.length > 0 ? this.segments : RichText.parse(this.text);
      for (let i: number = 0; i < segments.length; i++) {
        const segment: RichSegment = segments[i];
        if (segment.kind === RichKind.Emote) {
          const side: number = ui.vp2px(RichText.emoteSize(segment));
          builder.addPlaceholder({ width: side, height: side,
            align: graphicsText.PlaceholderAlignment.CENTER_OF_ROW_BOX,
            baseline: graphicsText.TextBaseline.ALPHABETIC, baselineOffset: 0 });
        } else { builder.addText(segment.text); }
      }
      const paragraph = builder.build();
      paragraph.layoutSync(ui.vp2px(width));
      const overflowing: boolean = paragraph.getLineCount() > 6 || paragraph.didExceedMaxLines();
      if (this.overflowing !== overflowing) { this.overflowing = overflowing; }
      // 返回px，布局用vp；系统大字体下仍为“全文”保留完整热区。
      const label: number = measure.measureText({ textContent: '全文', fontSize: this.textSize.toString() + 'fp' });
      if (!Number.isFinite(label) || label <= 0) { throw new Error('Invalid label measure'); }
      const moreWidth: number = Math.max(40, ui.px2vp(label) + 16);
      const fadeHeight: number = ui.px2vp(linePx);
      if (Math.abs(this.moreWidth - moreWidth) > 0.5) { this.moreWidth = moreWidth; }
      if (Math.abs(this.fadeHeight - fadeHeight) > 0.5) { this.fadeHeight = fadeHeight; }
      this.measuredText = this.text; this.measuredWidth = width;
      this.measuredSegments = this.segments;
      this.measuredFontPx = fontPx; this.measuredLinePx = linePx;
    } catch (_) {
      // 测量不可用仍保留访问全文的入口，不让6行以外的正文不可达。
      this.measuredWidth = -1;
      this.overflowing = true;
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        InlineRichText({ text: this.text, segments: this.segments, textSize: this.textSize,
          textLineHeight: this.textLineHeight, maxLineCount: this.expanded ? 2147483647 : 6 })

        if (this.overflowing && !this.expanded) {
          // DST_OUT只擦除局部Text的alpha，深浅色/转发半透明底色保持原样。
          Row()
            .width(this.moreWidth + 48)
            .height(this.fadeHeight)
            .linearGradient({ direction: GradientDirection.Right,
              colors: [['#00000000', 0], ['#FF000000', 48 / (this.moreWidth + 48)], ['#FF000000', 1]] })
            .blendMode(BlendMode.DST_OUT)
            .hitTestBehavior(HitTestMode.None)
            .accessibilityLevel('no')
        }
      }
      .width('100%')
      // 仅长正文分配6行大小的局部混合层；短正文没有离屏开销。
      .blendMode(this.overflowing && !this.expanded ? BlendMode.SRC_OVER : BlendMode.NONE, BlendApplyType.OFFSCREEN)

      if (this.overflowing && !this.expanded) {
        Text('全文')
          .fontSize(this.textSize)
          .lineHeight(this.textLineHeight)
          .fontColor($r('app.color.link_blue'))
          .width(this.moreWidth)
          .padding({ left: 16 })
          .textAlign(TextAlign.End)
          .id('dynamic-fold-more')
          .onClick((): void => { this.expanded = true; })
      }
    }
    .width('100%')
    .onAreaChange((_old: Area, area: Area): void => {
      const width: number = Number(area.width);
      if (width > 0) { this.actualWidth = width; this.measureOverflow(); }
    })
  }
}
