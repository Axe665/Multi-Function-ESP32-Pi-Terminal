# dist：预编译 DEB（不再分发）

预编译安装包已经停止分发——仓库和 Release 里都不再保留 `.deb`，
避免把几 GB 的构建产物塞进版本库。需要用现成包时自己打一份：

```sh
./build_scripts/build_deb.sh                    # 本机架构
dpkg-buildpackage -b -aarm64 -us -uc -d         # 交叉，先 export ORPI_* 三件套
```

- 产物由 `dpkg-buildpackage` 写在**仓库根目录**（`../*.deb`），不进 git
- 交叉编译需要的 SDK 分卷：先跑 `./tools/fetch_artifacts.sh`
- 打包细节见 [docs/deb-packaging.md](../docs/deb-packaging.md)

## 安装（自己打出来的包）

```sh
sudo apt install ./orange-pi-terminal_*.deb ./orange-pi-terminal-dev_*.deb
sudo systemctl disable --now orange-pi-net-proxy 2>/dev/null || true
systemctl --user restart pi-module-terminal
```
