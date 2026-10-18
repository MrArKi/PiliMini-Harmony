/**
 * SP-1 取流验证页：
 * 1) view 接口拿 cid/title（无需签名）
 * 2) playurl 拿 durl（无签名，≤720P）
 * 3) playurl + fnval=16 尝试 DASH（独立音轨）
 * 结果可一键发送到播放器页验证。
 */
import { http } from '@kit.NetworkKit';
import { router } from '@kit.ArkUI';

const UA_PC: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const REFERER: string = 'https://www.bilibili.com';

interface ViewData {
  cid: number;
  title: string;
  duration: number;
}

interface ViewResp {
  code: number;
  message: string;
  data?: ViewData;
}

interface DurlItem {
  order: number;
  length: number;
  size: number;
  url: string;
}

interface DashItem {
  id: number;
  baseUrl: string;
  bandwidth: number;
}

interface DashData {
  duration: number;
  video: DashItem[];
  audio: DashItem[];
}

interface PlayData {
  quality: number;
  format: string;
  accept_quality?: number[];
  durl?: DurlItem[];
  dash?: DashData;
}

interface PlayResp {
  code: number;
  message: string;
  data?: PlayData;
}

@Entry
@Component
struct SpikeNet {
  @State bvid: string = 'BV1GJ411x7h7';
  @State cid: number = 0;
  @State title: string = '';
  @State logText: string = '';
  @State lastDurl: string = '';
  @State lastDashVideo: string = '';
  @State lastDashAudio: string = '';

  private append(line: string): void {
    this.logText = this.logText + line + '\n';
  }

