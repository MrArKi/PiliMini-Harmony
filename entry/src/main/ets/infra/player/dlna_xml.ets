import { util, xml } from '@kit.ArkTS';

/** 有界UPnP XML树；忽略前缀，但保持层级，避免把不同service字段拼到一起。 */
export class DlnaXmlNode {
  name: string;
  text: string = '';
  children: DlnaXmlNode[] = [];

  constructor(name: string) { this.name = name; }

  child(name: string): DlnaXmlNode | undefined {
    for (let i: number = 0; i < this.children.length; i++) {
      if (this.children[i].name === name) { return this.children[i]; }
    }
    return undefined;
  }

  first(name: string): DlnaXmlNode | undefined {
    if (this.name === name) { return this; }
    for (let i: number = 0; i < this.children.length; i++) {
      const found: DlnaXmlNode | undefined = this.children[i].first(name);
      if (found !== undefined) { return found; }
    }
    return undefined;
  }

  all(name: string): DlnaXmlNode[] {
    const result: DlnaXmlNode[] = this.name === name ? [this] : [];
    for (let i: number = 0; i < this.children.length; i++) {
      const found: DlnaXmlNode[] = this.children[i].all(name);
      for (let j: number = 0; j < found.length; j++) { result.push(found[j]); }
    }
    return result;
  }
}

export class DlnaXml {
  static parse(text: string): DlnaXmlNode {
    if (text.length === 0 || text.length > 262144 || /<!DOCTYPE|<!ENTITY/i.test(text)) {
      throw new Error('投屏设备响应无法解析');
    }
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    const parser: xml.XmlPullParser = new xml.XmlPullParser(bytes.buffer as ArrayBuffer, 'UTF-8');
    const root: DlnaXmlNode = new DlnaXmlNode('');
    const stack: DlnaXmlNode[] = [root];
    let count: number = 0;
    parser.parseXml({ supportDoctype: false, ignoreNameSpace: true,
      tokenValueCallbackFunction: (type: xml.EventType, info: xml.ParseInfo): boolean => {
        if (type === xml.EventType.START_TAG) {
          if (++count > 4096 || stack.length > 32) { throw new Error('投屏设备响应层级过深'); }
          const full: string = info.getName();
          const node: DlnaXmlNode = new DlnaXmlNode(full.substring(full.lastIndexOf(':') + 1));
          stack[stack.length - 1].children.push(node); stack.push(node);
        } else if (type === xml.EventType.END_TAG) {
          if (stack.length <= 1) { throw new Error('投屏设备响应结构异常'); }
          stack.pop();
        } else if (type === xml.EventType.TEXT || type === xml.EventType.CDSECT ||
          type === xml.EventType.ENTITY_REFERENCE) {
          if (stack.length > 1) { stack[stack.length - 1].text += info.getText(); }
        } else if (type === xml.EventType.DOCDECL) { throw new Error('投屏设备响应结构异常'); }
        return true;
      }
    });
    if (stack.length !== 1 || root.children.length !== 1) { throw new Error('投屏设备响应结构异常'); }
    return root.children[0];
  }

  static value(text: string, name: string): string {
    const node: DlnaXmlNode | undefined = DlnaXml.parse(text).first(name);
    return node === undefined ? '' : node.text.trim();
  }

  static values(text: string, name: string): string[] {
    const nodes: DlnaXmlNode[] = DlnaXml.parse(text).all(name);
    return nodes.map((node: DlnaXmlNode): string => node.text.trim());
  }

  static escape(value: string): string {
    return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }
}
