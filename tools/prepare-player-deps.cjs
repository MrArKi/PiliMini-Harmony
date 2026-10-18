/* Nara锁定的鸿蒙libmpv依赖。下载内容不入库，先校验再解压/使用。 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
require('node:dns').setDefaultResultOrder('ipv4first');
const root = path.resolve(__dirname, '..');
const cache = path.join(root, '.local-deps', 'player');
const target = path.join(root, 'entry', 'libs', 'arm64-v8a');
const archiveHash = 'b3aab969d282779be5d27aabb04a65793f3337f6aabbfcc6907012c03b58fe18';
const libraryHash = 'cb1dbeda351f67e7bc3b29a08fabe0bff8a5b4592cc759a39e39c3e516d4e8bd';
const url = 'https://github.com/p1nbored/libmpv-ohos-build/releases/download/20260831-hdr/libmpv_aarch64.zip';
// 同一发布资产的API入口，避免部分网络对github下载入口限流；内容仍由SHA256锁定。
const assetUrl = 'https://api.github.com/repos/p1nbored/libmpv-ohos-build/releases/assets/602424898?download=pilimini-full';
function hash(file) { return fs.existsSync(file) ? crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') : ''; }
(async () => {
 fs.mkdirSync(cache, { recursive: true });
 fs.mkdirSync(target, { recursive: true });
 const library = path.join(target, 'libmpv.so');
 if (hash(library) === libraryHash) { console.log('libmpv arm64-v8a SHA256 verified'); return; }
 const archive = path.join(cache, 'libmpv_aarch64.zip');
 if (hash(archive) !== archiveHash) {
  const result = spawnSync('curl.exe', ['-4', '--fail', '--location', '--silent', '--show-error', '--header', 'Accept: application/octet-stream', '--retry', '3', '--retry-all-errors', '--connect-timeout', '15', '--max-time', '900', '--output', archive, assetUrl], { stdio: 'inherit', windowsHide: true });
  if (result.status !== 0) throw new Error('libmpv下载失败');
 }
 if (hash(archive) !== archiveHash) throw new Error('libmpv archive SHA256 mismatch');
 const unpack = spawnSync('tar', ['-xf', archive, '-C', target], { stdio: 'inherit', windowsHide: true });
 if (unpack.status !== 0 || hash(library) !== libraryHash) throw new Error('libmpv library SHA256 mismatch');
 console.log('libmpv arm64-v8a SHA256 verified');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
