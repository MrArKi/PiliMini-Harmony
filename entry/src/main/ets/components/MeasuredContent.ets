/**
 * 用官方自定义布局量取折叠内容的自然高度，隐藏时仍测量，外层负责数值高度与裁剪。
 * SDK：CustomComponent.onMeasureSize/onPlaceChildren（API10）、FrameCallback（API12）。
 * content通常传一个Column；多个根节点按纵向顺序布局。所有布局尺寸单位均为vp。
 */
import { FrameCallback } from '@ohos.arkui.UIContext';

class ContentHeightFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(_time: number): void { this.action(); this.action = () => {}; }
}

@Component
export struct MeasuredContent {
  @BuilderParam content: () => void = this.EmptyContent;
  onHeight: (height: number) => void = () => {};
  private destroyed: boolean = false;
  private frameQueued: boolean = false;
  private layoutGeneration: number = 0;
  private pendingHeight: number = 0;
  private reportedHeight: number = -1;

  @Builder
  EmptyContent() {}

  aboutToAppear(): void {
    this.destroyed = false;
    this.layoutGeneration++;
    this.frameQueued = false;
    this.reportedHeight = -1;
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.layoutGeneration++;
    this.frameQueued = false;
  }

  /** 测量阶段只更新普通字段；下一帧合并提交最新自然高度，允许增高和变矮。 */
  private reportHeight(height: number): void {
    this.pendingHeight = height;
    if (this.destroyed || this.frameQueued || Math.abs(height - this.reportedHeight) < 0.5) { return; }
    this.frameQueued = true;
    const generation: number = this.layoutGeneration;
    try {
      this.getUIContext().postFrameCallback(new ContentHeightFrame((): void => {
        if (this.destroyed || generation !== this.layoutGeneration) { return; }
        this.frameQueued = false;
        const latest: number = this.pendingHeight;
        if (Math.abs(latest - this.reportedHeight) < 0.5) { return; }
        this.reportedHeight = latest;
        this.onHeight(latest);
      }));
    } catch (_) {
      // 生命周期尚未挂载时等待下一次布局，不在测量调用栈直接回写父组件状态。
      this.frameQueued = false;
    }
  }

  onMeasureSize(self: GeometryInfo, children: Measurable[], constraint: ConstraintSizeOptions): SizeResult {
    const limit: number = Number(constraint.maxWidth);
    const minimum: number = Number(constraint.minWidth);
    const fallback: number = Number.isFinite(self.width) && self.width > 0 ? self.width :
      (Number.isFinite(minimum) ? Math.max(0, minimum) : 0);
    const width: number = Number.isFinite(limit) ? Math.max(0, limit) : fallback;
    if (width <= 0) {
      return { width: 0, height: 0 };
    }
    let height: number = 0;
    children.forEach((child: Measurable): void => {
      const measured: MeasureResult = child.measure({ minWidth: width, maxWidth: width,
        // 内容根节点应使用LayoutPolicy.fixAtIdealSize解除折叠父层约束；此处只限定测量上界。
        minHeight: 0, maxHeight: 99999 });
      if (Number.isFinite(measured.height)) { height += Math.max(0, measured.height); }
    });
    this.reportHeight(height);
    return { width: width, height: height };
  }

  onPlaceChildren(_self: GeometryInfo, children: Layoutable[], _constraint: ConstraintSizeOptions): void {
    let y: number = 0;
    children.forEach((child: Layoutable): void => {
      child.layout({ x: 0, y: y });
      const height: number = child.measureResult.height;
      if (Number.isFinite(height)) { y += Math.max(0, height); }
    });
  }

  build() {
    this.content()
  }
}
