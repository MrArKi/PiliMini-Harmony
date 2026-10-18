import { router } from '@kit.ArkUI';

/** 空间入口统一传mid；同一UP不重复压栈。 */
export function openMember(mid: number): void {
  if (!Number.isFinite(mid) || mid <= 0) { return; }
  if (router.getState().path === 'pages/member/MemberPage') {
    const params = router.getParams() as Record<string, string>;
    if (params['mid'] === mid.toString()) { return; }
  }
  router.pushUrl({ url: 'pages/member/MemberPage', params: { 'mid': mid.toString() } });
}
