/**
 * 图片加载器（spec-02 任务 2.4）
 * 两级缓存：内存LRU（64张且16MiB）+大图槽（2张且16MiB）+磁盘（默认1GB）
 * 并发去重：同一 URL 并发请求合并为一次下载；解码降采样（默认 480x270）
 */
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { UA_PC, BILI_REFERER } from '../../config/constants';
import lazy { md5Hex } from '../sign/md5';
import { imageRequestUrl, isDiskThumbnail } from './bili_image';

const MEM_MAX: number = 64;
const MEM_BYTES_MAX: number = 16 * 1024 * 1024;
const BIG_BYTES_MAX: number = 16 * 1024 * 1024;
/** 单张解码后像素超过该值：不进主 LRU，改走「大图槽」（最多 2 张，供查看器来回翻看） */
const MEM_SKIP_PIXELS: number = 1_000_000;
/** 大图槽容量（张） */
const BIG_SLOTS: number = 2;
/** 磁盘缓存上限（可配；默认 1GB，对齐 Nara maxCacheSize 默认值） */
let diskLimitBytes: number = 1024 * 1024 * 1024;
/** 原图/异常大响应不长期占盘；只有成功解码的小缩略图可以持久缓存。 */
const DISK_FILE_MAX: number = 512 * 1024;
let diskBytes: number = 0;

interface DiskEntry {
  name: string;
  size: number;
  usedAt: number;
}

/** 大图槽（查看器用；最多 BIG_SLOTS 张，先进先出） */
const bigCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
const bigOrder: string[] = [];
const memCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
const memOrder: string[] = [];
const memSizes: Map<string, number> = new Map<string, number>();
const bigSizes: Map<string, number> = new Map<string, number>();
let memBytes: number = 0;
let bigBytes: number = 0;
const pending: Map<string, Promise<image.PixelMap>> = new Map<string, Promise<image.PixelMap>>();
let cacheDir: string = '';
let cacheGeneration: number = 0;
/** 扫描不占首帧；并发写盘/清空后旧统计不可回写。 */
let diskRevision: number = 0;
let trimTimer: number = -1;
let trimRunning: boolean = false;
let trimRequested: boolean = false;
const TRIM_BATCH: number = 8;

export function initImageLoader(dir: string): void {
  cacheDir = dir + '/img';
  try {
    if (!fileIo.accessSync(cacheDir)) {
      fileIo.mkdirSync(cacheDir);
    }
    scheduleDiskTrim();
  } catch (e) {
    console.warn('[ImgLoader] init 异常: ' + JSON.stringify(e));
  }
}

/** 合并初始化、限额设置和超限写入；不在Ability.onCreate同步遍历磁盘。 */
function scheduleDiskTrim(): void {
  trimRequested = true;
  if (trimTimer >= 0 || trimRunning || cacheDir.length === 0) { return; }
  trimTimer = setTimeout((): void => {
    trimTimer = -1;
    trimRunning = true;
    trimRequested = false;
    trimDisk(cacheDir, diskRevision).catch((e: Error): void => {
      console.warn('[ImgLoader] trim 异常: ' + e.message);
    }).finally((): void => {
      trimRunning = false;
      if (trimRequested) { scheduleDiskTrim(); }
    });
  }, 32);
}

function diskSnapshotCurrent(dir: string, revision: number): boolean {
  const current: boolean = cacheDir === dir && diskRevision === revision;
  if (!current) { trimRequested = true; }
  return current;
}

async function scanDiskEntry(dir: string, name: string, revision: number): Promise<DiskEntry | undefined> {
  if (!diskSnapshotCurrent(dir, revision)) { return undefined; }
  const path: string = dir + '/' + name;
  try {
    if (/^img_[0-9a-f]{32}$/.test(name)) { fileIo.unlinkSync(path); return undefined; }
    if (!/^thumb_[0-9a-f]{32}$/.test(name)) { return undefined; }
    const st = await fileIo.stat(path);
    if (!diskSnapshotCurrent(dir, revision)) { return undefined; }
    // 删除前无await：扫描期间发生的清空/新写入不能被旧快照误删。
    if (st.size <= 0 || st.size > DISK_FILE_MAX) { fileIo.unlinkSync(path); return undefined; }
    return { name: name, size: st.size, usedAt: st.mtime };
  } catch (_) { return undefined; }
}

