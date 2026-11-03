/** 进程内启动阶段计时；系统拉起到模块加载前的时间由设备日志测量。 */
const loadedAt: number = Date.now();

export function markStartup(stage: string): void {
  console.info('[Startup] stage=' + stage + ' elapsedMs=' + (Date.now() - loadedAt).toString());
}
