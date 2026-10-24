/** 我的关注模型（spec-28）；账号快照只在请求期间持有。 */
export interface FollowSession {
  cookie: string;
  csrf: string;
  account: string;
  revision: number;
}

export interface FollowItem {
  mid: number;
  name: string;
  face: string;
  sign: string;
  attribute: number;
  officialType: number;
  officialDesc: string;
}

export interface FollowGroup {
  tagid: number;
  name: string;
  count: number;
  tip: string;
  /** 系统分组和未知负ID保守只读。 */
  custom: boolean;
}

export interface FollowPage {
  items: FollowItem[];
  page: number;
  nextPage: number;
  /** -1表示接口未提供总数，不能据此声称取全。 */
  total: number;
  hasMore: boolean;
}
