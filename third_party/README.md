# third_party 说明

本目录只放**第三方内容**，不放项目自己的代码。每个子目录对应一个上游项目，
命名与其上游一致；需要区分架构的（GStreamer、内置依赖包）在二级目录用
`<arch>/` 分层。

| 目录 | 内容 | 来源 |
|---|---|---|
| `Viper-Browser/` | 浏览器内核（Qt WebEngine 封装） | 上游 Viper 项目 |
| `YesPlayMusic/` | 音乐 API 参考实现 | 上游 YesPlayMusic |
| `vlc/` | `VlcVideoItem` 与 VLC 后端参考 | 上游示例 + 本项目适配 |
| `flite/` | 中文语音引擎（`flite_zh`） | CMU Flite |
| `sqlite-amalgamation/` | SQLCipher 依赖的 SQLite 源码 | SQLite 官方 amalgamation |
| `gst/` | GStreamer 头文件 + 运行期插件（见下） | Debian/Ubuntu 包解包 |
| `deps/` | OpenSSL / mbedTLS / SQLCipher 的开发包（按架构） | 发行版 `-dev` 包解包 |

## GStreamer（`gst/`）

两条获取路径，都**不需要 root**，只下载 `.deb` 解包：

```sh
./tools/fetch_gst_headers.sh                 # 开发期：头文件 + 链接期 .so
./tools/fetch_gst_plugins.sh --arch arm64    # 运行期：插件 .so（可交叉下载）
```

`gst/<arch>/` 的约定：

```text
gst/<arch>/
├── include/            # fetch_gst_headers.sh：头文件（含 glib-arch/glibconfig.h）
├── lib/                # fetch_gst_headers.sh：指向系统运行库的符号链接
└── plugins/
    ├── gstreamer-1.0/  # fetch_gst_plugins.sh：playbin/mp3/hls 等 element
    ├── lib/            # 插件的私有依赖（非基础库）
    └── MANIFEST.json   # 包名/版本/文件清单
```

目标机使用（不改系统、不装包）：

```sh
export GST_PLUGIN_PATH=$PWD/third_party/gst/arm64/plugins/gstreamer-1.0
export LD_LIBRARY_PATH=$PWD/third_party/gst/arm64/plugins/lib:$LD_LIBRARY_PATH
gst-inspect-1.0 playbin
```

**不要**把 `libgstreamer-1.0.so` 实体复制进 `gst/<arch>/lib/`：GStreamer 会按
自身位置重定位插件目录，复制后所有 element 都会 `no element`。`lib/` 里只能是
指向系统运行库的符号链接（`fetch_gst_headers.sh` 已按此设计）。

本仓库已预置两套运行期插件：

| 目录 | 插件数 | 体积 | 用途 |
|---|---|---|---|
| `gst/arm64/plugins/` | 255 | 27 MB | Pi 3B（目标机） |
| `gst/amd64/plugins/` | 264 | 22 MB | 开发机 / 测试机 |

它们只包含**插件本身**，链接的系统库由目标机提供。Pi 基线已确认具备：
`libmpg123.so.0`、`libavcodec/libavformat/libavfilter/libavutil`（若目标机缺，按
`MANIFEST.json` 里的包名安装 `libmpg123-0`、`libavcodec59` 等运行时包即可）。

## 内置开发依赖（`deps/`）

`deps/<arch>/` 是从发行版 `-dev` 包解出来的 OpenSSL / mbedTLS / SQLCipher 头文件与
库，供**没有系统开发包**的机器编译。当前只放了 `x86_64-linux-gnu/`；目标机（Pi）
直接用系统包，不需要这一份。

`pi_terminal/CMakeLists.txt` 通过 `TERMINAL_VENDOR_DEPS` 自动发现，不需要设置
`CMAKE_PREFIX_PATH`。

## 新增第三方内容的规则

1. 先查上游许可证，把 `LICENSE`/`NOTICE` 一并放进该子目录；
2. 不提交构建产物（`*.o`、`*.a`、可执行文件），只提交源码或运行期必需的文件；
3. 单个文件不超过 100 MB（GitHub 硬限制），大文件用 `tools/` 下的脚本按需下载；
4. 在 `docs/README.md` 或本文件登记来源、版本与用途。
