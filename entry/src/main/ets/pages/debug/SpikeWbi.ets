/**
 * SP-2 验证页：wbi 签名 → rcmd（首页推荐）/ 搜索
 */
import { getJson, buildQuery } from '../../infra/http/http';
import { wbiSign, getMixinKeyCached } from '../../infra/sign/wbi';
import { API_BASE } from '../../config/constants';

interface RcmdItem {
  title?: string;
  bvid?: string;
  goto?: string;
}

interface RcmdData {
  item?: RcmdItem[];
}

interface RcmdResp {
  code: number;
  message: string;
  data?: RcmdData;
}

interface SearchItem {
  title?: string;
  bvid?: string;
}

interface SearchData {
  result?: SearchItem[];
}

interface SearchResp {
  code: number;
  message: string;
  data?: SearchData;
}

@Entry
@Component
struct SpikeWbi {
  @State keyword: string = '原神';
  @State logText: string = '';

  private append(line: string): void {
    this.logText = this.logText + line + '\n';
  }

  private stripTag(s: string): string {
    return s.replace(/<[^>]+>/g, '');
  }

  private async testMixinKey(): Promise<void> {
    try {
      const key: string = await getMixinKeyCached();
      this.append('[ok] mixinKey=' + key + '（长度 ' + key.length + '）');
    } catch (e) {
      this.append('[!] mixinKey 失败: ' + JSON.stringify(e));
    }
  }

  private async testRcmd(): Promise<void> {
    this.append('== rcmd（首页推荐，wbi 签名）');
    try {
      const params: Record<string, string> = {
        'web_location': '1430650',
        'y_num': '5',
        'fresh_type': '4',
        'feed_version': 'V8',
        'fresh_idx_1h': '1',
        'fetch_row': '1',
        'fresh_idx': '1',
        'brush': '0',
        'homepage_ver': '1',
        'ps': '12',
        'last_y_num': '5',
        'screen': '1920-1080'
      };
      const signed: Record<string, string> = await wbiSign(params);
      const url: string = API_BASE + '/x/web-interface/wbi/index/top/feed/rcmd?' + buildQuery(signed);
      const raw: string = await getJson(url);
      const resp = JSON.parse(raw) as RcmdResp;
      this.append('[ok] code=' + resp.code + ' msg=' + resp.message);
      const data: RcmdData | undefined = resp.data;
      if (data !== undefined && data.item !== undefined) {
        this.append('[ok] items=' + data.item.length);
        for (let i = 0; i < data.item.length && i < 5; i++) {
          const t: string = data.item[i].title !== undefined ? data.item[i].title as string : '?';
          this.append('  ' + (i + 1) + '. ' + this.stripTag(t));
        }
      } else {
        this.append('[!] 无 item 数据');
      }
    } catch (e) {
      this.append('[!] rcmd 异常: ' + JSON.stringify(e));
    }
  }

  private async testSearch(): Promise<void> {
    this.append('== search（关键词=' + this.keyword + '，wbi 签名）');
    try {
      const params: Record<string, string> = {
        'search_type': 'video',
        'keyword': this.keyword,
        'page': '1',
        'page_size': '10',
        'web_location': '1430650'
      };
      const signed: Record<string, string> = await wbiSign(params);
      const url: string = API_BASE + '/x/web-interface/wbi/search/type?' + buildQuery(signed);
      const raw: string = await getJson(url);
      const resp = JSON.parse(raw) as SearchResp;
      this.append('[ok] code=' + resp.code + ' msg=' + resp.message);
      const data: SearchData | undefined = resp.data;
      if (data !== undefined && data.result !== undefined) {
        this.append('[ok] results=' + data.result.length);
        for (let i = 0; i < data.result.length && i < 5; i++) {
          const t: string = data.result[i].title !== undefined ? data.result[i].title as string : '?';
          this.append('  ' + (i + 1) + '. ' + this.stripTag(t));
        }
      } else {
        this.append('[!] 无 result 数据');
      }
    } catch (e) {
      this.append('[!] search 异常: ' + JSON.stringify(e));
    }
  }

  build() {
    Column({ space: 8 }) {
      Text('SP-2 wbi 签名验证')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16 })

      Row({ space: 8 }) {
        Button('取 mixinKey')
          .fontSize(13)
          .onClick(() => {
            this.testMixinKey();
          })
        Button('签名+rcmd')
          .fontSize(13)
          .onClick(() => {
            this.testRcmd();
          })
        Button('清空')
          .fontSize(13)
          .onClick(() => {
            this.logText = '';
          })
      }
      .width('92%')

      Row({ space: 8 }) {
        TextInput({ text: this.keyword, placeholder: '搜索关键词' })
          .layoutWeight(1)
          .fontSize(13)
          .onChange((v: string) => {
            this.keyword = v;
          })
        Button('签名+搜索')
          .fontSize(13)
          .onClick(() => {
            this.testSearch();
          })
      }
      .width('92%')

      Scroll() {
        Text(this.logText)
          .fontSize(11)
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('92%')
      .backgroundColor('#FAFAFA')
      .borderRadius(8)
      .padding(8)
    }
    .width('100%')
    .height('100%')
  }
}
