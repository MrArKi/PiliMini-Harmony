/** 同一会话的并发nav只请求一次；仅保留在途响应，不缓存账号资料。 */
import { API_BASE } from '../../config/constants';
import { CookieStore } from '../cookie/cookie_store';
import { getJson } from './http';

let pendingNav: Promise<string> | undefined = undefined;
let pendingRevision: number = -1;

export function requestNav(): Promise<string> {
  const revision: number = CookieStore.sessionRevision();
  if (pendingNav !== undefined && pendingRevision === revision) { return pendingNav; }
  const operation: Promise<string> = getJson(API_BASE + '/x/web-interface/nav').finally((): void => {
    if (pendingNav === operation) { pendingNav = undefined; }
  });
  pendingRevision = revision;
  pendingNav = operation;
  return operation;
}
