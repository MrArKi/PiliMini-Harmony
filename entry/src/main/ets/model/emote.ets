/** 评论正文里的 B 站表情：key 是正文占位符（如 [doge]），url 已补全协议。 */
export class CommentEmote {
  key: string = '';
  url: string = '';
  /** 接口 meta.size：1 常规、2 大表情（Nara 按 20/40 渲染）。 */
  size: number = 1;
}
