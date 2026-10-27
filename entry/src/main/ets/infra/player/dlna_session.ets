import { CastSnapshot, DlnaDevice, DlnaMedia } from '../../model/cast';
import { DlnaHttp, DlnaRequestError } from './dlna_http';
import { DlnaXml, DlnaXmlNode } from './dlna_xml';

/** 单设备AVTransport控制点；SOAP严格串行，退页Stop排在已发出的Play之后。 */
export class DlnaCastSession {
  private static pendingStops: DlnaCastSession[] = [];
  private static stopDrain: Promise<boolean> | undefined = undefined;
  readonly snapshot: CastSnapshot = new CastSnapshot();
  private valid: () => boolean;
  private handoff: () => number;
  private changed: (snapshot: CastSnapshot) => void;
  private http: DlnaHttp = new DlnaHttp();
  private device: DlnaDevice | undefined = undefined;
  private queue: Promise<void> = Promise.resolve();
  private closing: Promise<void> | undefined = undefined;
  private active: boolean = false;
  private generation: number = 0;
  private touched: boolean = false;
  private confirmedStopped: boolean = true;
  private playPending: boolean = false;
  private commandPending: boolean = false;
  private reading: boolean = false;
  private timer: number = -1;
  private panelVisible: boolean = false;
  private background: boolean = false;
  private failures: number = 0;
  private started: boolean = false;
  private awaitingPlaying: boolean = false;
  private connectDeadline: number = 0;
  private initialPosition: number = 0;
  private initialSeekDone: boolean = false;
  private capabilitiesReady: boolean = false;
  private declaredKnown: boolean = false;
  private declared: string[] = [];
  private currentActionsKnown: boolean = false;
  private currentActions: string[] = [];
  private rejected: string[] = [];
  private actionsReadable: boolean = true;
  private positionReadable: boolean = true;
  private relativeTimeSeek: boolean = true;

  constructor(valid: () => boolean, handoff: () => number, changed: (snapshot: CastSnapshot) => void) {
    this.valid = valid; this.handoff = handoff; this.changed = changed;
  }

  private current(generation: number): boolean {
    if (!this.active || generation !== this.generation) { return false; }
    if (!this.valid()) { this.terminate('disconnected', '', false); return false; }
    return true;
  }

  private emit(): void { if (this.valid()) { this.changed(this.snapshot); } }

  private enqueue(work: () => Promise<void>): Promise<void> {
    const next: Promise<void> = this.queue.then(work);
    this.queue = next.catch((): void => {});
    return next;
  }

  async connect(device: DlnaDevice, media: DlnaMedia): Promise<void> {
    if (this.device !== undefined) { throw new Error('请重新选择投屏设备'); }
    if (!this.valid()) { return; }
    if (DlnaCastSession.pendingStops.length > 0 && !await DlnaCastSession.drainStops()) {
      this.snapshot.phase = 'error'; this.snapshot.message = '尚未确认电视停止，请重试断开'; this.emit(); return;
    }
    if (!this.valid()) { return; }
    this.device = device; this.active = true;
    const generation: number = ++this.generation;
    this.snapshot.phase = 'connecting'; this.snapshot.deviceName = device.name;
    this.snapshot.duration = media.duration; this.snapshot.position = media.position;
    this.snapshot.message = '正在连接…'; this.snapshot.remote = false;
    this.emit();
    await this.enqueue(async (): Promise<void> => {
      try {
        if (!this.current(generation)) { return; }
        // 接收端空闲时Stop可拒绝，不把它作为设置新URI的前置成功条件。
        try { await this.soap('Stop'); } catch (_) {}
        if (!this.current(generation)) { return; }
        if (DlnaCastSession.pendingStops.length >= 4) { throw new Error('请先断开其他投屏设备'); }
        this.touched = true; this.confirmedStopped = false;
        await this.soap('SetAVTransportURI', '<CurrentURI>' + DlnaXml.escape(media.url) + '</CurrentURI>' +
          '<CurrentURIMetaData>' + DlnaXml.escape(this.metadata(media)) + '</CurrentURIMetaData>');
        if (!this.current(generation)) { return; }
        // URI已由接收端接受后才暂停本机；取源、发现、选设备均不提前暂停。
        const position: number = this.handoff();
        this.initialPosition = this.clamp(Number.isFinite(position) ? position : media.position);
        this.snapshot.position = this.initialPosition;
        this.snapshot.remote = true; this.snapshot.localHeld = true;
        this.snapshot.message = ''; this.emit();
        if (!this.current(generation)) { return; }
        this.connectDeadline = Date.now() + 20000;
        await this.playRequest();
        if (!this.current(generation)) { return; }
        await this.readTransport(generation);
        if (!this.current(generation)) { return; }
        await this.readCapabilities(generation);
        if (!this.current(generation)) { return; }
        await this.readActions(generation);
        if (!this.current(generation)) { return; }
        this.capabilitiesReady = true;
        this.capabilities();
        await this.resumeInitial(generation);
        if (!this.current(generation)) { return; }
        this.emit(); this.schedule();
      } catch (_) {
        if (this.current(generation)) { this.terminate('error', '投屏起播失败，请检查设备和网络后重试'); }
      }
    });
  }

