/**
 * 二维码生成（spec-03 任务 3.1）
 * 官方 Scan Kit `generateBarcode` 直接出 PixelMap：
 *  - 替代原 @ohos/zxing 第三方编码 + 手写 RGBA 缓冲 + createPixelMapSync
 *  - 编码在原生层完成，不再占用 UI 线程（原实现 240×240 逐像素 57600 次循环）
 *  - 去掉一个第三方依赖
 */
import { image } from '@kit.ImageKit';
import { generateBarcode, scanCore } from '@kit.ScanKit';

/** 官方宽高取值范围 [200, 4096]（px） */
const MIN_PX: number = 200;
const MAX_PX: number = 4096;

export async function generateQrPixelMap(content: string, size: number): Promise<image.PixelMap | undefined> {
  if (content.length === 0) {
    return undefined;
  }
  const px: number = Math.max(MIN_PX, Math.min(MAX_PX, Math.round(size)));
  const options: generateBarcode.CreateOptions = {
    scanType: scanCore.ScanType.QR_CODE,
    width: px,
    height: px,
    // 官方 margin 取值 1~10；1 与 B 站网页二维码的静区一致
    margin: 1,
    // 扫码场景用 M（15%）即可：L 在屏幕反光下识别率低，H 会让码点变密
    level: generateBarcode.ErrorCorrectionLevel.LEVEL_M
  };
  try {
    return await generateBarcode.createBarcode(content, options);
  } catch (e) {
    console.warn('[QR] ScanKit 生成失败: ' + JSON.stringify(e));
    return undefined;
  }
}
