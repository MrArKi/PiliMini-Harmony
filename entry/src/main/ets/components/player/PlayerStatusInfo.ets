import { batteryInfo, commonEventManager } from '@kit.BasicServicesKit';

/** Nara横屏控制栏的电量与时间；随控制层挂载，不引入应用侧轮询。 */
@Component
export struct PlayerStatusInfo {
  @State private batteryLevel: number = -1;
  @State private charging: boolean = false;
  @State private full: boolean = false;
  private subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;

  private readBattery(): void {
    try {
      const level: number = batteryInfo.batterySOC;
      this.batteryLevel = Number.isFinite(level) && level >= 0 && level <= 100 ? Math.round(level) : -1;
      this.charging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE;
      this.full = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (_) { this.batteryLevel = -1; }
  }

  aboutToAppear(): void {
    this.readBattery();
    try {
      const subscriber: commonEventManager.CommonEventSubscriber = commonEventManager.createSubscriberSync({
        events: [commonEventManager.Support.COMMON_EVENT_BATTERY_CHANGED]
      });
      this.subscriber = subscriber;
      commonEventManager.subscribe(subscriber, (error): void => {
        if (!error && this.subscriber === subscriber) { this.readBattery(); }
      });
    } catch (_) {}
  }

  aboutToDisappear(): void {
    const subscriber: commonEventManager.CommonEventSubscriber | undefined = this.subscriber;
    this.subscriber = undefined;
    if (subscriber !== undefined) {
      try { commonEventManager.unsubscribe(subscriber, (): void => {}); } catch (_) {}
    }
  }

  build() {
    Row({ space: 10 }) {
      if (this.batteryLevel >= 0) {
        Row({ space: 3 }) {
          if (this.charging || this.full) {
            Image(this.charging ? $r('app.media.icon_battery_charging') : $r('app.media.icon_battery_full'))
              .width(13).height(13).fillColor('#FFFFFF')
          }
          Text(this.batteryLevel.toString() + '%').fontSize(13).fontColor('#FFFFFF')
            .id('player-battery-level')
        }
      }
      TextClock().format('HH:mm').fontSize(13).fontColor('#FFFFFF').id('player-current-time')
    }.hitTestBehavior(HitTestMode.None)
  }
}
