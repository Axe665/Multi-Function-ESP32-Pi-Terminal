# 血压读数 · health.pressure

> 模块：血压读数 ｜ id 83 ｜ 形态：仅主机（无 ESP 固件）

Pi 侧插件与 QML 页面：手工录入一次收缩压 / 舒张压 / 脉搏，或接收设备上报的读数。
模块只做校验、去重和存储映射，**不做诊断**；越界或矛盾读数标为无效并给原因。

## 包含什么

- `module.cpp`：`pi_module_api_version` / manifest / 数据解析、边界校验、事件上报。
- `qml/ModulePage.qml`：录入表单、最近测量列表、来源与有效性标记。
- `tests/pressure_module_test.cpp`：边界值、缺失字段、无效原因、ABI 版本测试。
- 没有 ESP 固件：测量设备经终端已有的设备接入链路上报，模块只处理 `device.auto` /
  `device.manual` / `user.entry` 三种来源。

## 数据

- 上报字段：`source` / `device_model` / `measured_at_ms` / `systolic` / `diastolic` /
  `pulse` / `unit` / `valid` / `invalid_reason`。
- 页面持久化走宿主注入的 `moduleData.appendMeasurement()` / `recentMeasurements()`，
  不直接访问数据库。

## 构建与测试

```sh
cmake -S . -B build -DMODULE_SDK_DIR=<SDK>/sdk -DMODULE_TESTING=ON \
  -DCMAKE_PREFIX_PATH=<Qt6>
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

或在 SDK 根目录跑 `python3 module_devkit.py test <本目录>`。

`module_id=83` 必须与目标 Pi profile 的接受范围一致；mock 设备已支持 83 的模拟测量。
