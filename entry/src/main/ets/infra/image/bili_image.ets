/**
 * B 站图片地址工具（对齐 PiliNara `lib/utils/image_utils.dart`）
 *  - `thumbUrl`：列表/网格用缩略图（重写或追加 `@<w>w_<h>h_1c.webp`），避免拉原图
 *  - `originalUrl`：查看器用原图（去掉 `@尺寸_格式` 后缀）
 */
export function thumbUrl(src: string, w: number, h: number): string {
  if (src.length === 0) {
    return '';
  }
  const at: number = src.indexOf('@');
  const base: string = at > 0 ? src.substring(0, at) : src;
  if (w <= 0 && h <= 0) {
    return base;
  }
  const parts: string[] = [];
  if (w > 0) {
    parts.push(w.toString() + 'w');
  }
  if (h > 0) {
    parts.push(h.toString() + 'h');
  }
  parts.push('1c');
  return base + '@' + parts.join('_') + '.webp';
}

/** 原图（去掉 `@1035w_1035h_1e_1c.webp` 之类的后缀） */
export function originalUrl(src: string): string {
  if (src.length === 0) {
    return '';
  }
  const at: number = src.indexOf('@');
  return at > 0 ? src.substring(0, at) : src;
}

/** Nara NetworkImgLayer同样先请求CDN缩略图；尺寸只是解码参数时仍会下载原图。 */
export function imageRequestUrl(src: string, w: number, h: number, original: boolean = false): string {
  if (original || !/^https?:\/\/[^/]+\.(hdslb\.com|biliimg\.com)\//i.test(src)) { return src; }
  const base: string = originalUrl(src);
  if (!/\.(jpe?g|png|webp|gif|avif)$/i.test(base)) { return src; }
  // 只指定一条边并保留完整内容，裁剪由布局负责，不能破坏缩略图往返转场。
  const size: number = Math.max(1, Math.round(w <= h ? w : h));
  return base + '@' + size.toString() + (w <= h ? 'w' : 'h') + '_80q.webp';
}

export function isDiskThumbnail(url: string): boolean {
  return /^https?:\/\/[^/]+\.(hdslb\.com|biliimg\.com)\/.+@\d+[wh]_80q\.webp$/i.test(url);
}
