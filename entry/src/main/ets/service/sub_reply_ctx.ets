/**
 * 楼中楼页面入参（进程内传递；放在 service 层，避免页面模块被路由表与调用方各加载一份导致静态值不同步）
 */
import { CommentItem } from './video_service';

export class SubReplyArgs {
  static root: CommentItem | undefined = undefined;
  static upMid: number = 0;
  static total: number = 0;
  /** 视频楼中楼：aid > 0（评论 type=1） */
  static aid: number = 0;
  /** 动态楼中楼：oid + otype（type=17 等） */
  static oid: string = '';
  static otype: number = 1;
  static targetRpid: number = 0;

  static set(root: CommentItem, upMid: number, aid: number, oid: string, otype: number, targetRpid: number = 0): void {
    SubReplyArgs.root = root;
    SubReplyArgs.upMid = upMid;
    SubReplyArgs.total = root.rcount;
    SubReplyArgs.aid = aid;
    SubReplyArgs.oid = oid;
    SubReplyArgs.otype = otype;
    SubReplyArgs.targetRpid = targetRpid;
  }

  /** 消费方在 aboutToAppear 快照后立即清空（风险5：返回动画期间读到 undefined） */
  static clear(): void {
    SubReplyArgs.root = undefined;
    SubReplyArgs.upMid = 0;
    SubReplyArgs.total = 0;
    SubReplyArgs.aid = 0;
    SubReplyArgs.oid = '';
    SubReplyArgs.otype = 1;
    SubReplyArgs.targetRpid = 0;
  }
}
