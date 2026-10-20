/**
 * 视频条目模型（列表卡片通用）
 */
export interface VideoItem {
  /** 列表 key（唯一，用于 LazyForEach） */
  key: string;
  bvid: string;
  cid: number;
  title: string;
  cover: string;
  upName: string;
  /** UP UID（首页菜单直接访问空间；旧来源可缺省） */
  upMid?: number;
  upFace: string;
  playCount: number;
  /** 弹幕数（Nara 卡片第二行展示） */
  danmaku: number;
  /** 发布时间（秒；Nara 卡片第一行 "MM-DD UP名"） */
  pubdate: number;
  /** 秒 */
  duration: number;
  /** avid（稍后再看/收藏删除等写操作用；列表页可能为 0） */
  aid?: number;
}