/** 升级清理旧格式；官方异步元信息每批最多8项，不阻塞UI线程全盘扫描。 */
async function trimDisk(dir: string, revision: number): Promise<void> {
  const started: number = Date.now();
  const names: string[] = await fileIo.listFile(dir);
  const entries: DiskEntry[] = [];
  let total: number = 0;
  for (let i = 0; i < names.length; i += TRIM_BATCH) {
    if (!diskSnapshotCurrent(dir, revision)) { return; }
    const batch: Array<DiskEntry | undefined> = await Promise.all(names.slice(i, i + TRIM_BATCH)
      .map((name: string): Promise<DiskEntry | undefined> => scanDiskEntry(dir, name, revision)));
    for (let j = 0; j < batch.length; j++) {
      const entry: DiskEntry | undefined = batch[j];
      if (entry !== undefined) { entries.push(entry); total += entry.size; }
    }
    // 一批全为无需stat的旧格式时也让出事件循环，避免迁移形成连续长任务。
    if (i + TRIM_BATCH < names.length) { await new Promise<void>((resolve): void => { setTimeout(resolve, 0); }); }
  }
  if (!diskSnapshotCurrent(dir, revision)) { return; }
  if (total > diskLimitBytes) {
    entries.sort((a: DiskEntry, b: DiskEntry): number => a.usedAt - b.usedAt);
    for (let i = 0; i < entries.length && total > diskLimitBytes; i++) {
      try {
        const entry: DiskEntry = entries[i];
        const path: string = dir + '/' + entry.name;
        const st = await fileIo.stat(path);
        if (!diskSnapshotCurrent(dir, revision)) { return; }
        if (st.mtime > entry.usedAt || st.size !== entry.size) { trimRequested = true; continue; }
        fileIo.unlinkSync(path); total -= entry.size;
      } catch (_) { /* 保留未能删除的条目占用，不能假报已释放。 */ }
    }
  }
  if (diskSnapshotCurrent(dir, revision)) {
    diskBytes = total;
    console.info('[ImgLoader] async trim files=' + names.length.toString() +
      ' elapsedMs=' + (Date.now() - started).toString());
  }
}

/** 磁盘缓存占用（字节；供设置页「清除图片缓存」展示） */
export function imageCacheSize(): number {
  try {
    const names: string[] = fileIo.listFileSync(cacheDir);
    let total: number = 0;
    for (let i = 0; i < names.length; i++) {
      try {
        total += fileIo.statSync(cacheDir + '/' + names[i]).size;
      } catch (e) {
        // 单个文件异常跳过
      }
    }
    return total;
  } catch (e) {
    return 0;
  }
}

/** 清空图片缓存（内存 LRU 引用 + 磁盘文件），返回清理前的字节数 */
export function clearImageCache(): number {
  const before: number = imageCacheSize();
  trimImageMemory();
  diskRevision++;
  diskBytes = 0;
  try {
    const names: string[] = fileIo.listFileSync(cacheDir);
    for (let i = 0; i < names.length; i++) {
      try {
        fileIo.unlinkSync(cacheDir + '/' + names[i]);
      } catch (e) {
        // 忽略单文件失败
      }
    }
  } catch (e) {
    console.warn('[ImgLoader] clear 异常: ' + JSON.stringify(e));
  }
  console.info('[ImgLoader] 已清空图片缓存（' + before + ' bytes）');
  return before;
}

/** 内存告警仅清可重建引用，不删磁盘，不release页面仍在使用的共享PixelMap。 */
export function trimImageMemory(): void {
  cacheGeneration++;
  memCache.clear();
  memOrder.length = 0;
  bigCache.clear();
  bigOrder.length = 0;
  memSizes.clear(); bigSizes.clear();
  memBytes = 0; bigBytes = 0;
}

