# 第三方来源与许可证

PiliMini自身采用GPL-3.0-only。以下组件、图形数据及其修改仍保留原作者的版权和许可，根许可证不替代它们。此文件记录源码仓库中的直接来源与构建依赖，并非任意HAP包完整的依赖许可证清单。

## 参考与改编

- **PiliNara**：https://github.com/dev4harmony/PiliNara/tree/ohos ，上游项目还包括 https://github.com/Starfallan/PiliNara 及 https://github.com/bggRGjQaUbCoE/PiliPlus 。Nara的LICENSE为GNU GPL v3（https://github.com/dev4harmony/PiliNara/blob/ohos/LICENSE）。PiliMini以ArkTS/ArkUI重新组织界面和业务，参考其布局、动效、交互、播放器参数、后台行为及WBI签名；`member_level_*.svg`改编自Nara的`LevelCanvas`几何。保留上游项目及贡献者的版权，不将改编部分标为完全原创。
- **bilibili-API-collect**：https://github.com/SocialSisterYi/bilibili-API-collect ，仅用作接口资料参考；不将其整份文档复制入本仓库。
- `common/feed_navigation.ets`及主壳导航处理参考Nara的`pages/main/controller.dart`、`pages/common/common_controller.dart`和`utils/extension/scroll_controller_ext.dart`的单击回顶、双击刷新及500ms回顶规则；`components/FavFolderCard.ets`参考Nara的`FavVideoItem`/`FavFolderItem`的封面行与横向叠层预览。
- 下载资料库、版本化有序文件夹、离线播放范围与续播入口参考Nara [2.1.6.1-ohos](https://github.com/dev4harmony/PiliNara/tree/2.1.6.1-ohos/lib/pages/download)及上游[2.6.1.1](https://github.com/Starfallan/PiliNara/tree/2.6.1.1/lib/services/download)；卡片布局与选中动画参考`PageInfoItem`、`DetailItem`和`select_mask.dart`。以ArkTS服务、系统原生下载和现有播放器重新组织，不包含上游Dart流下载实现。

## 源码中保留的第三方内容

### libmpv C API头文件（ISC）

`entry/src/main/cpp/third_party/mpv/client.h`来自 https://github.com/p1nbored/mpv/blob/578c5bf8b3f615218162700438e89509005cd751/include/mpv/client.h ，保留文件内完整ISC许可。ISC许可的是接口头文件，并不表示libmpv二进制整体采用ISC。

```text
Copyright (C) 2017 the mpv developers

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

### Flutter播放/暂停图标数据（BSD-3-Clause）

`entry/src/main/ets/components/player/play_pause_frames.ets`改编自Flutter 3.44.0的`packages/flutter/lib/src/material/animated_icons/data/play_pause.g.dart`，将路径帧用于ArkUI Canvas；不引入Flutter运行时。来源：https://github.com/flutter/flutter/tree/3.44.0 。完整声明同时保留在源码文件内：

```text
Copyright 2014 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Source: flutter/flutter 3.44.0, packages/flutter/lib/src/material/animated_icons/data/play_pause.g.dart
```

## 通过包管理器获取的依赖

- **@ohos/zxing 2.1.2**：Apache-2.0，https://gitcode.com/openharmony-tpc/zxing 。用于生成登录二维码；第三方包由ohpm获取，不复制其源码或依赖目录入仓库。
- **@zxing/text-encoding 0.9.0**：`Unlicense OR Apache-2.0`，https://github.com/zxing-js/text-encoding ，为前者的传递依赖。分发时保留实际包提供的许可文本。

Apache-2.0文本：https://www.apache.org/licenses/LICENSE-2.0 。这些许可与GPL v3可组合使用，依赖自身不会因此被改标成GPL。

## 播放内核与构建依赖

- **arm64 libmpv**：来自 https://github.com/p1nbored/libmpv-ohos-build/releases/tag/20260831-hdr ，由`tools/prepare-player-deps.cjs`下载并核验SHA256，二进制不入库。
- **模拟器源码**：mpv、FFmpeg、libplacebo、libass、FreeType、HarfBuzz、FriBidi、Mbed TLS等的具体版本、源码地址和摘要见`tools/player-simulator-sources.json`；源码包、构建工具和输出均在忽略目录。
- **模拟器本地修改**：`tools/build-player-simulator.cjs`为mpv的OHOS OpenGL尺寸切换添加一次缓冲交换后的补绘，修复暂停末帧停留在旧缓冲尺寸的问题；修改随构建配方公开，仅用于x86_64调试库，生产arm64仍使用上方原始发布库。
- `tools/player-simulator-vo-worker.c`（LGPL-2.1-or-later）由构建脚本插入锁定版本mpv的`video/out/vo.c`，复用一个VO执行线程，完整保留每个VO的初始化/释放与等待结束语义。用于限制模拟器EGL驱动的每线程连接残留；源码纳入构建摘要，不修改arm64发布库。此文件为构建源码，仓库不包含可执行程序。
- mpv上游默认GPL-2.0-or-later，排除GPL专属代码的构建可采用LGPL-2.1-or-later；FFmpeg也随启用组件和配置决定许可。`gpl=false`配置本身不能代替实际组件核对。必须保留各自的`Copyright`、`LICENSE*`、补丁与构建信息。

当前Git仓库交付开发源码，不附播放器二进制。未来发布HAP或自行修改内核时，应按该包的实际组成提供许可声明、对应版本源码及必要构建/修改材料，不能只附本仓库的GPL文本或只链接一个上游首页就视为完成。
