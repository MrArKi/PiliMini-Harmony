/**
 * 稍后再看页（spec-07）
 *  VideoCard 列表 + 每条右侧删除 + 下拉刷新 + 清空全部
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router, promptAction } from '@kit.ArkUI';
import { VideoCard } from '../../components/VideoCard';
import { LoadingFooter, ErrorRetry, EmptyState } from '../../components/StateViews';
import { FavService } from '../../service/fav_service';
import { AuthService } from '../../service/auth_service';
import { VideoItem } from '../../model/video_item';

@Entry
@Component
struct LaterPage {
  @State items: VideoItem[] = [];
  @State loading: boolean = true;
  @State err: string = '';
  @State loggedIn: boolean = false;
  @State refreshing: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;

  aboutToAppear(): void {
    this.init();
  }

  private async init(): Promise<void> {
    this.err = '';
    this.loading = true;
    // strict：网络失败不能折叠成"未登录"
    try {
      const u = await AuthService.fetchNav(true);
      this.loggedIn = u !== null;
    } catch (e) {
      this.loading = false;
      this.err = '网络异常，请检查网络后重试';
      return;
    }
    if (!this.loggedIn) {
      this.loading = false;
      return;
    }
    await this.load();
  }

  private async load(): Promise<void> {
    this.err = '';
    try {
      this.items = await FavService.laterList();
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  /** 清空：逐条删（接口无批量），失败的必须留在列表里，不能谎报已清空 */
  private async clearAll(): Promise<void> {
    const all: VideoItem[] = this.items.slice();
    const remain: VideoItem[] = [];
    for (let i: number = 0; i < all.length; i++) {
      const aid: number = all[i].aid ?? 0;
      if (aid <= 0) { remain.push(all[i]); continue; }
      try {
        await FavService.laterRemove(aid);
      } catch (e) {
        remain.push(all[i]);
      }
    }
    this.items = remain;
    if (remain.length === 0) {
      promptAction.showToast({ message: '已清空' });
    } else {
      promptAction.showToast({ message: '还有 ' + remain.length.toString() + ' 条未能移除，请重试' });
    }
  }

  private async removeOne(it: VideoItem): Promise<void> {
    try {
      const aid: number = it.aid ?? -1;
      await FavService.laterRemove(aid);
      const next: VideoItem[] = [];
      for (let i = 0; i < this.items.length; i++) {
        if (this.items[i].key !== it.key) {
          next.push(this.items[i]);
        }
      }
      this.items = next;
      promptAction.showToast({ message: '已移出稍后再看' });
    } catch (e) {
      promptAction.showToast({ message: '移除失败：' + (e as Error).message });
    }
  }

  /** 与Nara默认Cupertino一致：300ms，底页1/3视差。 */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '100%' })
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 8 }) {
        Image($r('app.media.icon_arrow_left'))
            .width(22).height(22)
          .fillColor($r('app.color.text_primary'))
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            router.back();
          })
        Text('稍后再看')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.items.length > 0) {
          Text('清空')
            .fontSize(13)
            .fontColor($r('app.color.brand_pink'))
            .padding({ left: 8, right: 8 })
            .onClick((): void => {
              if (this.items.length === 0) { return; }
              AlertDialog.show({
                title: '清空稍后再看',
                message: '将从 B 站账号移除全部 ' + this.items.length.toString() + ' 个视频，此操作不可撤销。',
                primaryButton: { value: '取消', action: (): void => {} },
                secondaryButton: {
                  value: '清空', fontColor: '#E54D42',
                  action: (): void => { this.clearAll(); }
                }
              });
            })
        }
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
      .backgroundColor($r('app.color.card_bg'))

      if (this.loading) {
        Column() {
          LoadingProgress().width(40).height(40)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.err.length > 0) {
        ErrorRetry({ text: this.err, onRetry: (): void => {
          this.init();
        } })
      } else if (!this.loggedIn) {
        Column({ space: 12 }) {
          Text('未登录')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Button('去登录')
            .fontSize(13)
            .backgroundColor($r('app.color.brand_pink'))
            .onClick(() => {
              router.pushUrl({ url: 'pages/login/LoginPage' });
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List() {
            ForEach(this.items, (it: VideoItem) => {
              ListItem() {
                Stack({ alignContent: Alignment.End }) {
                  VideoCard({ model: it })
                  // Nara 同款：右侧「×」移除按钮（不用文字按钮）
                  Column() {
                    Image($r('app.media.icon_clear'))
                      .width(16)
                      .height(16)
                      .fillColor($r('app.color.text_secondary'))
                  }
                  .width(36)
                  .height(36)
                  .justifyContent(FlexAlign.Center)
                  .margin({ right: 4 })
                  .onClick(() => {
                    this.removeOne(it);
                  })
                }
                .width('100%')
              }
            }, (it: VideoItem) => it.key)
            ListItem() {
              if (this.items.length === 0) {
                EmptyState({ text: '稍后再看空空如也' })
              } else {
                LoadingFooter({ text: '共 ' + this.items.length.toString() + ' 条', loading: false })
              }
            }
          }
          .width('100%')
          .layoutWeight(1)
        }
        .onRefreshing(() => {
          this.load();
        })
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
