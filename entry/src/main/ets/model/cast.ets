/** 仅本次局域网发现所得设备，地址不持久化。 */
export class DlnaDevice {
  id: string = '';
  name: string = '';
  host: string = '';
  location: string = '';
  serviceType: string = '';
  controlUrl: string = '';
  scpdUrl: string = '';
  netId: number = 0;
}

export class DlnaMedia {
  url: string = '';
  title: string = '';
  duration: number = 0;
  position: number = 0;
}

/** 投屏独立状态；本机mpv状态始终由PlayController维护。 */
export class CastSnapshot {
  devices: DlnaDevice[] = [];
  discovering: boolean = false;
  selection: boolean = false;
  /** 已暂停本机并交接过远端，失败后也须显式恢复。 */
  localHeld: boolean = false;
  phase: string = 'idle';
  remote: boolean = false;
  deviceName: string = '';
  position: number = 0;
  duration: number = 0;
  message: string = '';
  canPlay: boolean = false;
  canPause: boolean = false;
  canSeek: boolean = false;
}
