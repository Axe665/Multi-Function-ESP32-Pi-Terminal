# 浏览器虚拟摇杆（Joystick 控制网页浏览）

## 目标

为触屏浏览器增加一个**屏幕上的虚拟摇杆**：摇杆驱动高可见度光标在网页上移动，
光标靠近屏幕边缘时页面自动滚动，按钮完成点击/后退/刷新。面向适老化场景，
控件全部加大、支持拖动换位，不需要任何新硬件与原生依赖。

## 使用

1. 浏览器工具栏新增「摇杆」按钮，页面右下角也有常驻徽章；点开即展开面板。
2. 面板顶部长条可拖动整块面板换位置；中央圆盘是摇杆，拇指按住滑动即可
   移动黄色光标，松手自动回中。
3. 光标进入画面边缘约 7% 的区域时页面自动向该方向滚动，靠近边缘越快滚得越快。
4. 「点击」按钮对光标下的网页元素注入 `mousedown/mouseup/click` 并调用
   `el.click()`，链接、按钮、输入框均可触发。
5. 「后退」「刷新」直接作用于当前标签页；「收起」收回面板。

## 实现

全部逻辑在 `pi_terminal/qml/BrowserJoystick.qml` 一个文件内，Main.qml 只加了
一个工具栏按钮和组件实例，符合“功能单独文件、不污染 Main”的仓库约定：

- 光标与边缘滚动：16 ms 定时器把摇杆向量换算为光标位移；边缘区按接近度生成
  `window.scrollBy(dx,dy)` 注入（约每 3 帧一次），与既有 DragHandler 触摸滚动
  的注入方式一致。
- 点击：`document.elementFromPoint(x,y)` + 合成 MouseEvent + `el.click()`，
  坐标为网页 CSS 像素（除以 `devicePixelRatio × zoomFactor`），缩放页面下也准。
- 面板拖拽用 `DragHandler`（只抓长条把手），摇杆用 `MultiPointTouchArea`，
  二者互不干扰；光标/面板均为悬浮覆盖层，不拦截页面原有触摸。
- 不需要 C++：`runJavaScript/goBack/reload/canGoBack` 都是 WebEngineView
  既有 API，测试里用假视图替换即可。

## 测试（功能 / 界面 / 性能）

一键入口（构建 + 运行三层测试并输出汇总）：

```sh
pi_terminal/tests/run_joystick_tests.sh               # 功能 + 界面 + 性能
pi_terminal/tests/run_joystick_tests.sh --benchmark   # 仅性能层，打印 JOYSTICK_BENCH_* 指标
```

| 层 | 测试 | 覆盖内容 |
|---|---|---|
| 功能 | `browser_joystick_cursor` | 假 WebEngineView 记录注入 JS：摇杆把光标推入边缘后出现 `window.scrollBy`、点击注入含 `elementFromPoint`、后退/刷新调用数正确、toggle 收起 |
| 界面 | `browser_joystick_ui` | 展开/收起可见性（徽章/面板/光标）、光标几何与 cursorX/Y 公式一致、控件均 ≥48px（适老化触控目标）、后退按钮随 canGoBack 禁用、面板在 800×600 与 360×480 下均不出界 |
| 性能 | `browser_joystick_performance` | 边缘滚动注入速率（5–80 次/s，防失控循环）、setStick 调用吞吐、点击注入延迟、光标钳制到 1.0 不越界 |

## 实机验证清单

1. 触屏按住摇杆移动，光标流畅、松手回中无跳变。
2. 光标推入四边，长页面自动滚动；滚速随靠近边缘增大。
3. 在百度首页/新闻站点击链接、按钮、输入框各一次，均能触发。
4. 页面缩放（`zoomFactor` 1.2/1.5/2.0）下点击位置不偏移。
5. 无痕标签页与普通标签页切换后摇杆仍作用于当前页。
6. 拖动面板换位后摇杆与按钮工作正常；展开/收起反复切换无卡顿。
7. 跑 `run_joystick_tests.sh` 三层全绿，记录 `JOYSTICK_BENCH_*` 指标。
