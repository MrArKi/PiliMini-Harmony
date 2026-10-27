import { connection, socket } from '@kit.NetworkKit';
import { util, url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DlnaDevice } from '../../model/cast';
import { DlnaHttp } from './dlna_http';
import { DlnaXml, DlnaXmlNode } from './dlna_xml';

const SSDP_IP: string = '239.255.255.250';
const SEARCH_TARGETS: string[] = ['ssdp:all', 'urn:schemas-upnp-org:device:MediaRenderer:1',
  'urn:schemas-upnp-org:service:AVTransport:1'];

class DescriptionCandidate {
  location: string = '';
  host: string = '';
  netId: number = 0;
}

class SearchLane {
  socket: socket.UDPSocket;
  net: connection.NetHandle;
  address: string;
  constructor(client: socket.UDPSocket, net: connection.NetHandle, address: string) {
    this.socket = client; this.net = net; this.address = address;
  }
}

/** 仅面板请求时启动，20秒后关闭全部UDP与描述请求。 */
export class DlnaDiscovery {
  private onUpdate: (devices: DlnaDevice[], discovering: boolean, message: string) => void;
  private generation: number = 0;
  private active: boolean = false;
  private devices: DlnaDevice[] = [];
  private lanes: SearchLane[] = [];
  private servers: socket.MulticastSocket[] = [];
  private timers: number[] = [];
  private http: DlnaHttp = new DlnaHttp();
  private candidates: DescriptionCandidate[] = [];
  private seen: Set<string> = new Set<string>();
  private pending: number = 0;
  private replies: number = 0;
  private sendFailures: number = 0;
  private descriptionFailures: number = 0;
  private lastFailureStage: number = 0;
  private lastFailureCode: number = 0;

  constructor(onUpdate: (devices: DlnaDevice[], discovering: boolean, message: string) => void) {
    this.onUpdate = onUpdate;
  }

  private current(generation: number): boolean { return this.active && generation === this.generation; }
  private emit(message: string = ''): void { this.onUpdate(this.devices.slice(), this.active, message); }

