# 运行依赖：哪些 apt 装、哪些随包带、哪些运行时下载

`orange-pi-terminal` 的依赖分三类。打包脚本（`debian/control`、`debian/stage-deb.sh`）
与 `build_scripts/check_deps.sh` 必须与本文一致。

## 0. 验证状态

| 架构 | 状态 | 说明 |
|---|---|---|
| amd64 | **已实机验证** | 2026-11-08/09，Ubuntu 24.04：安装、启动、VLC 解码、桌宠下载+转换、网易云 API 搜索/取流全部通过 |
| arm64 | **未在硬件验证** | 交叉构建，配方与 amd64 相同；依赖声明与内置内容一致，但未在树莓派上安装/运行，发布前需实机验证 |

包内 `/usr/share/doc/orange-pi-terminal/BUILD-STATUS.txt` 会写明该包属于哪种状态。

## 1. 系统包（写进 Depends，apt 自动安装）

| 依赖 | 用途 | 缺了会怎样 |
|---|---|---|
| `libc6` `libstdc++6` `libgcc-s1` | C/C++ 运行时 | 起不来 |
| `libsqlcipher0`（仅 arm64） | 加密数据库 | 登录/开库失败 |
| `libmbedcrypto7` | PBR/加密原语 | 握手失败 |
| `libasound2` `pulseaudio-utils` | 音频与系统音量 | 音乐无声 |
| `nodejs` | 网易云 API 服务 | 在线音乐不可用 |
| `python3` `python3-pil` `python3-cryptography` | 桌宠图集打包、模块签名 | 桌宠下载后转换失败 |
| `ffmpeg` | 本地音乐元数据/封面（ffprobe/ffmpeg） | 本地歌曲无标题封面 |
| `libvlc5` `vlc-plugin-base` | 视频/电视（libvlc） | **黑屏、无法解码** |
| `openjdk-17-jdk-headless` | 桌宠 Spine 转换器（`java` + `javac`） | 桌宠“缺依赖，无法下载/切换模型” |
| `nftables` | 出站内核兜底 | 联网控制只剩应用层 |
| `polkitd` | 网络策略 helper 授权 | 改策略失败 |

> 这些全部由 `apt install ./orange-pi-terminal_*.deb` 自动拉取，不需要手动装。

## 2. 随包内置（源里没有，或版本必须固定）

| 内容 | 位置 | 原因 |
|---|---|---|
| Qt 6.5.3 运行时 | `/opt/orange-pi-terminal/qt/` | 系统 Qt 6.4 缺 6.5 私有 API |
| `libsqlcipher`（amd64） | `lib/orange-pi-terminal/` | Ubuntu 没有 `libsqlcipher0` 包 |
| `@neteaseapireborn/api` 4.29.7 + 依赖 | `libexec/orange-pi-terminal/music-api/node_modules/` | npm 包不在 Debian 源 |
| 终端自身二进制/库/资源/语音 | `/opt/orange-pi-terminal/` | 项目本体 |

打包前必须存在 `pi_terminal/music_api/node_modules`（否则 `stage-deb.sh` 直接报错退出）。
生成方式：

```sh
./build_scripts/check_deps.sh            # 检查并提示
# 或
bash pi_terminal/scripts/install-music-api.sh
```

## 3. 运行时联网下载（不打包，需目标机可访问互联网）

| 内容 | 来源 | 说明 |
|---|---|---|
| 桌宠模型（`.atlas/.skel/.png`） | `api.github.com`（`raw.githubusercontent.com` 不通时自动回退） | 只下载所选角色，不下载整库 |
| Spine 转换 JAR（lwjgl/gdx/spine-libgdx） | `repo.maven.apache.org` | 哈希锁定在 `arkpets/runtime-lock.json`，按架构下载 |

`raw.githubusercontent.com` 被墙时回退可用；如果两个 GitHub 域名都不通，桌宠下载会失败，
但已有模型与内置阿米娅不受影响。

## 4. 打包前自检

```sh
./build_scripts/check_deps.sh                     # 逐项 [ok]/[缺]
dpkg-deb -c orange-pi-terminal_*.deb | grep node_modules | head   # 必须非空
dpkg-deb -f orange-pi-terminal_*.deb Depends                      # 必须含 vlc-plugin-base/jdk/ffmpeg
```

`lintian` 对内置 Qt/私有库会报 `embedded-library`/`dir-or-file-in-opt`，已在
`debian/*.lintian-overrides` 中说明。