  /** 每个请求均由独立LAN HTTP完成完整超时；不携带Web认证或媒体地址日志。 */
  private soap(action: string, argumentsXml: string = ''): Promise<string> {
    const device: DlnaDevice | undefined = this.device;
    if (device === undefined) { return Promise.reject(new Error('尚未选择投屏设备')); }
    const body: string = '<?xml version="1.0" encoding="utf-8"?>' +
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' +
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:' + action +
      ' xmlns:u="' + DlnaXml.escape(device.serviceType) + '"><InstanceID>0</InstanceID>' + argumentsXml +
      '</u:' + action + '></s:Body></s:Envelope>';
    return this.http.request(device.controlUrl, body, device.serviceType + '#' + action, device.netId);
  }

  private metadata(media: DlnaMedia): string {
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">' +
      '<item id="0" parentID="-1" restricted="1"><dc:title>' + DlnaXml.escape(media.title) +
      '</dc:title><upnp:class>object.item.videoItem</upnp:class>' +
      '<res protocolInfo="http-get:*:video/mp4:*" duration="' + this.time(media.duration) + '">' +
      DlnaXml.escape(media.url) + '</res></item></DIDL-Lite>';
  }

  private async playRequest(): Promise<void> {
    this.confirmedStopped = false; this.playPending = true; this.awaitingPlaying = true;
    try { await this.soap('Play', '<Speed>1</Speed>'); }
    finally { this.playPending = false; }
  }

  /** 旧页面停止超时后的有限补偿；只由下一次明确的投屏/播放动作调用。 */
  static drainStops(): Promise<boolean> {
    if (DlnaCastSession.stopDrain !== undefined) { return DlnaCastSession.stopDrain; }
    const work: Promise<boolean> = DlnaCastSession.drainPendingStops();
    DlnaCastSession.stopDrain = work.finally((): void => { DlnaCastSession.stopDrain = undefined; });
    return DlnaCastSession.stopDrain;
  }

  private static async drainPendingStops(): Promise<boolean> {
    const pending: DlnaCastSession[] = DlnaCastSession.pendingStops.slice(0, 4);
    for (let i: number = 0; i < pending.length; i++) { await pending[i].retryPendingStop(); }
    return DlnaCastSession.pendingStops.length === 0;
  }

  private registerPendingStop(): void {
    if (this.confirmedStopped || !this.touched) { return; }
    if (DlnaCastSession.pendingStops.indexOf(this) >= 0) { return; }
    if (DlnaCastSession.pendingStops.length >= 4) { return; }
    DlnaCastSession.pendingStops.push(this);
  }

