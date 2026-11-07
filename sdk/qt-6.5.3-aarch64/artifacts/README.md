# 预编译交付包（分卷）

GitHub 单文件限制 100MB，258MB 的部署包拆成 90MB 分卷。

## 合并

```bash
cd artifacts
cat orpi-qt653-pi3.tar.zst.part* > orpi-qt653-pi3.tar.zst
sha256sum orpi-qt653-pi3.tar.zst
# 应为：74d1b6f1d479e04f536bbc487b495cf3f3979847f4d93ee99eadfa7b022b3e3c
```

## 内容

解压后 615MB：
- `opt/qt653-arm64/` — Qt 6.5.3 aarch64 运行时（WebEngine/Multimedia/TextToSpeech，
  8 个平台插件 + xcb EGL 集成）
- `usr/` — pi_terminal 产物（可执行 + 库 + QML 预缓存 + 模块 + 语音资源）
- `部署说明.md` — 安装、校验、安全配置
- `deploy-pi.sh` — Pi 端一键安装脚本

## 安装（Pi 上）

```bash
sudo tar -xf orpi-qt653-pi3.tar.zst -C /tmp
sudo bash /tmp/orpi-qt653-pi3/deploy-pi.sh
```

## 重新构建

不想用预编译包时：

```bash
./cross-build/build-qt653.sh && ./cross-build/build-project.sh && ./cross-build/make-deliverable.sh
```
