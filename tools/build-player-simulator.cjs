/* Windows x86_64模拟器：从锁定的Nara同源源码构建调试库，生产arm64使用prepare-player-deps.cjs。
 * 依赖：Node、Python3、Git Bash、DevEco Native SDK；所有下载/产物只写.local-deps和entry/libs。
 * 用法：node tools/build-player-simulator.cjs --sdk <native目录> --python <python.exe> --bash <bash.exe>
 * 已校验产物默认直接复用；--rebuild重新执行构建。不会删除源码或工作区文件。
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const os = require('node:os');
const root = path.resolve(__dirname, '..');
const cache = path.join(root, '.local-deps', 'player');
const manifest = require('./player-simulator-sources.json');
const args = process.argv.slice(2);
const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const sdk = option('--sdk', process.env.OHOS_NATIVE_HOME);
const python = option('--python', process.env.PLAYER_PYTHON || 'python');
const bash = option('--bash', process.env.PLAYER_BASH || 'bash');
const target = path.join(root, 'entry', 'libs', 'x86_64', 'libmpv.so');
const stamp = path.join(cache, 'simulator-build.json');
const normalized = p => p.replaceAll('\\', '/');
const posix = p => normalized(path.resolve(p)).replace(/^([a-z]):/i, (_, drive) => '/' + drive.toLowerCase());
const quoted = s => "'" + s.replaceAll("'", "'\\''") + "'";
const sha = file => fs.existsSync(file) ? crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') : '';
const lockHash = sha(path.join(__dirname, 'player-simulator-sources.json'));
const recipeHash = sha(__filename);
function run(exe, argv, cwd = root, capture = false) {
  const result = spawnSync(exe, argv, { cwd, env: process.env, windowsHide: true,
    stdio: capture ? 'pipe' : 'inherit', maxBuffer: 32 * 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`${path.basename(exe)}失败：${result.error || result.stderr?.toString() || result.status}`);
  return result.stdout;
}
function download(item) {
  const file = path.join(cache, item.file);
  if (sha(file) !== item.sha256) {
    run('curl.exe', ['-4', '--fail', '--location', '--silent', '--show-error', '--retry', '3',
      '--connect-timeout', '15', '--max-time', '600', '--output', file, item.url]);
  }
  if (sha(file) !== item.sha256) throw new Error(`${item.file} SHA256不匹配，拒绝执行`);
  return file;
}
function write(file, content) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, content); }
function copy(from, to) { fs.mkdirSync(path.dirname(to), { recursive: true }); fs.cpSync(from, to, { recursive: true }); }
function meson(...argv) { run(python, ['-m', 'mesonbuild.mesonmain', ...argv]); }
function patchSimulatorResize(source) {
  const file = path.join(source, 'video', 'out', 'opengl', 'context_ohos.c');
  let text = fs.readFileSync(file, 'utf8').replaceAll('\r\n', '\n');
  const marker = 'PiliMini simulator: redraw once after EGL acquires the resized buffer.';
  if (text.includes(marker)) return;
  const replace = (before, after) => {
    if (text.split(before).length !== 2) throw new Error('模拟器EGL补绘补丁与锁定源码不匹配');
    text = text.replace(before, after);
  };
  replace('    EGLSurface egl_surface;\n', '    EGLSurface egl_surface;\n    bool resized;\n');
  replace('    eglSwapBuffers(p->egl_display, p->egl_surface);\n',
    '    eglSwapBuffers(p->egl_display, p->egl_surface);\n' +
    '    // ' + marker + '\n' +
    '    if (p->resized) {\n        p->resized = false;\n' +
    '        ctx->vo->want_redraw = true;\n        vo_wakeup(ctx->vo);\n    }\n');
  replace('static bool ohos_reconfig(struct ra_ctx *ctx)\n{\n',
    'static bool ohos_reconfig(struct ra_ctx *ctx)\n{\n    struct priv *p = ctx->priv;\n');
  replace('    ctx->vo->dwidth = w;\n',
    '    p->resized |= ctx->vo->dwidth != w || ctx->vo->dheight != h;\n    ctx->vo->dwidth = w;\n');
  write(file, text);
}
function main() {
  fs.mkdirSync(cache, { recursive: true });
  if (fs.existsSync(stamp) && !args.includes('--rebuild')) {
    const previous = JSON.parse(fs.readFileSync(stamp));
    if (previous.lockHash === lockHash && previous.recipeHash === recipeHash && sha(target) === previous.libraryHash) {
      console.log('libmpv x86_64 debug SHA256 verified'); return;
    }
  }
  if (!sdk || !fs.existsSync(path.join(sdk, 'llvm', 'bin', 'clang.exe')))
    throw new Error('请用--sdk或OHOS_NATIVE_HOME指定DevEco Native SDK');
  const llvm = name => path.join(sdk, 'llvm', 'bin', name + '.exe');
  const cmake = path.join(sdk, 'build-tools', 'cmake', 'bin', 'cmake.exe');
  const ninja = path.join(sdk, 'build-tools', 'cmake', 'bin', 'ninja.exe');
  process.env.PATH = [path.dirname(ninja), path.join(cache, 'bin'), process.env.PATH].join(path.delimiter);
  process.env.PYTHONPATH = path.join(cache, 'python');
  process.env.PKG_CONFIG_PATH = '';
  const prefix = path.join(cache, 'x86-prefix');
  process.env.PKG_CONFIG_LIBDIR = path.join(prefix, 'lib', 'pkgconfig');
  fs.mkdirSync(prefix, { recursive: true });
  run(python, ['-m', 'pip', 'install', '--target', process.env.PYTHONPATH,
    'meson==1.12.1', 'jinja2==3.1.6', 'glad2==2.0.8']);
  for (const item of manifest.sources) {
    const archive = download(item);
    if (!fs.existsSync(path.join(cache, item.directory))) run('tar', ['-xf', archive, '-C', cache]);
  }
  for (const item of manifest.tools) run('tar', ['-xf', download(item), '-C', cache]);
  const patch = download(manifest.patch);
  const source = name => path.join(cache, manifest.sources.find(s => s.file.startsWith(name)).directory);
  // 只影响模拟器O0库；暂停尺寸切换也需正确末帧，不能通过短暂播放强制刷新。
  patchSimulatorResize(source('mpv'));
  // 上游external-YUV补丁是Nara鸿蒙移植的一部分，不能省略。
  const patchArgs = ['apply', '--check', patch];
  const check = spawnSync('git', patchArgs, { cwd: source('placebo'), windowsHide: true, stdio: 'ignore' });
  if (check.status === 0) run('git', ['apply', patch], source('placebo'));
  else run('git', ['apply', '--reverse', '--check', patch], source('placebo'));
  copy(source('mbed-framework'), path.join(source('mbedtls'), 'framework'));
  const cross = path.join(cache, 'x86-cross.ini');
  const cc = [normalized(llvm('clang')), '--target=x86_64-linux-ohos', '--sysroot=' + normalized(path.join(sdk, 'sysroot'))];
  const cpp = [normalized(llvm('clang++')), ...cc.slice(1)];
  const list = value => '[' + value.map(quoted).join(', ') + ']';
  write(cross, `[binaries]\nc = ${list(cc)}\ncpp = ${list(cpp)}\nar = ${quoted(normalized(llvm('llvm-ar')))}\nstrip = ${quoted(normalized(llvm('llvm-strip')))}\npkg-config = ${quoted(normalized(path.join(cache, 'bin', 'pkg-config.exe')))}\n\n[host_machine]\nsystem = 'ohos'\ncpu_family = 'x86_64'\ncpu = 'x86_64'\nendian = 'little'\n\n[properties]\nneeds_exe_wrapper = true\npkg_config_libdir = [${quoted(normalized(process.env.PKG_CONFIG_LIBDIR))}]\n\n[built-in options]\nc_args = ['-fPIC']\ncpp_args = ['-fPIC']\nc_link_args = ['-Wl,-z,relro,-z,now']\ncpp_link_args = ['-Wl,-z,relro,-z,now']\n`);
  const jobs = Math.min(os.availableParallelism(), 8).toString();
  function cmakeLibrary(name, src, options) {
    const build = path.join(cache, 'build-' + name);
    run(cmake, ['-S', src, '-B', build, '-G', 'Ninja',
      '-DCMAKE_TOOLCHAIN_FILE=' + normalized(path.join(sdk, 'build', 'cmake', 'ohos.toolchain.cmake')),
      '-DOHOS_ARCH=x86_64', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
      '-DCMAKE_INSTALL_PREFIX=' + normalized(prefix), ...options]);
    run(cmake, ['--build', build, '--parallel', jobs]);
    run(cmake, ['--install', build]);
  }
  cmakeLibrary('mbed', source('mbedtls'), ['-DENABLE_PROGRAMS=OFF', '-DENABLE_TESTING=OFF',
    '-DUSE_SHARED_MBEDTLS_LIBRARY=OFF', '-DUSE_STATIC_MBEDTLS_LIBRARY=ON']);
  cmakeLibrary('freetype', source('freetype'), ['-DBUILD_SHARED_LIBS=OFF',
    ...['ZLIB','BZIP2','PNG','HARFBUZZ','BROTLI'].map(v => '-DFT_DISABLE_' + v + '=ON')]);
  // Win32没有宿主C编译器时，以TinyCC运行原版表生成器；库本身仍由SDK clang编译。
  const fri = source('fribidi'), tcc = path.join(cache, 'tcc', 'tcc.exe');
  const flags = ['-Ilib','-Igen.tab','-DHAVE_STDLIB_H','-DHAVE_STRING_H','-DFRIBIDI_LIB_STATIC','-DHAVE_STRINGIZE','-DDONT_HAVE_FRIBIDI_CONFIG_H'];
  function generate(name, inputs, output, unicode = false) {
    const generator = 'gen.tab/gen-' + name + '.exe';
    run(tcc, [...flags, '-o', generator, 'gen.tab/gen-' + name + '.c', ...(unicode ? [] : ['gen.tab/packtab.c'])], fri);
    write(path.join(fri, 'gen.tab', output), run(path.join(fri, generator), inputs, fri, true));
  }
  generate('unicode-version', ['gen.tab/unidata/ReadMe.txt','gen.tab/unidata/BidiMirroring.txt','gen-unicode-version'], 'fribidi-unicode-version.h', true);
  for (const [name, inputs] of Object.entries({ 'bidi-type':['UnicodeData.txt'], 'joining-type':['UnicodeData.txt','ArabicShaping.txt'],
    'arabic-shaping':['UnicodeData.txt'], 'mirroring':['BidiMirroring.txt'], 'brackets':['BidiBrackets.txt','UnicodeData.txt'], 'brackets-type':['BidiBrackets.txt'] })) {
    generate(name + '-tab', ['2', ...inputs.map(s => 'gen.tab/unidata/' + s), 'gen-' + name + '-tab'], name + '.tab.i');
  }
  write(path.join(fri, 'gen.tab', 'meson.build'), "fribidi_unicode_version_h = files('fribidi-unicode-version.h')\ngenerated_tab_include_files = []\ninstall_headers(fribidi_unicode_version_h, subdir: 'fribidi')\n");
  function mesonLibrary(name, src, options, shared = false) {
    const build = path.join(cache, 'build-' + name);
    meson('setup', ...(fs.existsSync(path.join(build, 'build.ninja')) ? ['--reconfigure'] : []), build, src,
      '--cross-file', cross, '--prefix', '/usr', '--libdir', 'lib', '--buildtype', shared ? 'debug' : 'release',
      '-Ddefault_library=' + (shared ? 'shared' : 'static'), ...options);
    run(ninja, ['-C', build, '-j', jobs]);
    const stage = path.join(cache, name + '-stage');
    meson('install', '-C', build, '--destdir', stage);
    copy(path.join(stage, 'usr'), prefix);
    const pc = path.join(prefix, 'lib', 'pkgconfig');
    for (const file of fs.readdirSync(pc).filter(s => s.endsWith('.pc'))) {
      const full = path.join(pc, file);
      write(full, fs.readFileSync(full, 'utf8').replace(/^prefix=\/usr$/m, 'prefix=' + normalized(prefix)));
    }
  }
  mesonLibrary('fribidi', fri, ['-Dbin=false','-Ddocs=false','-Dtests=false']);
  cmakeLibrary('harfbuzz', source('harfbuzz'), ['-DBUILD_SHARED_LIBS=OFF', '-DHB_BUILD_SUBSET=OFF',
    '-DHB_BUILD_UTILS=OFF', ...['CAIRO','FREETYPE','GLIB','GOBJECT','GRAPHITE2','ICU','INTROSPECTION'].map(v => '-DHB_HAVE_' + v + '=OFF')]);
  mesonLibrary('ass', source('libass'), ['-Dfontconfig=disabled','-Ddirectwrite=disabled','-Dcoretext=disabled',
    '-Drequire-system-font-provider=false','-Dasm=disabled','-Dtest=disabled','-Dcompare=disabled','-Dprofile=disabled',
    '-Dcheckasm=disabled','-Dfuzz=disabled','-Dlibunibreak=disabled']);
  mesonLibrary('placebo', source('placebo'), ['-Dvulkan=disabled','-Dd3d11=disabled','-Dshaderc=disabled',
    '-Dglslang=disabled','-Dlcms=disabled','-Dlibdovi=disabled','-Ddemos=false','-Dtests=false','-Dbench=false',
    '-Dxxhash=disabled','-Dunwind=disabled','-Dopengl=enabled']);
  // FFmpeg configure/make要求POSIX shell；所有路径用单引号独立转义。
  const wrapper = (name, executable, extra = []) => {
    const file = path.join(cache, name + '.sh');
    write(file, '#!/bin/bash\nexec ' + [posix(executable), ...extra].map(quoted).join(' ') + ' "$@"\n');
    return posix(file);
  };
  const ffcc = wrapper('clang-x86', llvm('clang'), cc.slice(1));
  const ffar = wrapper('ar-x86', llvm('llvm-ar')), ffnm = wrapper('nm-x86', llvm('llvm-nm'));
  // TinyCC用于生成工具，当前生成工具不依赖未实现的C11语义。
  const host = wrapper('host-tcc', tcc, ['-D__STDC_VERSION__=201112L']);
  const ffbuild = path.join(cache, 'build-ffmpeg'); fs.mkdirSync(ffbuild, { recursive: true });
  const ffOptions = ['--prefix=' + normalized(prefix), '--arch=x86_64', '--target-os=linux', '--enable-cross-compile',
    '--cc=' + ffcc, '--host-cc=' + host, '--ar=' + ffar, '--nm=' + ffnm,
    '--pkg-config=' + posix(path.join(cache, 'bin', 'pkg-config.exe')), '--pkg-config-flags=--static',
    '--extra-cflags=-I' + normalized(path.join(prefix, 'include')), '--extra-ldflags=-L' + normalized(path.join(prefix, 'lib')),
    '--enable-static','--disable-shared','--enable-version3','--enable-pic','--disable-doc','--disable-programs',
    '--disable-x86asm','--disable-autodetect','--disable-everything','--enable-avcodec','--enable-avformat','--enable-avfilter',
    '--enable-swresample','--enable-swscale','--disable-avdevice','--disable-devices','--enable-ohcodec','--enable-mbedtls',
    '--enable-decoder=h264,h264_oh,hevc,hevc_oh,mjpeg,png,aac,aac_latm,mp3,opus,ac3,eac3,flac,pcm_s16le,pcm_s16be,pcm_s32le,pcm_f32le,pcm_u8',
    '--enable-demuxer=mov,flv,mpegts,mp3,aac,hls,matroska','--enable-parser=h264,hevc,aac,mpegaudio,ac3,opus,mjpeg,flac',
    '--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata','--enable-protocol=file,http,https,tls,tcp',
    '--enable-filter=aresample,aformat,format,scale,anull,atrim,asetpts,setpts,volume,trim,abuffer,abuffersink,buffersink,buffer'];
  run(bash, ['-lc', [posix(path.join(source('ffmpeg'), 'configure')), ...ffOptions].map(quoted).join(' ')], ffbuild);
  // Win32 make的include和SRC_PATH必须是驱动器绝对路径，shell编译器参数保留POSIX路径。
  const makefile = path.join(ffbuild, 'Makefile');
  write(makefile, fs.readFileSync(makefile,'utf8').replace(/^include .+\/Makefile$/m, 'include ' + normalized(path.join(source('ffmpeg'), 'Makefile'))));
  const config = path.join(ffbuild, 'ffbuild', 'config.mak');
  write(config, fs.readFileSync(config,'utf8').replace(/^SRC_PATH=.+$/m, 'SRC_PATH=' + normalized(source('ffmpeg'))));
  run(bash, ['-lc', [posix(path.join(cache,'bin','make.exe')), '-j' + jobs, 'RANLIB=' + quoted(posix(llvm('llvm-ranlib')))].join(' ')], ffbuild);
  // FFmpeg在Windows上的install头路径不可用，按其公开头集合复制，包含configure生成头。
  for (const name of ['avcodec','avformat','avfilter','avutil','swresample','swscale']) {
    const lib = 'lib' + name;
    copy(path.join(ffbuild,lib,lib + '.a'), path.join(prefix,'lib',lib + '.a'));
    const headers = path.join(prefix,'include',lib); fs.mkdirSync(headers,{recursive:true});
    for (const directory of [path.join(source('ffmpeg'),lib), path.join(ffbuild,lib)])
      for (const file of fs.readdirSync(directory).filter(s => s.endsWith('.h'))) copy(path.join(directory,file),path.join(headers,file));
    copy(path.join(ffbuild,lib,lib + '.pc'),path.join(prefix,'lib','pkgconfig',lib + '.pc'));
  }
  mesonLibrary('mpv', source('mpv'), ['-Dgpl=false','-Dbuild-date=false','-Dcplayer=false','-Dmanpage-build=disabled',
    '-Dohos=enabled','-Degl-ohos=enabled','-Dvulkan=disabled','-Dshaderc=disabled','-Dlua=disabled','-Dlibavdevice=disabled',
    '-Dcplugins=disabled','-Dtests=false','-Djavascript=disabled','-Ddvdnav=disabled','-Dlibarchive=disabled',
    '-Drubberband=disabled','-Duchardet=disabled','-Dlibbluray=disabled','-Dcdda=disabled','-Ddvbin=disabled',
    '-Dvapoursynth=disabled','-Dzimg=disabled','-Dsdl2-audio=disabled','-Djack=disabled','-Dpipewire=disabled',
    '-Dpulse=disabled','-Dalsa=disabled','-Dopenal=disabled','-Dsdl2-gamepad=disabled','-Dopensles=disabled',
    '-Db_ndebug=false','-Dc_args=-fPIC'], true);
  copy(path.join(cache,'build-mpv','libmpv.so'),target);
  write(stamp, JSON.stringify({lockHash,recipeHash,libraryHash:sha(target),buildtype:'debug',architecture:'x86_64',
    note:'模拟器OpenGL优化构建崩溃尚未定位，使用O0；生产arm64保持Nara原始发布库。'},null,2) + '\n');
  console.log('libmpv x86_64 built: ' + sha(target));
}
try { main(); } catch(error) { console.error(error.message); process.exitCode = 1; }