  private removePendingStop(): void {
    const index: number = DlnaCastSession.pendingStops.indexOf(this);
    if (index >= 0) { DlnaCastSession.pendingStops.splice(index, 1); }
  }

  private async retryPendingStop(): Promise<void> {
    if (this.confirmedStopped) { this.removePendingStop(); return; }
    if (this.playPending || this.commandPending || this.active) { return; }
    if (this.closing !== undefined) { await this.closing; }
    if (this.confirmedStopped || this.playPending || this.commandPending || this.active) { return; }
    await this.enqueue(async (): Promise<void> => {
      if (this.confirmedStopped || this.playPending || this.commandPending || this.active) { return; }
      try { await this.soap('Stop'); this.confirmedStopped = true; this.removePendingStop(); }
      catch (_) { this.registerPendingStop(); }
    });
    if (this.confirmedStopped) { this.http.close(); }
  }

  command(command: 'play' | 'pause' | 'seek', parameter?: number): void {
    const generation: number = this.generation;
    if (!this.current(generation) || !this.snapshot.remote) { return; }
    if (this.commandPending || !this.capabilitiesReady || !this.started) {
      this.snapshot.message = '投屏正在准备，请稍候'; this.emit(); return;
    }
    const supported: boolean = command === 'play' ? this.snapshot.canPlay :
      (command === 'pause' ? this.snapshot.canPause : this.snapshot.canSeek);
    if (!supported) { this.snapshot.message = '接收设备暂不支持该操作'; this.emit(); return; }
    if (command === 'seek' && (parameter === undefined || !Number.isFinite(parameter))) { return; }
    this.commandPending = true; this.clearTimer();
    this.enqueue(async (): Promise<void> => {
      try {
        if (!this.current(generation)) { return; }
        const action: string = command === 'play' ? 'Play' : (command === 'pause' ? 'Pause' : 'Seek');
        try {
          if (command === 'play') {
            this.connectDeadline = Date.now() + 20000;
            await this.playRequest();
          } else if (command === 'pause') { await this.soap('Pause'); }
          else { await this.seekRequest(parameter as number); }
          if (!this.current(generation)) { return; }
          this.snapshot.message = ''; this.failures = 0;
        } catch (error) {
          if (!this.current(generation)) { return; }
          this.rejectAction(action, error as Error);
          this.snapshot.message = command === 'seek' ? '接收设备未能定位，请重试' : '投屏控制失败，请重试';
        }
        if (!this.current(generation)) { return; }
        await this.readStatus(generation);
      } finally {
        this.commandPending = false;
        if (this.current(generation)) { this.capabilities(); this.emit(); this.schedule(); }
      }
    }).catch((): void => {
      if (this.current(generation)) { this.failedRead(); }
    });
  }

  private async readCapabilities(generation: number): Promise<void> {
    const device: DlnaDevice | undefined = this.device;
    if (device === undefined || device.scpdUrl.length === 0) { return; }
    try {
      const xml: string = await this.http.request(device.scpdUrl, '', '', device.netId);
      if (!this.current(generation)) { return; }
      const root: DlnaXmlNode = DlnaXml.parse(xml);
      const actions: DlnaXmlNode | undefined = root.first('actionList');
      if (actions !== undefined) {
        this.declared = [];
        const list: DlnaXmlNode[] = actions.all('action');
        for (let i: number = 0; i < list.length; i++) {
          const name: DlnaXmlNode | undefined = list[i].child('name');
          if (name !== undefined && name.text.length > 0) { this.declared.push(name.text); }
        }
        this.declaredKnown = this.declared.length > 0;
      }
      const variables: DlnaXmlNode[] = root.all('stateVariable');
      for (let i: number = 0; i < variables.length; i++) {
        const name: DlnaXmlNode | undefined = variables[i].child('name');
        if (name !== undefined && name.text === 'A_ARG_TYPE_SeekMode') {
          const allowed: DlnaXmlNode[] = variables[i].all('allowedValue');
          if (allowed.length > 0) {
            this.relativeTimeSeek = false;
            for (let j: number = 0; j < allowed.length; j++) {
              if (allowed[j].text === 'REL_TIME') { this.relativeTimeSeek = true; }
            }
          }
        }
      }
    } catch (_) { /* 描述能力可选；继续以当前动作列表与SOAP拒绝判断。 */ }
  }

