/** 详情宿主句柄：独立于详情树，首页初始化不加载播放器/评论/下载依赖。 */
import { HeroRect } from '../../common/hero_route';

export class VideoDetailHandle {
  bindingGeneration: number = 0;
  show: () => void = (): void => {};
  hide: (covered?: boolean) => void = (): void => {};
  prepareExit: () => Promise<void> = (): Promise<void> => Promise.resolve();
  cancelExit: () => void = (): void => {};
  back: () => boolean = (): boolean => false;
  exit: (toHome: boolean) => void = (): void => {};
  routeEntry: (progress: number) => void = (): void => {};
  /** 窗口vp；只含状态栏下方实际可见（已裁剪）的播放器区域。 */
  visualRect: () => HeroRect = (): HeroRect => new HeroRect();
  /** 宿主设置；详情布局/源尺寸变化时报告同一坐标系矩形，不轮询。 */
  onVisualRect: (rect: HeroRect) => void = (_rect: HeroRect): void => {};
  /** 宿主设置；当前源的原生视频输出就绪并完成后续渲染帧时通知。 */
  onVisualReady: () => void = (): void => {};
  /** 宿主设置；首次播放失败时撤去封面，显露详情/播放器错误与重试入口。 */
  onVisualUnavailable: () => void = (): void => {};
}
