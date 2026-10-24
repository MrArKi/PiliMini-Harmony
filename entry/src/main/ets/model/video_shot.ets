/** B站videoshot雪碧图；时间索引与Nara的count(index<=秒)-2保持一致。 */
export interface VideoShotData {
  columns: number;
  rows: number;
  frameWidth: number;
  frameHeight: number;
  images: string[];
  index: number[];
}

export interface VideoShotFrame {
  index: number;
  page: number;
  column: number;
  row: number;
}

export function videoShotFrameAt(data: VideoShotData, seconds: number): VideoShotFrame {
  let lo: number = 0;
  let hi: number = data.index.length;
  while (lo < hi) {
    const mid: number = Math.floor((lo + hi) / 2);
    if (data.index[mid] <= seconds) { lo = mid + 1; } else { hi = mid; }
  }
  const perPage: number = data.columns * data.rows;
  const index: number = Math.max(0, Math.min(lo - 2, data.images.length * perPage - 1));
  const within: number = index % perPage;
  return { index: index, page: Math.floor(index / perPage), column: within % data.columns,
    row: Math.floor(within / data.columns) };
}