  private async readActions(generation: number): Promise<void> {
    if (!this.actionsReadable || (this.declaredKnown && this.declared.indexOf('GetCurrentTransportActions') < 0)) { return; }
    try {
      const xml: string = await this.soap('GetCurrentTransportActions');
      if (!this.current(generation)) { return; }
      const actions: string = DlnaXml.value(xml, 'Actions');
      this.currentActions = actions.split(',').map((value: string): string => value.trim());
      this.currentActionsKnown = true;
    } catch (error) {
      if (!this.current(generation)) { return; }
      const code: number = this.errorCode(error as Error);
      if (code === 401 || code === 602) { this.actionsReadable = false; this.currentActionsKnown = false; }
    }
    this.capabilities();
  }

  private supports(action: string): boolean {
    if (this.rejected.indexOf(action) >= 0) { return false; }
    if (this.currentActionsKnown) { return this.currentActions.indexOf(action) >= 0; }
    if (this.declaredKnown) { return this.declared.indexOf(action) >= 0; }
    return action === 'Play'; // Play已实际成功，其余未声明能力不预先承诺。
  }

  private capabilities(): void {
    const ready: boolean = this.active && this.snapshot.remote && this.started && this.capabilitiesReady;
    this.snapshot.canPlay = ready && this.supports('Play');
    this.snapshot.canPause = ready && this.supports('Pause');
    this.snapshot.canSeek = ready && this.relativeTimeSeek && this.supports('Seek');
  }

  private rejectAction(action: string, error: Error): void {
    const code: number = this.errorCode(error);
    if (code === 401 || code === 602 || (action === 'Seek' && code === 710)) {
      if (this.rejected.indexOf(action) < 0) { this.rejected.push(action); }
    }
    this.capabilities();
  }

  private errorCode(error: Error): number { return error instanceof DlnaRequestError ? error.code : 0; }

  private async seekRequest(position: number): Promise<void> {
    await this.soap('Seek', '<Unit>REL_TIME</Unit><Target>' + this.time(this.clamp(position)) + '</Target>');
  }

  private async resumeInitial(generation: number): Promise<void> {
    if (!this.started || !this.capabilitiesReady || this.initialSeekDone) { return; }
    this.initialSeekDone = true;
    if (this.initialPosition < 1000) { return; }
    if (!this.snapshot.canSeek) { this.snapshot.message = '设备暂不支持定位，已从头播放'; return; }
    try {
      await this.seekRequest(this.initialPosition);
      if (!this.current(generation)) { return; }
      await this.readPosition(generation);
    } catch (error) {
      if (!this.current(generation)) { return; }
      this.rejectAction('Seek', error as Error);
      this.snapshot.message = '设备未能恢复原进度，已继续播放';
    }
  }