  async start(): Promise<void> {
    this.stop();
    const generation: number = ++this.generation;
    this.active = true; this.devices = []; this.seen.clear(); this.candidates = []; this.pending = 0;
    this.replies = 0; this.sendFailures = 0; this.descriptionFailures = 0;
    this.lastFailureStage = 0; this.lastFailureCode = 0;
    this.http = new DlnaHttp(); this.emit();
    this.timers.push(setTimeout((): void => { if (this.current(generation)) { this.stop(); } }, 20000));
    try {
      const nets: connection.NetHandle[] = await connection.getAllNets();
      for (let i: number = 0; i < Math.min(nets.length, 16); i++) {
        if (!this.current(generation)) { return; }
        try {
          const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(nets[i]);
          if (!this.current(generation)) { return; }
          if (capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) < 0 &&
            capabilities.bearerTypes.indexOf(connection.NetBearType.BEARER_ETHERNET) < 0) { continue; }
          const properties: connection.ConnectionProperties = await connection.getConnectionProperties(nets[i]);
          if (!this.current(generation)) { return; }
          for (let j: number = 0; j < properties.linkAddresses.length && this.lanes.length < 8; j++) {
            const address: string = properties.linkAddresses[j].address.address;
            if (!DlnaDiscovery.ipv4(address) || /^127\.|^0\./.test(address)) { continue; }
            if (this.lanes.some((lane: SearchLane): boolean => lane.address === address)) { continue; }
            await this.addLane(nets[i], address, generation);
            if (!this.current(generation)) { return; }
          }
          // NOTIFY为兼容路径，1900端口被其它播放器占用不影响主动M-SEARCH。
          this.addNotify(nets[i], generation).catch((): void => {});
        } catch (error) { this.failure(2, error as BusinessError); }
      }
      if (!this.current(generation)) { return; }
      if (this.lanes.length === 0) {
        this.stop(); this.emit('请连接与电视相同的无线网络后重试'); return;
      }
      this.sendSearch(generation);
      for (let i: number = 1; i < 10; i++) {
        this.timers.push(setTimeout((): void => { if (this.current(generation)) { this.sendSearch(generation); } }, i * 2000));
      }
    } catch (error) {
      this.failure(1, error as BusinessError);
      if (this.current(generation)) { this.stop(); this.emit('无法搜索设备，请检查无线网络后重试'); }
    }
  }

  stop(): void {
    const wasActive: boolean = this.active;
    if (wasActive) {
      hilog.warn(0x0000, 'PiliMini-DLNA',
        'scan lanes=%{public}d replies=%{public}d candidates=%{public}d devices=%{public}d sendFailures=%{public}d descriptionFailures=%{public}d stage=%{public}d code=%{public}d',
        this.lanes.length, this.replies, this.seen.size, this.devices.length, this.sendFailures,
        this.descriptionFailures, this.lastFailureStage, this.lastFailureCode);
    }
    this.active = false; this.generation++;
    for (let i: number = 0; i < this.timers.length; i++) { clearTimeout(this.timers[i]); }
    this.timers = []; this.http.close(); this.candidates = [];
    const clients: socket.UDPSocket[] = this.lanes.map((lane: SearchLane): socket.UDPSocket => lane.socket);
    for (let i: number = 0; i < this.servers.length; i++) { clients.push(this.servers[i]); }
    this.lanes = []; this.servers = [];
    for (let i: number = 0; i < clients.length; i++) { this.closeSocket(clients[i]); }
    if (wasActive) { this.emit(); }
  }

  private failure(stage: number, error: BusinessError): void {
    this.lastFailureStage = stage;
    this.lastFailureCode = Number.isFinite(error.code) ? error.code : 0;
  }

  private closeSocket(client: socket.UDPSocket): void {
    try { client.off('message'); client.off('error'); } catch (_) {}
    try { client.close().catch((): void => {}); } catch (_) {}
  }

  private async addLane(net: connection.NetHandle, address: string, generation: number): Promise<void> {
    const client: socket.UDPSocket = socket.constructUDPSocketInstance();
    const lane: SearchLane = new SearchLane(client, net, address);
    this.lanes.push(lane);
    let stage: number = 3;
    try {
      client.on('message', (event: socket.SocketMessageInfo): void => { this.receive(event, net.netId, generation); });
      client.on('error', (_: BusinessError): void => {});
      await client.bind({ address: address, family: 1, port: 0 });
      if (!this.current(generation)) { this.closeSocket(client); return; }
      stage = 4; await net.bindSocket(client);
      if (!this.current(generation)) { this.closeSocket(client); return; }
      try {
        await client.setExtraOptions({ receiveBufferSize: 65536, sendBufferSize: 8192, broadcast: true });
      } catch (error) { this.failure(5, error as BusinessError); }
      if (!this.current(generation)) { this.closeSocket(client); }
    } catch (error) {
      this.failure(stage, error as BusinessError);
      this.closeSocket(client);
      const index: number = this.lanes.indexOf(lane);
      if (index >= 0) { this.lanes.splice(index, 1); }
    }
  }

  private async addNotify(net: connection.NetHandle, generation: number): Promise<void> {
    const server: socket.MulticastSocket = socket.constructMulticastSocketInstance();
    this.servers.push(server);
    try {
      server.on('message', (event: socket.SocketMessageInfo): void => { this.receive(event, net.netId, generation); });
      server.on('error', (_: BusinessError): void => {});
      server.setReuseAddress(true);
      await server.bind({ address: '0.0.0.0', family: 1, port: 1900 });
      if (!this.current(generation)) { this.closeSocket(server); return; }
      await net.bindSocket(server);
      if (!this.current(generation)) { this.closeSocket(server); return; }
      await server.addMembership({ address: SSDP_IP, family: 1, port: 1900 });
      if (!this.current(generation)) { this.closeSocket(server); }
    } catch (_) {
      this.closeSocket(server);
      const index: number = this.servers.indexOf(server);
      if (index >= 0) { this.servers.splice(index, 1); }
    }
  }

  private sendSearch(generation: number): void {
    for (let i: number = 0; i < this.lanes.length; i++) {
      const client: socket.UDPSocket = this.lanes[i].socket;
      for (let j: number = 0; j < SEARCH_TARGETS.length; j++) {
        if (!this.current(generation)) { return; }
        const payload: string = 'M-SEARCH * HTTP/1.1\r\nHOST: ' + SSDP_IP + ':1900\r\n' +
          'MAN: "ssdp:discover"\r\nMX: 2\r\nST: ' + SEARCH_TARGETS[j] + '\r\n\r\n';
        client.send({ data: payload, address: { address: SSDP_IP, family: 1, port: 1900 } }).catch((): void => {
          if (this.current(generation)) { this.sendFailures++; }
        });
      }
    }
  }

  private receive(event: socket.SocketMessageInfo, netId: number, generation: number): void {
    if (!this.current(generation) || event.message.byteLength > 16384 || this.seen.size >= 64 || this.devices.length >= 32) { return; }
    const host: string = event.remoteInfo.address;
    if (!DlnaDiscovery.ipv4(host) || /^127\.|^0\./.test(host)) { return; }
    let message: string;
    try { message = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(event.message)); } catch (_) { return; }
    if (!/^HTTP\/1\.[01] 200\b/i.test(message) && !/^NOTIFY \* HTTP\/1\.[01]/i.test(message)) { return; }
    if (/^NTS\s*:\s*ssdp:byebye/im.test(message)) { return; }
    this.replies++;
    const header: RegExpExecArray | null = /^LOCATION\s*:\s*([^\r\n]+)\s*$/im.exec(message);
    if (header === null) { return; }
    const location: string = this.resolve(header[1].trim(), '', host);
    if (location.length === 0 || this.seen.has(location)) { return; }
    this.seen.add(location);
    const candidate: DescriptionCandidate = new DescriptionCandidate();
    candidate.host = host; candidate.location = location; candidate.netId = netId;
    this.candidates.push(candidate); this.pump(generation);
  }

  private pump(generation: number): void {
    while (this.current(generation) && this.pending < 4 && this.candidates.length > 0 && this.devices.length < 32) {
      const candidate: DescriptionCandidate | undefined = this.candidates.shift();
      if (candidate === undefined) { return; }
      this.pending++;
      this.describe(candidate, generation).finally((): void => {
        if (generation === this.generation) { this.pending--; this.pump(generation); }
      });
    }
  }

  private async describe(candidate: DescriptionCandidate, generation: number): Promise<void> {
    try {
      const text: string = await this.http.request(candidate.location, '', '', candidate.netId);
      if (!this.current(generation)) { return; }
      const root: DlnaXmlNode = DlnaXml.parse(text);
      const baseNode: DlnaXmlNode | undefined = root.child('URLBase');
      const base: string = baseNode === undefined || baseNode.text.trim().length === 0 ? candidate.location :
        this.resolve(baseNode.text.trim(), candidate.location, candidate.host);
      if (base.length === 0) { return; }
      const devices: DlnaXmlNode[] = root.all('device');
      for (let i: number = 0; i < devices.length && this.devices.length < 32; i++) {
        const list: DlnaXmlNode | undefined = devices[i].child('serviceList');
        if (list === undefined) { continue; }
        for (let j: number = 0; j < list.children.length; j++) {
          const service: DlnaXmlNode = list.children[j];
          const type: string = this.childValue(service, 'serviceType');
          if (!/^urn:schemas-upnp-org:service:AVTransport:[0-9]+$/i.test(type)) { continue; }
          const control: string = this.resolve(this.childValue(service, 'controlURL'), base, candidate.host);
          if (control.length === 0) { continue; }
          const item: DlnaDevice = new DlnaDevice();
          item.id = this.childValue(devices[i], 'UDN') || candidate.location;
          if (this.devices.some((value: DlnaDevice): boolean => value.id === item.id || value.controlUrl === control)) { continue; }
          item.name = (this.childValue(devices[i], 'friendlyName') || '投屏设备').replace(/[\u0000-\u001f]/g, '').substring(0, 128);
          item.host = candidate.host; item.location = candidate.location; item.serviceType = type;
          item.controlUrl = control; item.scpdUrl = this.resolve(this.childValue(service, 'SCPDURL'), base, candidate.host);
          item.netId = candidate.netId; this.devices.push(item); this.emit(); break;
        }
      }
    } catch (error) {
      if (this.current(generation)) { this.descriptionFailures++; this.failure(6, error as BusinessError); }
    }
  }

  private childValue(parent: DlnaXmlNode, name: string): string {
    const node: DlnaXmlNode | undefined = parent.child(name);
    return node === undefined ? '' : node.text.trim();
  }

  private resolve(value: string, base: string, host: string): string {
    if (value.length === 0 || value.length > 4096 || /[\r\n\u0000]/.test(value)) { return ''; }
    try {
      const resolved: url.URL = base.length > 0 ? new url.URL(value, base) : new url.URL(value);
      if ((resolved.protocol !== 'http:' && resolved.protocol !== 'https:') || resolved.hostname !== host ||
        resolved.username.length > 0 || resolved.password.length > 0) { return ''; }
      resolved.hash = ''; return resolved.href;
    } catch (_) { return ''; }
  }

  private static ipv4(address: string): boolean {
    const values: string[] = address.split('.');
    if (values.length !== 4) { return false; }
    return values.every((value: string): boolean => /^\d{1,3}$/.test(value) && Number(value) <= 255);
  }
}
