# 啸天红外围界 · xiaotian.fence（历史存档）

> 历史存档：已被 `projects/xiaotian-pogo/` 的真实 HTTPS 基线取代，不再维护。
>
> 模块：啸天红外围界 ｜ id 82 ｜ 形态：仅主机（固件规划中）

门口通行 / 户外折线围界的红外对射模块。当前完成 Pi 侧插件、页面和离线状态机；
ESP32 侧探头采集固件仍在规划，尚未采购与实测。

## 包含什么

- `module.cpp`：布防/撤防、两路遮挡与心跳解析、3 秒告警保持、诊断字段上报。
- `qml/ModulePage.qml` + `qml/FenceState.qml`：布防状态、告警、历史、诊断面板。
- `tests/fence_module_test.cpp`：去抖、布防状态、告警保持、ABI 版本测试。
- `docs/`：首轮原型执行清单与需求交接（2026-10-25），硬件未定型。

## 未完成

- ESP 固件的红外探头采样、双线测速、折线分段告警。
- 实机布防/撤防、遮挡恢复、断线重连。
- 页面里的诊断字段只验证了模拟数据，没有真实传感器证据。

## 构建与测试

```sh
cmake -S . -B build -DMODULE_SDK_DIR=<SDK>/sdk -DMODULE_TESTING=ON \
  -DCMAKE_PREFIX_PATH=<Qt6>
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

或在 SDK 根目录跑 `python3 module_devkit.py test <本目录>`。

`module_id=82` 必须与目标 Pi profile 的接受范围一致；mock 设备已支持 82 的模拟围界上报。