/** 设置磁盘缓存上限（MB）；传 0 表示用默认 1GB */
export function setDiskLimitMB(mb: number): void {
  const next: number = mb > 0 ? mb * 1024 * 1024 : 1024 * 1024 * 1024;
  if (diskLimitBytes === next) { return; }
  diskLimitBytes = next;
  scheduleDiskTrim();
}

/** 当前磁盘缓存上限（MB，便于设置页回显） */
export function diskLimitMB(): number {
  return Math.round(diskLimitBytes / (1024 * 1024));
}

function memGet(url: string): image.PixelMap | undefined {
  const big = bigCache.get(url);
  if (big !== undefined) {
    return big;
  }
  const v = memCache.get(url);
  if (v !== undefined) {
    const idx = memOrder.indexOf(url);
    if (idx >= 0) {
      memOrder.splice(idx, 1);
    }
    memOrder.push(url);
  }
  return v;
}

function memPut(url: string, pm: image.PixelMap, pixels: number): void {
  const bytes: number = pm.getPixelBytesNumber();
  if (bytes <= 0) { return; }
  // 大图走「大图槽」（查看器来回翻看不重复解码），不进主 LRU
  if (pixels > MEM_SKIP_PIXELS) {
    if (bytes > BIG_BYTES_MAX) { return; }
    if (bigCache.has(url)) {
      const idx = bigOrder.indexOf(url);
      if (idx >= 0) {
        bigOrder.splice(idx, 1);
      }
      bigBytes -= bigSizes.get(url) || 0;
      bigCache.delete(url); bigSizes.delete(url);
    }
    while (bigOrder.length > 0 && (bigOrder.length >= BIG_SLOTS || bigBytes + bytes > BIG_BYTES_MAX)) {
      const oldest = bigOrder.shift();
      if (oldest !== undefined) {
        bigBytes -= bigSizes.get(oldest) || 0;
        bigSizes.delete(oldest);
        bigCache.delete(oldest);
      }
    }
    bigCache.set(url, pm);
    bigSizes.set(url, bytes); bigBytes += bytes;
    bigOrder.push(url);
    return;
  }
  if (bytes > MEM_BYTES_MAX) { return; }
  if (memCache.has(url)) {
    const idx = memOrder.indexOf(url);
    if (idx >= 0) {
      memOrder.splice(idx, 1);
    }
    memBytes -= memSizes.get(url) || 0;
    memCache.delete(url); memSizes.delete(url);
  }
  while (memOrder.length > 0 && (memOrder.length >= MEM_MAX || memBytes + bytes > MEM_BYTES_MAX)) {
    // 仅从 LRU 移除引用，**不显式 release**：同一 PixelMap 可能仍被页面组件持有，
    // 释放会导致正在显示的图变空白/报错；交给 GC 在无人引用后回收
    const oldest = memOrder.shift();
    if (oldest !== undefined) {
      memBytes -= memSizes.get(oldest) || 0;
      memSizes.delete(oldest);
      memCache.delete(oldest);
    }
  }
  memCache.set(url, pm);
  memSizes.set(url, bytes); memBytes += bytes;
  memOrder.push(url);
}

/** 同步复用已经解码的图，透明转场首帧不能等待Promise微任务。 */
export function peekCachedImage(url: string, w: number, h: number, original: boolean = false): image.PixelMap | undefined {
  return memGet(imageRequestUrl(url, w, h, original) + '#' + w.toString() + 'x' + h.toString() + ':' + cacheGeneration.toString());
}

