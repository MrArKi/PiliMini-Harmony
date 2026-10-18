/**
 * 视频清晰度映射（Bug1 修复）
 * 完整复刻 Nara `lib/models/common/video/video_quality.dart` 的 qn → 描述表
 * 用途：accept_description 缺失时兜底、播放器清晰度标签、设置页默认清晰度选项
 */
export interface QualityEntry {
  qn: number;
  desc: string;
  shortDesc: string;
}

const QUALITY_TABLE: QualityEntry[] = [
  { qn: 129, desc: 'HDR Vivid', shortDesc: 'HDR Vivid' },
  { qn: 127, desc: '8K 超高清', shortDesc: '8K' },
  { qn: 126, desc: '杜比视界', shortDesc: '杜比' },
  { qn: 125, desc: 'HDR 真彩', shortDesc: 'HDR' },
  { qn: 120, desc: '4K 超高清', shortDesc: '4K' },
  { qn: 116, desc: '1080P 60帧', shortDesc: '1080P60' },
  { qn: 112, desc: '1080P 高码率', shortDesc: '1080P+' },
  { qn: 80, desc: '1080P 高清', shortDesc: '1080P' },
  { qn: 74, desc: '720P 60帧', shortDesc: '720P60' },
  { qn: 64, desc: '720P 准高清', shortDesc: '720P' },
  { qn: 32, desc: '480P 标清', shortDesc: '480P' },
  { qn: 16, desc: '360P 流畅', shortDesc: '360P' },
  { qn: 6, desc: '240P 极速', shortDesc: '240P' }
];

export class VideoQuality {
  /** qn → 完整描述（未知 qn 回退 "<qn>P"） */
  static label(qn: number): string {
    for (let i = 0; i < QUALITY_TABLE.length; i++) {
      if (QUALITY_TABLE[i].qn === qn) {
        return QUALITY_TABLE[i].desc;
      }
    }
    return qn.toString() + 'P';
  }

  /** qn → 短描述（控件/角标用；未知 qn 回退 "<qn>P"） */
  static shortLabel(qn: number): string {
    for (let i = 0; i < QUALITY_TABLE.length; i++) {
      if (QUALITY_TABLE[i].qn === qn) {
        return QUALITY_TABLE[i].shortDesc;
      }
    }
    return qn.toString() + 'P';
  }

  /** 全表（设置页默认清晰度选项用，高 → 低） */
  static all(): QualityEntry[] {
    return QUALITY_TABLE;
  }
}
