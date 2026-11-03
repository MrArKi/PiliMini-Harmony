/**
 * 评论/简介富文本分段（spec-33/35）：链接、@用户、B站表情。
 * 只做纯文本切分，点击/图片由宿主决定；不解析 Markdown、不请求网络。
 */
import { common, Want } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { CommentEmote } from '../model/emote';

export enum RichKind {
  Plain = 0,
  Link = 1,
  Mention = 2,
  Emote = 3,
  Topic = 4
}

/** polymer 动态与 OPUS rich 字段；仅消费服务端返回，不猜测表情地址。 */
export interface RichEmoji {
  webp_url?: string; gif_url?: string; icon_url?: string; url?: string; size?: number;
}
export interface RichSourceNode {
  type?: string; orig_text?: string; text?: string; rid?: string | number;
  jump_url?: string; emoji?: RichEmoji;
}

export class RichSegment {
  kind: RichKind = RichKind.Plain;
  text: string = '';
  /** Link=可打开的地址（可能省略协议）；Mention=不带@的用户名；Emote=图片地址 */
  target: string = '';
  /** 仅 Emote 使用：接口 meta.size（1 常规 / 2 大表情）。 */
  size: number = 1;
  mid: number = 0;
  bold: boolean = false;
  italic: boolean = false;
  strike: boolean = false;
  fontSize: number = 0;

  constructor(kind: RichKind, text: string, target: string) {
    this.kind = kind;
    this.text = text;
    this.target = target;
  }
}

/** 带协议或常见B站短链前缀；不含中文标点，避免把整句吞成链接。 */
const LINK_PATTERN: RegExp = new RegExp(
  '(?:https?:\\/\\/|www\\.|b23\\.tv\\/|bili23\\.cn\\/|bilibili\\.com\\/)[A-Za-z0-9\\-._~:/?#\\[\\]@!$&\'()*+,;=%]+');
/** B站@昵称允许中英文、数字、下划线与连字符，遇空格/标点结束。 */
const MENTION_PATTERN: RegExp = new RegExp('@[\\u4e00-\\u9fa5A-Za-z0-9_\\-]{1,30}');
const LINK_TAIL: string = '。，、；：！？）》」”’.,;:!?\'")]}';

export class RichText {
  static emoteSize(segment: RichSegment): number { return segment.size >= 2 ? 40 : 20; }

  static segmentKey(segment: RichSegment, index: number): string {
    return index.toString() + '_' + segment.kind.toString() + '_' + segment.text + '_' + segment.target + '_'
      + segment.size.toString() + '_' + segment.mid.toString() + '_' + segment.fontSize.toString()
      + '_' + segment.bold.toString() + segment.italic.toString() + segment.strike.toString();
  }

