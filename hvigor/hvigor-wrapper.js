/** 使用本机DevEco工具链；不把开发者的安装路径写入源码。 */
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ideHome = process.env.DEVECO_STUDIO_HOME;
const hvigorHome = process.env.DEVECO_HVIGOR_HOME || (ideHome && path.join(ideHome, 'tools', 'hvigor'));
const wrapper = hvigorHome && path.join(hvigorHome, 'bin', 'hvigorw.js');
if (!wrapper || !fs.existsSync(wrapper)) {
  console.error('[hvigor-wrapper] 请设置DEVECO_STUDIO_HOME为DevEco Studio安装目录，或设置DEVECO_HVIGOR_HOME。');
  process.exit(1);
}
if (!process.env.DEVECO_SDK_HOME && ideHome) {
  process.env.DEVECO_SDK_HOME = path.join(ideHome, 'sdk');
}
const result = spawnSync(process.execPath, [wrapper, ...process.argv.slice(2)], {
  stdio: 'inherit', cwd: process.cwd(), windowsHide: true
});
if (result.error) { console.error('[hvigor-wrapper] 调用失败：', result.error.message); }
process.exit(result.status === null ? 1 : result.status);
