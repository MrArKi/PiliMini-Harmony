/** MD5摘要统一使用系统cryptoFramework；与WBI网络/登录依赖分离。 */
import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export async function md5Hex(input: string): Promise<string> {
  const md = cryptoFramework.createMd('MD5');
  await md.update({ data: new Uint8Array(buffer.from(input, 'utf-8').buffer) });
  const digest = await md.digest();
  return buffer.from(digest.data).toString('hex');
}