export function loadImage(src: string, w: number = 480, h: number = 270, original: boolean = false): Promise<image.PixelMap> {
  const url: string = imageRequestUrl(src, w, h, original);
  const key: string = url + '#' + w.toString() + 'x' + h.toString() + ':' + cacheGeneration.toString();
  const cached = memGet(key);
  if (cached !== undefined) {
    return Promise.resolve(cached);
  }
  const running = pending.get(key);
  if (running !== undefined) {
    return running;
  }
  // 完成/失败都必须移除 pending：否则 Promise（含 PixelMap）常驻内存，
  // 且失败的 URL 会永久返回缓存的 rejected Promise（本会话无法重试）
  const task: Promise<image.PixelMap> = loadInner(url, w, h, key, cacheGeneration,
    !original && isDiskThumbnail(url)).finally(() => {
    pending.delete(key);
  });
  pending.set(key, task);
  return task;
}

async function loadInner(url: string, w: number, h: number, key: string, generation: number,
  cacheOnDisk: boolean): Promise<image.PixelMap> {
  let data: ArrayBuffer | undefined = undefined;
  let downloaded: boolean = false;
  const fileName: string = cacheOnDisk ? cacheDir + '/thumb_' + await md5Hex(url) : '';

  // 1) 磁盘
  try {
    if (cacheOnDisk) {
      const st = await fileIo.stat(fileName);
      if (st.size > 0 && st.size <= DISK_FILE_MAX) {
        const f = await fileIo.open(fileName, fileIo.OpenMode.READ_ONLY);
        try {
          const buf = new ArrayBuffer(st.size);
          const bytes: number = await fileIo.read(f.fd, buf);
          if (bytes === st.size) { data = buf; }
        } finally {
          await fileIo.close(f);
        }
        try { fileIo.utimes(fileName, Date.now()); } catch (_) { /* 更新时间失败仍可显示已读图片。 */ }
        console.info('[ImgLoader] disk hit');
      }
    }
  } catch (e) {
    data = undefined;
  }

  // 2) 网络
  if (data === undefined) {
    const req = http.createHttp();
    try {
      const res = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': UA_PC, 'Referer': BILI_REFERER },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        connectTimeout: 15000,
        readTimeout: 20000
      });
      if (res.responseCode === 200 && typeof res.result !== 'string') {
        data = res.result as ArrayBuffer;
        downloaded = true;
        console.info('[ImgLoader] net fetch ' + (cacheOnDisk ? 'thumbnail' : 'memory only'));
      }
    } finally {
      req.destroy();
    }
    if (data === undefined) {
      throw new Error('图片下载失败');
    }
  }

  // 3) 解码（降采样；按原图比例适配到 w×h 框内，避免拉伸变形）
  const source = image.createImageSource(data);
  let tw: number = w;
  let th: number = h;
  try {
    const info: image.ImageInfo = source.getImageInfoSync();
    const iw: number = info.size.width;
    const ih: number = info.size.height;
    if (iw > 0 && ih > 0) {
      const s: number = Math.min(w / iw, h / ih, 1);
      tw = Math.max(1, Math.round(iw * s));
      th = Math.max(1, Math.round(ih * s));
    }
  } catch (e) {
    // 读取尺寸失败按原参数解码
  }
  const opts: image.DecodingOptions = {
    desiredSize: { width: tw, height: th }
  };
  try {
    const pm: image.PixelMap = await source.createPixelMap(opts);
    if (generation === cacheGeneration) {
      memPut(key, pm, tw * th);
      // 校验解码成功再落盘；原图、失败响应、大缩略图和清理前的请求均不能回填。
      if (downloaded && cacheOnDisk && data.byteLength > 0 && data.byteLength <= DISK_FILE_MAX) {
        try {
          diskRevision++;
          const oldSize: number = fileIo.accessSync(fileName) ? fileIo.statSync(fileName).size : 0;
          const f = fileIo.openSync(fileName, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          try { fileIo.writeSync(f.fd, data); } finally { fileIo.closeSync(f); }
          diskBytes += data.byteLength - oldSize;
          if (diskBytes > diskLimitBytes) { scheduleDiskTrim(); }
        } catch (e) { console.warn('[ImgLoader] 写盘失败: ' + JSON.stringify(e)); }
      }
    }
    return pm;
  } finally {
    await source.release();
  }
}
