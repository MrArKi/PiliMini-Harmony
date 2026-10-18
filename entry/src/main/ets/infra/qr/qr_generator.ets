/**
 * 二维码生成（spec-03 任务 3.1）
 * zxing 编码 → BitMatrix → RGBA buffer → PixelMap
 */
import { image } from '@kit.ImageKit';
import { MultiFormatWriter, BarcodeFormat } from '@ohos/zxing';

export function generateQrPixelMap(content: string, size: number): image.PixelMap | undefined {
  try {
    const writer = new MultiFormatWriter();
    const matrix = writer.encode(content, BarcodeFormat.QR_CODE, size, size, null);
    const w: number = matrix.getWidth();
    const h: number = matrix.getHeight();
    const buf = new ArrayBuffer(w * h * 4);
    const view = new Uint32Array(buf);
    for (let y = 0; y < h; y++) {
      const rowOff = y * w;
      for (let x = 0; x < w; x++) {
        view[rowOff + x] = matrix.get(x, y) ? 0xFF000000 : 0xFFFFFFFF;
      }
    }
    const opts: image.InitializationOptions = {
      size: { width: w, height: h },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true
    };
    return image.createPixelMapSync(buf, opts);
  } catch (e) {
    console.warn('[QR] 生成失败: ' + JSON.stringify(e));
    return undefined;
  }
}