  private async readTransport(generation: number): Promise<void> {
    const xml: string = await this.soap('GetTransportInfo');
    if (!this.current(generation)) { return; }
    const transport: string = DlnaXml.value(xml, 'CurrentTransportState').trim().toUpperCase();
    const status: string = DlnaXml.value(xml, 'CurrentTransportStatus').trim().toUpperCase();
    if (status === 'ERROR_OCCURRED') { throw new Error('接收设备播放失败'); }
    if (transport === 'PLAYING' || transport === 'RECORDING') {
      this.snapshot.phase = 'playing'; this.started = true; this.confirmedStopped = false;
      this.connectDeadline = 0; this.awaitingPlaying = false;
    } else if (transport === 'PAUSED_PLAYBACK' || transport === 'PAUSED_RECORDING') {
      this.snapshot.phase = this.started ? 'paused' : 'connecting';
    } else if (transport === 'STOPPED' || transport === 'NO_MEDIA_PRESENT') {
      if (!this.awaitingPlaying) { this.confirmedStopped = true; }
      this.snapshot.phase = this.started && !this.awaitingPlaying ? 'ended' : 'connecting';
    } else if (transport === 'TRANSITIONING') { this.snapshot.phase = 'connecting'; }
    else { throw new Error('接收设备未返回有效播放状态'); }
    if (this.snapshot.phase === 'connecting' && this.connectDeadline > 0 && Date.now() > this.connectDeadline) {
      throw new Error('接收设备起播超时');
    }
    if (this.snapshot.phase !== 'playing' && this.snapshot.phase !== 'connecting') { this.clearTimer(); }
    this.failures = 0; this.capabilities(); this.emit();
  }

  private async readPosition(generation: number): Promise<void> {
    if (!this.positionReadable) { return; }
    try {
      const xml: string = await this.soap('GetPositionInfo');
      if (!this.current(generation)) { return; }
      const position: number = this.parseTime(DlnaXml.value(xml, 'RelTime'));
      const duration: number = this.parseTime(DlnaXml.value(xml, 'TrackDuration'));
      if (duration > 0) { this.snapshot.duration = duration; }
      if (position >= 0) { this.snapshot.position = Math.max(0, this.snapshot.duration > 0 ?
        Math.min(position, this.snapshot.duration) : position); }
    } catch (error) {
      if (!this.current(generation)) { return; }
      const code: number = this.errorCode(error as Error);
      if (code === 401 || code === 602) { this.positionReadable = false; }
    }
  }

  /** 断开/续播前补读一次远端进度；不支持或读取失败返回-1，旧快照保持不变。 */
  async syncPosition(): Promise<number> {
    if (!this.active || !this.snapshot.remote || !this.positionReadable) { return -1; }
    const generation: number = this.generation;
    await this.enqueue(async (): Promise<void> => {
      if (!this.current(generation)) { return; }
      await this.readPosition(generation);
    });
    return this.snapshot.position;
  }

  private async readStatus(generation: number): Promise<void> {    await this.readTransport(generation);
    if (!this.current(generation)) { return; }
    await this.readPosition(generation);
    if (!this.current(generation)) { return; }
    await this.readActions(generation);
    if (!this.current(generation)) { return; }
    await this.resumeInitial(generation);
    if (this.current(generation)) { this.capabilities(); this.emit(); }
  }

  private requestRead(): void {
    const generation: number = this.generation;
    if (this.reading || this.commandPending || !this.snapshot.remote || !this.current(generation)) { return; }
    this.reading = true; this.clearTimer();
    this.enqueue(async (): Promise<void> => {
      if (!this.current(generation)) { return; }
      try { await this.readStatus(generation); }
      catch (_) { if (this.current(generation)) { this.failedRead(); } }
    }).finally((): void => {
      this.reading = false;
      if (this.current(generation)) { this.schedule(); }
    }).catch((): void => {});
  }

  private failedRead(): void {
    this.failures++;
    if (this.snapshot.phase === 'connecting' && this.connectDeadline > 0 && Date.now() > this.connectDeadline) {
      this.terminate('error', '投屏起播超时，请检查设备和网络后重试'); return;
    }
    if (this.failures >= 3) { this.terminate('error', '无法连接投屏设备，请检查网络后重试'); return; }
    this.snapshot.message = '暂时无法读取设备状态，正在重试'; this.emit(); this.schedule();
  }

  setPanelVisible(visible: boolean): void {
    const opened: boolean = visible && !this.panelVisible;
    this.panelVisible = visible; this.clearTimer();
    if (opened && this.snapshot.remote) { this.requestRead(); }
    else { this.schedule(); }
  }

