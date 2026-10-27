import { router, promptAction } from '@kit.ArkUI';
import { CommentItem, VideoService } from '../service/video_service';

/** 空间入口统一传mid；同一UP不重复压栈。 */
export function openMember(mid: number): void {
  if (!Number.isFinite(mid) || mid <= 0) { return; }
  if (router.getState().path === 'pages/member/MemberPage') {
    const params = router.getParams() as Record<string, string>;
    if (params['mid'] === mid.toString()) { return; }
  }
  router.pushUrl({ url: 'pages/member/MemberPage', params: { 'mid': mid.toString() } });
}

/**
 * 评论里的 @昵称：先在当前评论树内按同名命中取mid，命中不到再走用户搜索。
 * 两者都失败只提示，不打开空空间或错误页。
 */
export function openMention(name: string, candidates: CommentItem[]): void {
  const key: string = name.trim();
  if (key.length === 0) { return; }
  for (let i: number = 0; i < candidates.length; i++) {
    if (candidates[i].mid > 0 && candidates[i].uname === key) { openMember(candidates[i].mid); return; }
  }
  VideoService.searchUserByName(key).then((mid: number): void => {
    if (mid > 0) { openMember(mid); } else { promptAction.showToast({ message: '未找到 @' + key }); }
  }).catch((): void => { promptAction.showToast({ message: '未找到 @' + key }); });
}
