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
  Emote = 3
}

export class RichSegment {
  kind: RichKind = RichKind.Plain;
  text: string = '';
  /** Link=可打开的地址（可能省略协议）；Mention=不带@的用户名；Emote=图片地址 */
  target: string = '';
  /** 仅 Emote 使用：接口 meta.size（1 常规 / 2 大表情）。 */
  size: number = 1;

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
        if (emotes[i].key.length === 0) { continue; }
        const at: number = text.indexOf(emotes[i].key, cursor);
        if (at >= 0 && (hitAt < 0 || at < hitAt)) { hitAt = at; hit = emotes[i]; }
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
