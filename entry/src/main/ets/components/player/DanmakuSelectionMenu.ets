/** 透明选项内容；唯一系统材质由宿主bindPopup提供（包括箭头）。 */
import { DanmakuItem } from '../../model/danmaku';

const MENU_TEXT: string = '#F1F1F1';
const MENU_SECONDARY: string = '#C2C2C2';

function selectionTime(time: number): string {
  const seconds: number = Math.max(0, Math.floor(time / 1000));
  const minutes: string = Math.floor(seconds / 60).toString();
  const remain: string = (seconds % 60).toString();
  return (minutes.length < 2 ? '0' : '') + minutes + ':' + (remain.length < 2 ? '0' : '') + remain;
}

@Component
export struct DanmakuSelectionMenu {
  @Prop item: DanmakuItem;
  @Prop maxHeight: number = 400;
  onClose: () => void = () => {};
  onCopy: (item: DanmakuItem) => void = () => {};
  onHide: (item: DanmakuItem) => void = () => {};
  onKeyword: (item: DanmakuItem) => void = () => {};
  onSender: (item: DanmakuItem) => void = () => {};

  @Builder
  Action(label: string, id: string, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(13).fontColor(MENU_TEXT).width('100%')
    }.width('100%').height(42).padding(0).borderRadius(6).backgroundColor(Color.Transparent)
      .id(id).accessibilityText(label).onClick(action)
  }

  build() {
    Scroll() {
      Column() {
        Row() {
          Text('弹幕操作').fontSize(13).fontColor(MENU_SECONDARY).layoutWeight(1)
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.icon_clear')).width(16).height(16).fillColor(MENU_SECONDARY)
          }.width(32).height(32).padding(0).borderRadius(16).backgroundColor(Color.Transparent)
            .id('dm_select_close').accessibilityText('关闭弹幕操作').onClick(this.onClose)
        }.width('100%')
        Scroll() {
          Text(this.item.text).fontSize(14).fontColor(MENU_TEXT).width('100%').padding({ top: 10, bottom: 10 })
        }.width('100%').constraintSize({ maxHeight: 100 }).scrollBar(BarState.Auto)
        Text(selectionTime(this.item.time) + ' · ' + (this.item.mode === 5 ? '顶部' : (this.item.mode === 4 ? '底部' : '滚动')))
          .fontSize(11).fontColor(MENU_SECONDARY).width('100%').margin({ top: 6, bottom: 4 })
        this.Action('复制文字', 'dm_select_copy', () => { this.onCopy(this.item); })
        this.Action('本视频隐藏这条', 'dm_select_hide', () => { this.onHide(this.item); })
        this.Action('添加关键词屏蔽', 'dm_select_keyword', () => { this.onKeyword(this.item); })
        if (this.item.midHash.length > 0) {
          this.Action('屏蔽该发送者的弹幕', 'dm_select_sender', () => { this.onSender(this.item); })
        }
      }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
    }.width(280).constraintSize({ maxHeight: this.maxHeight }).scrollBar(BarState.Auto)
      .backgroundColor(Color.Transparent).borderRadius(12)
  }
}
