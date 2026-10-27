/**
 * 搜索联想高亮解析（对齐 Nara `utils/em.dart`）：
 * 服务端把命中词包在 `<em class="suggest_high_light">` 里，这里拆成 {命中, 文本} 段。
 * 只做切分与实体解码，样式由宿主决定；不发起网络请求。
 */

export class EmPart {
  isEm: boolean = false;
  text: string = '';

  constructor(isEm: boolean, text: string) {
    this.isEm = isEm;
    this.text = text;
  }
}

/** 无 g 标志：每轮用剩余串重新匹配，避免 lastIndex 残留。对应 Nara `<[^>]*>([^<]*)</[^>]*>`。 */
const TAG_PATTERN: RegExp = new RegExp('<[^>]*>([^<]*)<\\/[^>]*>');

export class Em {
  /** 拆段：命中段 isEm=true；连续普通文本合并；空串返回空数组。 */
  static parse(origin: string): EmPart[] {
    const parts: EmPart[] = [];
    if (origin.length === 0) {
      return parts;
    }
    let rest: string = origin;
    while (rest.length > 0) {
      const match: RegExpExecArray | null = TAG_PATTERN.exec(rest);
      if (match === null) {
        parts.push(new EmPart(false, Em.decode(rest)));
        break;
      }
      if (match.index > 0) {
        parts.push(new EmPart(false, Em.decode(rest.substring(0, match.index))));
      }
      const inner: string = match[1] === undefined ? match[0] : match[1];
      parts.push(new EmPart(true, Em.decode(inner)));
      rest = rest.substring(match.index + match[0].length);
    }
    return parts;
  }

  /** 命中段的纯文本拼接（用于无障碍朗读或复制场景）。 */
  static plain(origin: string): string {
    const parts: EmPart[] = Em.parse(origin);
    let out: string = '';
    for (let i: number = 0; i < parts.length; i++) {
      out += parts[i].text;
    }
    return out;
  }

  /** 解 HTML 实体：五个命名实体 + `&#xNNNN;`；无法识别时原样保留。 */
  private static decode(input: string): string {
    if (input.indexOf('&') < 0) {
      return input;
    }
    let out: string = '';
    let i: number = 0;
    while (i < input.length) {
      const ch: string = input.charAt(i);
      if (ch === '&') {
        const semi: number = input.indexOf(';', i);
        if (semi > i && semi - i <= 8) {
          const decoded: string = Em.entity(input.substring(i + 1, semi));
          if (decoded.length > 0) {
            out += decoded;
            i = semi + 1;
            continue;
          }
        }
      }
      out += ch;
      i++;
    }
    return out;
  }

  private static entity(body: string): string {
    if (body === 'lt') { return '<'; }
    if (body === 'gt') { return '>'; }
    if (body === 'quot') { return '"'; }
    if (body === 'apos') { return '\''; }
    if (body === 'nbsp') { return ' '; }
    if (body === 'amp') { return '&'; }
    if (body.length > 2 && body.charAt(0) === '#' && (body.charAt(1) === 'x' || body.charAt(1) === 'X')) {
      const code: number = parseInt(body.substring(2), 16);
      if (!isNaN(code) && code > 0 && code <= 0xFFFF) {
        return String.fromCharCode(code);
      }
    }
    return '';
  }
}