  setBackground(background: boolean): void {
    this.background = background; this.clearTimer(); this.schedule();
  }

  private schedule(): void {
    if (this.timer !== -1 || this.reading || this.commandPending || !this.active || !this.snapshot.remote ||
      (this.snapshot.phase !== 'playing' && this.snapshot.phase !== 'connecting')) { return; }
    const generation: number = this.generation;
    this.timer = setTimeout((): void => {
      this.timer = -1;
      if (this.current(generation)) { this.requestRead(); }
    }, this.background ? 15000 : (this.panelVisible ? 2000 : 5000));
  }

  private clearTimer(): void { if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; } }

  private terminate(phase: string, message: string, notify: boolean = true): void {
    this.active = false; this.generation++; this.clearTimer();
    this.snapshot.phase = phase; this.snapshot.message = message; this.snapshot.remote = false;
    this.capabilities(); if (notify) { this.emit(); }
    this.detachCallbacks();
    this.cleanup();
  }

  /** 停止重试只需设备/HTTP，不能由有限registry继续保留旧页面与历史对象。 */
  private detachCallbacks(): void {
    this.valid = (): boolean => false;
    this.handoff = (): number => 0;
    this.changed = (_: CastSnapshot): void => {};
  }

  /** HTTP完整结束后再发Stop；超时不能伪造停止成功，失败引用保留供用户重试。 */
  disconnect(): Promise<void> {
    if (this.active) {
      this.active = false; this.generation++; this.clearTimer();
      this.snapshot.remote = false; this.snapshot.phase = 'disconnected'; this.snapshot.message = '投屏已断开';
      this.capabilities();
    }
    this.detachCallbacks();
    return this.cleanup();
  }

  private cleanup(): Promise<void> {
    if (this.closing !== undefined) { return this.closing; }
    this.registerPendingStop();
    const work: Promise<void> = this.enqueue(async (): Promise<void> => {
      if (!this.touched) { this.confirmedStopped = true; this.http.close(); return; }
      if (!this.confirmedStopped) {
        try { await this.soap('Stop'); this.confirmedStopped = true; }
        catch (_) { /* 保留设备和HTTP对象，下一次显式断开可安全重试。 */ }
      }
      if (this.confirmedStopped) { this.removePendingStop(); this.http.close(); }
      else { this.registerPendingStop(); }
    });
    this.closing = work.finally((): void => { this.closing = undefined; });
    return this.closing;
  }

  stopped(): boolean { return this.confirmedStopped && !this.playPending; }

  private clamp(position: number): number {
    return Math.max(0, this.snapshot.duration > 0 ? Math.min(position, Math.max(0, this.snapshot.duration - 1000)) : position);
  }

  private time(ms: number): string {
    const total: number = Math.floor(Math.max(0, Number.isFinite(ms) ? ms : 0) / 1000);
    const hours: string = Math.floor(total / 3600).toString();
    const minutes: string = Math.floor(total % 3600 / 60).toString();
    const seconds: string = (total % 60).toString();
    return (hours.length < 2 ? '0' : '') + hours + ':' + (minutes.length < 2 ? '0' : '') + minutes +
      ':' + (seconds.length < 2 ? '0' : '') + seconds;
  }

  private parseTime(value: string): number {
    const parts: string[] = value.trim().split(':');
    if (parts.length !== 3 || !/^\d+$/.test(parts[0]) || !/^\d{1,2}$/.test(parts[1]) ||
      !/^\d{1,2}(?:\.\d+)?$/.test(parts[2])) { return -1; }
    const hours: number = Number(parts[0]), minutes: number = Number(parts[1]), seconds: number = Number(parts[2]);
    if (!Number.isFinite(hours) || minutes >= 60 || seconds >= 60) { return -1; }
    return (hours * 3600 + minutes * 60 + seconds) * 1000;
  }
}
