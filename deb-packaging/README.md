# deb-packaging：DEB 打包脚本与依赖说明

这个目录是**打包相关的全部脚本与描述文件**，供 review 后合并/替换仓库根目录的
`debian/`。不包含任何二进制（deb、Qt SDK、ESP 固件库）。

## 内容

| 文件 | 作用 |
|---|---|
| `debian/` | 标准 debhelper 打包目录（control/rules/stage-deb.sh/changelog/copyright/overrides/postinst/prerm） |
| `build_deb.sh` | 入口：准备三件套环境并调用 `dpkg-buildpackage` |
| `check_deps.sh` | 编译期 + 运行期依赖自检（含 VLC 插件、JDK、ffmpeg、网易云 node_modules） |
| `dependencies.md` | **依赖三类清单**：apt 自动装 / 随包内置 / 运行时下载 |
| `deb-packaging.md` | 包的布局、构建、校验、升级与已知问题 |
| `known-issues.md` | 本轮踩过的 7 个坑（GLIBC、worker 路径、代理冲突、fake-IP 等） |

## 使用

```sh
# 1) 把 debian/ 放回仓库根（本目录是提交形态，构建要求 debian/ 在根）
cp -r deb-packaging/debian .

# 2) 依赖自检（缺什么按提示装）
./deb-packaging/check_deps.sh

# 3) 出包
sudo apt install -y debhelper
ORPI_HOST_QT=/opt/Qt/6.5.3/gcc_64 dpkg-buildpackage -b -us -uc -d
```

交叉打 arm64 见 `build_deb.sh` 头部注释与 `deb-packaging.md`。

## 依赖策略（详见 `dependencies.md`）

1. **软件源里有的** → 写进 `debian/control` 的 `Depends`，`apt install ./pkg.deb` 自动装：
   `libvlc5, vlc-plugin-base`（视频）、`openjdk-17-jdk-headless`（桌宠转换）、
   `ffmpeg`（音乐元数据）、`nodejs, python3-pil, nftables, polkitd` 等。
2. **源里没有的** → 打进 deb：
   - Qt 6.5.3 运行时 → `/opt/orange-pi-terminal/qt`
   - `@neteaseapireborn/api` 的 `node_modules`（约 44 MB，构建前需存在）
   - amd64 的 `libsqlcipher`（Ubuntu 没有 `libsqlcipher0` 包）
3. **运行时下载**（不打包，需联网）：
   - 桌宠模型：`api.github.com`（raw 不通时回退）
   - Spine 转换 JAR：Maven Central，哈希锁定在 `arkpets/runtime-lock.json`

## 验证状态

| 架构 | 状态 |
|---|---|
| amd64 | **已实机验证**：安装、启动、VLC 解码、桌宠下载+转换、网易云 API 搜索/取流 |
| arm64 | **未在硬件验证**：交叉构建，配方一致；包内 `BUILD-STATUS.txt` 标注 UNTESTED |

## 注意

- 安装请用 `apt install ./orange-pi-terminal_*.deb`，不要 `dpkg -i`（否则依赖不自动装）；
- x86 包要求 glibc ≥ 2.38（Ubuntu 24.04+）；arm64 包按 Debian 12 构建（GLIBC ≤ 2.34）；
- deb 安装后**不要** enable `orange-pi-net-proxy`（system 代理用空策略会全拒），
  让应用自己拉起代理，见 `known-issues.md` #4。
