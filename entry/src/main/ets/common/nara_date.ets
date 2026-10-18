/** 与Nara DateFormatUtils.dateFormat的默认时间文案一致。 */
export function naraDate(timestamp: number): string {
  if (timestamp <= 0) { return ''; }
  const now: Date = new Date();
  const date: Date = new Date(timestamp * 1000);
  const minutes: number = Math.floor((now.getTime() - date.getTime()) / 60000);
  if (minutes < 1) { return '刚刚'; }
  if (minutes < 60) { return minutes.toString() + '分钟前'; }
  const hours: number = Math.floor(minutes / 60);
  if (hours < 24) { return hours.toString() + '小时前'; }
  const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const day: Date = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const days: number = Math.round((today.getTime() - day.getTime()) / 86400000);
  if (days === 1) { return '昨天 ' + two(date.getHours()) + ':' + two(date.getMinutes()); }
  if (days < 4) { return days.toString() + '天前'; }
  return (now.getFullYear() === date.getFullYear() ? '' : date.getFullYear().toString() + '-')
    + two(date.getMonth() + 1) + '-' + two(date.getDate());
}
function two(n: number): string { return n < 10 ? '0' + n.toString() : n.toString(); }