  private async getJson(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'User-Agent': UA_PC,
        'Referer': REFERER
      };
      const res = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      if (typeof res.result === 'string') {
        return res.result as string;
      }
      return JSON.stringify(res.result);
    } catch (e) {
      this.append('[!] 网络异常: ' + JSON.stringify(e));
      return '';
    } finally {
      req.destroy();
    }
  }

  private async fetchInfo(): Promise<void> {
    this.append('== view: ' + this.bvid);
    const raw: string = await this.getJson('https://api.bilibili.com/x/web-interface/view?bvid=' + this.bvid);
    if (raw.length === 0) {
      return;
    }
    let resp: ViewResp;
    try {
      resp = JSON.parse(raw) as ViewResp;
    } catch (e) {
      this.append('[!] JSON 解析失败');
      return;
    }
    if (resp.code !== 0) {
      this.append('[!] code=' + resp.code + ' msg=' + resp.message);
      return;
    }
    const data: ViewData | undefined = resp.data;
    if (data === undefined) {
      this.append('[!] data 为空');
      return;
    }
    this.cid = data.cid;
    this.title = data.title;
    this.append('[ok] cid=' + this.cid);
    this.append('[ok] title=' + this.title);
  }

  private async fetchDurl(): Promise<void> {
    if (this.cid === 0) {
      this.append('[!] 先点「查询视频信息」');
      return;
    }
    this.append('== playurl durl qn=64（无签名 / 默认，可能返回 PCDN 域名）');
    await this.fetchDurlInner('https://api.bilibili.com/x/player/playurl?bvid=' + this.bvid + '&cid=' + this.cid + '&qn=64&otype=json');
  }

  private async fetchDurlHtml5(): Promise<void> {
    if (this.cid === 0) {
      this.append('[!] 先点「查询视频信息」');
      return;
    }
    this.append('== playurl durl（platform=html5，普通 CDN）');
    await this.fetchDurlInner('https://api.bilibili.com/x/player/playurl?bvid=' + this.bvid + '&cid=' + this.cid + '&platform=html5&high_quality=1&otype=json');
  }

  private async fetchDurlInner(url: string): Promise<void> {
    const raw: string = await this.getJson(url);
    if (raw.length === 0) {
      return;
    }
    let resp: PlayResp;
    try {
      resp = JSON.parse(raw) as PlayResp;
    } catch (e) {
      this.append('[!] JSON 解析失败');
      return;
    }
    if (resp.code !== 0) {
      this.append('[!] code=' + resp.code + ' msg=' + resp.message);
      return;
    }
    const data: PlayData | undefined = resp.data;
    if (data === undefined) {
      this.append('[!] data 为空');
      return;
    }
    this.append('[ok] quality=' + data.quality + ' format=' + data.format);
    const dl: DurlItem[] | undefined = data.durl;
    if (dl !== undefined && dl.length > 0) {
      this.lastDurl = dl[0].url;
      this.append('[ok] durl[0] size=' + dl[0].size + ' length=' + dl[0].length + ' host=' + this.hostOf(dl[0].url));
      this.append('[url] ' + this.lastDurl);
    } else {
      this.append('[!] 无 durl 数据');
    }
  }

  private hostOf(u: string): string {
    const i: number = u.indexOf('://');
    if (i < 0) {
      return '?';
    }
    const rest: string = u.substring(i + 3);
    const j: number = rest.indexOf('/');
    return j > 0 ? rest.substring(0, j) : rest;
  }

  private async fetchDash(): Promise<void> {
    if (this.cid === 0) {
      this.append('[!] 先点「查询视频信息」');
      return;
    }
    this.append('== playurl dash fnval=16（若无登录可能降级/报错）');
    const url: string = 'https://api.bilibili.com/x/player/playurl?bvid=' + this.bvid + '&cid=' + this.cid + '&qn=80&fnval=16&otype=json';
    const raw: string = await this.getJson(url);
    if (raw.length === 0) {
      return;
    }
    let resp: PlayResp;
    try {
      resp = JSON.parse(raw) as PlayResp;
    } catch (e) {
      this.append('[!] JSON 解析失败');
      return;
    }
    if (resp.code !== 0) {
      this.append('[!] code=' + resp.code + ' msg=' + resp.message);
      return;
    }
    const data: PlayData | undefined = resp.data;
    if (data === undefined) {
      this.append('[!] data 为空');
      return;
    }
    const dash: DashData | undefined = data.dash;
    if (dash === undefined) {
      this.append('[!] 无 dash 数据（可能需要登录）');
      return;
    }
    if (dash.video.length > 0) {
      this.lastDashVideo = dash.video[0].baseUrl;
      this.append('[ok] dash.video[0] id=' + dash.video[0].id + ' bw=' + dash.video[0].bandwidth);
      this.append('[url] ' + this.lastDashVideo);
    }
    if (dash.audio.length > 0) {
      this.lastDashAudio = dash.audio[0].baseUrl;
      this.append('[ok] dash.audio[0] id=' + dash.audio[0].id + ' bw=' + dash.audio[0].bandwidth);
      this.append('[url] ' + this.lastDashAudio);
    }
  }

  private async testReach(): Promise<void> {
    if (this.lastDurl.length === 0) {
      this.append('[!] 先取 durl');
      return;
    }
    this.append('== 可达性测试（Range 0-1023）host=' + this.hostOf(this.lastDurl));
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'User-Agent': UA_PC,
        'Referer': REFERER,
        'Range': 'bytes=0-1023'
      };
      const res = await req.request(this.lastDurl, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 10000
      });
      this.append('[ok] code=' + res.responseCode);
      if (typeof res.result === 'string') {
        this.append('[body] ' + (res.result as string).substring(0, 50));
      } else {
        this.append('[body] 二进制响应（长度正常）');
      }
    } catch (e) {
      this.append('[!] 请求异常: ' + JSON.stringify(e));
    } finally {
      req.destroy();
    }
  }

  private openAudioPlayer(streamUrl: string): void {
    if (streamUrl.length === 0) {
      this.append('[!] 无可播放 URL（先取 DASH）');
      return;
    }
    const params: Record<string, string> = { 'url': streamUrl };
    router.pushUrl({ url: 'pages/debug/SpikeAudio', params: params });
  }

  private openPlayer(streamUrl: string): void {
    if (streamUrl.length === 0) {
      this.append('[!] 无可播放 URL（先取流）');
      return;
    }
    const params: Record<string, string> = { 'url': streamUrl };
    router.pushUrl({ url: 'pages/debug/SpikePlayer', params: params });
  }

  build() {
    Column({ space: 8 }) {
      Text('SP-Net 网络与取流')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16 })

      Row({ space: 8 }) {
        TextInput({ text: this.bvid, placeholder: '输入 bvid' })
          .layoutWeight(1)
          .onChange((v: string) => {
            this.bvid = v;
          })
        Button('查视频信息')
          .fontSize(13)
          .onClick(() => {
            this.fetchInfo();
          })
      }
      .width('92%')

      Flex({ wrap: FlexWrap.Wrap }) {
        Button('取 durl（html5）')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.fetchDurlHtml5();
          })
        Button('取 durl（默认）')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.fetchDurl();
          })
        Button('取 DASH')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.fetchDash();
          })
        Button('清空')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.logText = '';
          })
      }
      .width('92%')

      Flex({ wrap: FlexWrap.Wrap }) {
        Button('测 URL 可达')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.testReach();
          })
        Button('durl → 播放器')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.openPlayer(this.lastDurl);
          })
        Button('dash.video → 播放器')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.openPlayer(this.lastDashVideo);
          })
        Button('dash.audio → 纯音频')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.openAudioPlayer(this.lastDashAudio);
          })
        Button('durl → 纯音频页')
          .fontSize(12)
          .margin(4)
          .onClick(() => {
            this.openAudioPlayer(this.lastDurl);
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