  static emojiUrl(emoji?: RichEmoji): string {
    const value: string = emoji?.webp_url || emoji?.gif_url || emoji?.icon_url || emoji?.url || '';
    return value.startsWith('//') ? 'https:' + value : value.replace(/^http:\/\//, 'https://');
  }

  /** 按原文对齐节点：保留空白、未知类型和没有节点覆盖的文字。 */
  static parseNodes(text: string, nodes: RichSourceNode[] = []): RichSegment[] {
    if (nodes.length === 0) { return RichText.parse(text); }
    const source: string = text.length > 0 ? text
      : nodes.map((node: RichSourceNode): string => node.orig_text || node.text || '').join('');
    const segments: RichSegment[] = [];
    let cursor: number = 0;
    for (let i: number = 0; i < nodes.length; i++) {
      const node: RichSourceNode = nodes[i];
      const original: string = node.orig_text || node.text || '';
      if (original.length === 0) { continue; }
      const at: number = source.indexOf(original, cursor);
      if (at < 0) { continue; }
      if (at > cursor) { RichText.appendSegments(segments, RichText.parse(source.substring(cursor, at))); }
      const image: string = RichText.emojiUrl(node.emoji);
      let segment: RichSegment;
      if (node.type === 'RICH_TEXT_NODE_TYPE_EMOJI' && image.length > 0) {
        segment = new RichSegment(RichKind.Emote, original, image);
        segment.size = node.emoji?.size || 1;
      } else if (node.type === 'RICH_TEXT_NODE_TYPE_AT') {
        segment = new RichSegment(RichKind.Mention, original, original.replace(/^@/, '').trim());
        segment.mid = Number(node.rid || 0);
      } else if (node.type === 'RICH_TEXT_NODE_TYPE_TOPIC') {
        segment = new RichSegment(RichKind.Topic, original, original.replace(/^#|#$/g, ''));
      } else if (node.jump_url) {
        segment = new RichSegment(RichKind.Link, original, node.jump_url);
      } else {
        RichText.appendSegments(segments, RichText.parse(original));
        cursor = at + original.length;
        continue;
      }
      segments.push(segment);
      cursor = at + original.length;
    }
    if (cursor < source.length) { RichText.appendSegments(segments, RichText.parse(source.substring(cursor))); }
    return segments;
  }

  private static appendSegments(out: RichSegment[], values: RichSegment[]): void {
    for (let i: number = 0; i < values.length; i++) { out.push(values[i]); }
  }

  /** 是否含可点片段；false 时宿主继续用普通 Text，避免无谓分层。 */
  static isRich(text: string): boolean {
    if (text.length === 0) { return false; }
    return LINK_PATTERN.test(text) || MENTION_PATTERN.test(text);
  }

  /** 带表情时先按占位符切片，再对纯文本片段解析链接/@；无表情走原路径。 */
  static parse(text: string, emotes: CommentEmote[] = []): RichSegment[] {
    if (text.length === 0) { return []; }
    if (emotes.length === 0) { return RichText.parseText(text); }
    const segments: RichSegment[] = [];
    let cursor: number = 0;
    while (cursor < text.length) {
      let hit: CommentEmote | undefined = undefined;
      let hitAt: number = -1;
      for (let i: number = 0; i < emotes.length; i++) {
        if (emotes[i].key.length === 0 || emotes[i].url.length === 0) { continue; }
        const at: number = text.indexOf(emotes[i].key, cursor);
        if (at >= 0 && (hitAt < 0 || at < hitAt || (at === hitAt && hit !== undefined
          && emotes[i].key.length > hit.key.length))) { hitAt = at; hit = emotes[i]; }
      }
      if (hit === undefined || hitAt < 0) { break; }
      if (hitAt > cursor) {
        const plain: RichSegment[] = RichText.parseText(text.substring(cursor, hitAt));
        for (let i: number = 0; i < plain.length; i++) { segments.push(plain[i]); }
      }
      const emote: RichSegment = new RichSegment(RichKind.Emote, hit.key, hit.url);
      emote.size = hit.size;
      segments.push(emote);
      cursor = hitAt + hit.key.length;
    }
    if (cursor < text.length) {
      const tail: RichSegment[] = RichText.parseText(text.substring(cursor));
      for (let i: number = 0; i < tail.length; i++) { segments.push(tail[i]); }
    }
    return segments;
  }

  private static parseText(text: string): RichSegment[] {
    const segments: RichSegment[] = [];
    if (text.length === 0) { return segments; }
    let cursor: number = 0;
    while (cursor < text.length) {
      const rest: string = text.substring(cursor);
      const link: RegExpExecArray | null = LINK_PATTERN.exec(rest);
      const mention: RegExpExecArray | null = MENTION_PATTERN.exec(rest);
      const linkAt: number = link === null ? -1 : link.index;
      const mentionAt: number = mention === null ? -1 : mention.index;
      if (linkAt < 0 && mentionAt < 0) { break; }
      const asLink: boolean = linkAt >= 0 && (mentionAt < 0 || linkAt <= mentionAt);
      const at: number = asLink ? linkAt : mentionAt;
      const raw: string = asLink ? (link as RegExpExecArray)[0] : (mention as RegExpExecArray)[0];
      const value: string = asLink ? RichText.trimTail(raw) : raw;
      if (value.length === 0) {
        segments.push(new RichSegment(RichKind.Plain, rest.substring(0, at + 1), ''));
        cursor += at + 1;
        continue;
      }
      if (at > 0) { segments.push(new RichSegment(RichKind.Plain, rest.substring(0, at), '')); }
      segments.push(asLink ? new RichSegment(RichKind.Link, value, value)
        : new RichSegment(RichKind.Mention, value, value.substring(1)));
      cursor += at + value.length;
    }
    if (cursor < text.length) { segments.push(new RichSegment(RichKind.Plain, text.substring(cursor), '')); }
    return segments;
  }

  private static trimTail(value: string): string {
    let end: number = value.length;
    while (end > 0 && LINK_TAIL.indexOf(value.charAt(end - 1)) >= 0) { end--; }
    return value.substring(0, end);
  }

  /** 系统浏览器打开；无协议地址补 https，失败只提示不弹错误页。 */
  static openUrl(ctx: common.UIAbilityContext, url: string): void {
    const value: string = url.trim();
    if (value.length === 0) { return; }
    const uri: string = new RegExp('^[a-zA-Z][a-zA-Z0-9+.\\-]*:\\/\\/').test(value) ? value : 'https://' + value;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: uri
    };
    ctx.startAbility(want).catch((): void => { RichText.toast('无法打开链接'); });
  }

  static toast(message: string): void {
    try {
      promptAction.showToast({ message: message, duration: 1600 });
    } catch (_) { }
  }
}
