/**
 * 假数据（性能验证备用；首页已接入真实数据仍保留此文件供调试）
 */
import { VideoItem } from '../model/video_item';

const COVERS: string[] = [
  'https://i2.hdslb.com/bfs/archive/620c7c116e812bd8840430230d6df111e0a54163.jpg',
  'https://i2.hdslb.com/bfs/archive/15f56cd9405b6eb29622e045d12617e08a6730bf.jpg',
  'https://i0.hdslb.com/bfs/archive/137d533fa9125e9ae3440ababe759f131586bec0.jpg',
  'https://i1.hdslb.com/bfs/archive/b7350e999443ab1fbc376419ae0af31ff6a99f23.jpg',
  'https://i2.hdslb.com/bfs/archive/08af6efbda1bea0070171f1a5afff0ee6eca7bb6.jpg',
  'https://i1.hdslb.com/bfs/archive/33f481a0a299be6d052501b80e5d2daf98807bff.jpg'
];

const TITLES: string[] = [
  '性能验证样本 · 列表滚动测试',
  'PiliMini 调试 · 卡片渲染与图片缓存',
  '这是一条用于验证标题两行截断的长标题样本，超出部分应省略',
  '占位数据 · 用于调试'
];

export function buildMockList(count: number): VideoItem[] {
  const items: VideoItem[] = [];
  for (let i = 0; i < count; i++) {
    const item: VideoItem = {
      key: 'mock_' + i.toString(),
      bvid: 'BV_mock_' + i.toString(),
      cid: 0,
      title: TITLES[i % TITLES.length] + '（No.' + (i + 1).toString() + '）',
      cover: COVERS[i % COVERS.length],
      upName: 'UP主' + (i % 20).toString(),
      upFace: '',
      playCount: 1000 + i * 12345,
      danmaku: 100 + i * 7,
      pubdate: 1758000000 + i * 3600,
      duration: 60 + (i * 7) % 3600
    };
    items.push(item);
  }
  return items;
}
