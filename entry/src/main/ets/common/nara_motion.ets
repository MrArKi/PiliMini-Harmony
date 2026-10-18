/** Nara锁定GetX f727afba：默认Cupertino、300ms，底页1/3视差。 */
export const NARA_ROUTE_DURATION: number = 300;
export const NARA_ROUTE_CURVE: string = 'cubic-bezier(0.35,0.91,0.33,0.97)';
/** Flutter Bouncing的0.135^t → ArkUI FrictionMotion指数系数，映射见本地滚动复验报告。 */
export const NARA_SCROLL_FRICTION: number = -Math.log(0.135) / 4.2;
