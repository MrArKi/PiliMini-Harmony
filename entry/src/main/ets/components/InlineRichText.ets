/** 评论、动态共用官方 Text 的行内 Span/ImageSpan，不引入第二套排版。 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { RichKind, RichSegment, RichText as RichTextParser } from '../common/rich_text';
import { openMember, openMention } from '../common/member_route';

function segmentColor(segment: RichSegment): ResourceColor {
  if (segment.kind === RichKind.Link) { return $r('app.color.link_blue'); }
  if (segment.kind === RichKind.Mention || segment.kind === RichKind.Topic) { return $r('app.color.brand_pink'); }
  return $r('app.color.text_primary');
}

@Builder
export function InlineRichSpans(segments: RichSegment[], textSize: number, bold: boolean,
  onTap: (segment: RichSegment) => void, onImage: (success: boolean) => void) {
  ForEach(segments, (segment: RichSegment) => {
    if (segment.kind === RichKind.Emote) {
      ImageSpan(segment.target)
        .width(RichTextParser.emoteSize(segment)).height(RichTextParser.emoteSize(segment))
        .verticalAlign(ImageSpanAlignment.CENTER).objectFit(ImageFit.Contain)
        .onComplete((): void => { onImage(true); })
        .onError((): void => { onImage(false); })
    } else if (segment.kind === RichKind.Plain) {
      Span(segment.text)
        .fontSize(bold && textSize >= 20 ? textSize : (segment.fontSize > 0 ? segment.fontSize : textSize))
        .fontWeight(segment.bold || bold ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle(segment.italic ? FontStyle.Italic : FontStyle.Normal)
        .decoration({ type: segment.strike ? TextDecorationType.LineThrough : TextDecorationType.None })
        .fontColor(segmentColor(segment))
    } else {
      Span(segment.text)
        .fontSize(bold && textSize >= 20 ? textSize : (segment.fontSize > 0 ? segment.fontSize : textSize))
        .fontWeight(segment.bold || bold ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle(segment.italic ? FontStyle.Italic : FontStyle.Normal)
        .decoration({ type: segment.strike ? TextDecorationType.LineThrough : TextDecorationType.None })
        .fontColor(segmentColor(segment))
        .onClick((): void => { onTap(segment); })
    }
  }, (segment: RichSegment, index: number): string => RichTextParser.segmentKey(segment, index))
}

@Component
export struct InlineRichText {
  @Prop text: string = '';
  @Prop segments: RichSegment[] = [];
  @Prop textSize: number = 15;
  @Prop textLineHeight: number = 24;
  @Prop maxLineCount: number = 2147483647;
  @Prop bold: boolean = false;

  private tapSegment(segment: RichSegment): void {
    if (segment.kind === RichKind.Mention) {
      if (segment.mid > 0) { openMember(segment.mid); } else { openMention(segment.target, []); }
    } else if (segment.kind === RichKind.Topic) {
      router.pushUrl({ url: 'pages/search/SearchPage', params: { 'keyword': segment.target } });
    } else if (segment.kind === RichKind.Link) {
      const video: RegExpMatchArray | null = segment.target.match(/BV[0-9A-Za-z]{10}/);
      if (video) { router.pushUrl({ url: 'pages/video/VideoDetailPage', params: { 'bvid': video[0] } }); }
      else { RichTextParser.openUrl(getContext(this) as common.UIAbilityContext, segment.target); }
    }
  }

  build() {
    Text() {
      InlineRichSpans(this.segments.length > 0 ? this.segments : RichTextParser.parse(this.text), this.textSize, this.bold,
        (segment: RichSegment): void => { this.tapSegment(segment); }, (_success: boolean): void => {})
    }
    .fontSize(this.textSize).lineHeight(this.textLineHeight)
    .fontColor($r('app.color.text_primary')).maxLines(this.maxLineCount)
    .textOverflow({ overflow: TextOverflow.Clip }).width('100%')
  }
}
