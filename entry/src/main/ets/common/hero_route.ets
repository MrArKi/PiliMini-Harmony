import { image } from '@kit.ImageKit';
/**
 * 首页卡片 → 详情的「一镜到底」路由出口（spec-33）
 * 共享元素要求两端在同一棵 UI 树，详情必须由 MainShell 的 NavPathStack 推入。
 * 未注册时 push 返回 false，调用方回退 router，任何入口都不会失效。
 */
/** 被点击封面在窗口中的矩形（vp） */
export class HeroRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;

  constructor(x: number = 0, y: number = 0, w: number = 0, h: number = 0) {
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
  }
}

export class VideoNavParam {
  bvid: string = '';
  cid: number = 0;
  title: string = '';
  cover: string = '';
  rect: HeroRect = new HeroRect();
  sourceId: string = '';
  pixelMap: image.PixelMap | undefined = undefined;

  constructor(bvid: string, cid: number, title: string, cover: string = '', rect: HeroRect = new HeroRect(), sourceId: string = '', pixelMap: image.PixelMap | undefined = undefined) {
    this.bvid = bvid;
    this.cid = cid;
    this.title = title;
    this.cover = cover;
    this.rect = rect;
    this.sourceId = sourceId;
    this.pixelMap = pixelMap;
  }
}

export class HeroSourceHandle {
  setHidden: (hidden: boolean) => void = (): void => {};
  rect: () => HeroRect = (): HeroRect => new HeroRect();
  setFrame: (frame: image.PixelMap | undefined) => void = (): void => {};
}

export class HeroRoute {
  private static sources: Map<string, HeroSourceHandle> = new Map<string, HeroSourceHandle>();
  private static frameSource: string = '';
  static registerSource(id: string, handle: HeroSourceHandle): void { HeroRoute.sources.set(id, handle); }
  static hideSource(id: string, hidden: boolean): void {
    const handle: HeroSourceHandle | undefined = HeroRoute.sources.get(id);
    if (handle !== undefined) { handle.setHidden(hidden); }
  }
  static sourceRect(id: string): HeroRect {
    const handle: HeroSourceHandle | undefined = HeroRoute.sources.get(id);
    return handle === undefined ? new HeroRect() : handle.rect();
  }
  static unregisterSource(id: string): void {
    HeroRoute.sources.delete(id);
    if (HeroRoute.frameSource === id) { HeroRoute.frameSource = ''; }
  }
  /** 回程两端临时持有同一视频帧，转场完成即清除并恢复原封面。 */
  static setSourceFrame(id: string, frame: image.PixelMap): boolean {
    const handle: HeroSourceHandle | undefined = HeroRoute.sources.get(id);
    if (handle === undefined) { return false; }
    HeroRoute.clearSourceFrame();
    HeroRoute.frameSource = id;
    handle.setFrame(frame);
    return true;
  }
  static clearSourceFrame(): void {
    const handle: HeroSourceHandle | undefined = HeroRoute.sources.get(HeroRoute.frameSource);
    if (handle !== undefined) { handle.setFrame(undefined); }
    HeroRoute.frameSource = '';
  }
  /** 返回 true 表示已由 Navigation 接管 */
  static push: (param: VideoNavParam) => boolean = (): boolean => false;
  /** 首页封面布局变化时报告当前窗口矩形，供返回转场校正落点。 */
  static updateRect: (sourceId: string, rect: HeroRect) => void = (): void => {};
}
