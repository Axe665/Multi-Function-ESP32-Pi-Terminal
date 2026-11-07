# dist：预编译 DEB

本目录放**已验证**的安装包，x86_64 与 arm64 各一套。

GitHub 单文件上限 100 MB，deb 以 **90 MB 分片**提交；用 `join.sh` 拼回：

```sh
./dist/join.sh          # 生成 4 个 .deb 在仓库根目录，并校验 SHA256SUMS
```

| 包 | 架构 | 大小 | 分片 | 说明 |
|---|---|---|---|---|
| `orange-pi-terminal` | arm64 | 242 MB | part00–02 | Pi 3B 运行时（自带 Qt 6.5.3） |
| `orange-pi-terminal-dev` | arm64 | 5 KB | part00 | 模块 SDK 头文件/CMake |
| `orange-pi-terminal` | amd64 | 272 MB | part00–03 | 开发机运行时 |
| `orange-pi-terminal-dev` | amd64 | 5 KB | part00 | 同上 |

## 安装

```sh
sudo apt install ./orange-pi-terminal_1.0.0_<arch>.deb ./orange-pi-terminal-dev_1.0.0_<arch>.deb
# 不要把系统代理设成开机自启，原因见 docs/known-issues.md #4
sudo systemctl disable --now orange-pi-net-proxy 2>/dev/null || true
systemctl --user restart pi-module-terminal
```

## 校验

```sh
sha256sum dist/*.deb        # 与下方 SHA256SUMS 对照
dpkg-deb -c dist/orange-pi-terminal_1.0.0_arm64.deb | head
```

## 构建

```sh
./build_scripts/build_deb.sh                    # 本机架构
dpkg-buildpackage -b -aarm64 -us -uc -d         # 交叉，先 export ORPI_* 三件套
```

详见 [docs/deb-packaging.md](../docs/deb-packaging.md)。
