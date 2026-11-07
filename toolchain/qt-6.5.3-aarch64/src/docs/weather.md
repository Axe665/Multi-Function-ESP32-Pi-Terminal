# 天气（实况 · 24 小时 · 7 天）

内置应用页 `section 14`（13 是「语音音色」），入口在首页/应用抽屉的"天气"卡片。实现分四块：
`pi_terminal/qml/WeatherTools.qml`（页面 UI）、`WeatherEngine.qml`（地点、数据源、缓存、
网络与降级）、`WeatherMath.js`（纯函数：URL、解析、WMO 映射、单位与时间换算）、
`WeatherSettings.qml`（设置页分区），另加 `SystemTools` 设置白名单里的 `weather/` 前缀。

参考 `open-meteo/open-meteo` 的取数模型：一次请求只要"一个点 × 一组变量 × 一段时间"，
所以页面按"当前实况 + 24 小时逐时 + 7 天逐日"三段取数，不做地图、雷达或历史回放。

## 范围

| 模块 | 行为 |
| :--- | :--- |
| 当前实况 | 大号温度、天气现象（WMO 码归并成 10 类）、今日高/低温、体感、湿度、风速与风向、降水概率；底部一行"未来 2 小时"摘要（降水概率 + 温度区间） |
| 逐小时 | 24 小时横向条：时间（首列显示"现在"）、图标、温度、降水概率；可横向滑动，右侧有渐隐提示 |
| 逐日 | 7 天列表：今天/明天/周几、日期、图标、最低~最高、天气、降水概率 |
| 地点 | 最多 8 个；页头左右切换；弹层里可搜索城市（Open-Meteo Geocoding）、手输经纬度、删除；默认珠海 |
| 数据源 | 全局降级链，前一个失败自动换下一个；顺序、启用、测试都在设置页 |
| 设置 | 设置页「天气」分区：数据源顺序/开关/测试、OpenWeather Key 与版本、自定义 API、MET Norway 联系方式、刷新间隔（5/15/30/60 分钟）、单位（公制/英制） |
| 播报 | 右上角喇叭按钮播报"地点 + 当前温度 + 天气 + 今日最低/最高 + 降水概率 + 未来 2 小时"；走宿主 `announce()`，即新主线的本地 flite 单文件声库，音色跟随「语音音色」设置，受「中文语音播报」总开关约束 |
| 缓存 | 每个地点最近一次成功结果落盘；断网时显示并标注"缓存 · HH:MM"，不伪造数据。超过 **6 小时**改标"缓存已过期 · HH:MM"（只换标签，数据照常显示） |

## 数据源

| id | 名称 | 需要 Key | 说明 |
| :--- | :--- | :--- | :--- |
| `open-meteo` | Open-Meteo | 否 | 默认源；`/v1/forecast` 一次拿到 current/hourly/daily，`timezone=auto` 返回地点偏移；CC BY 4.0，页面固定署名 |
| `met-no` | MET Norway | 否 | 开源备用源（NLOD / CC BY 4.0）；`locationforecast/2.0/compact`；**请求头必须能识别应用**，联系方式在设置里填，写进 User-Agent |
| `openweather` | OpenWeather | 是 | 两种版本：`One Call 3.0`（一次全给）或 `2.5`（weather + forecast 两个请求，3 小时粒度聚合成逐日）；Key 明文存 QSettings，未配置时该源自动跳过 |
| `custom` | 自定义 API | 视上游 | URL 模板 + 字段映射；模板留空字段映射时按 **Open-Meteo 兼容响应**解析（可指向自建 Open-Meteo） |

降级链的规则：

1. 只把"已启用且已配置"的源放进队列（OpenWeather 无 Key、自定义无 URL 时直接跳过）；
2. 任一源返回 2xx 且能解析出 `current` 才算出成功，否则把错误记在当前源名下继续下一个；
3. 全部失败时保留上次成功结果（可能来自缓存）并置 `stale`，错误行显示最后一个失败原因；
4. 刷新、测试、切换地点共用同一个"代次"（generation），旧请求的回调直接丢弃，
   不会出现"点到第三个地点，第二个地点的响应把页面覆盖"的竞态。

### 联网权限

发请求前统一走 `NetworkGate::allow("weather")`：总开关或「天气联网」关闭时
**一个请求都不发**，保留现有数据，错误行显示「联网已关闭」。地理编码搜索同样受约束。
没有 `networkGate` 上下文属性的环境（单元测试）按放行处理。
模型与六个开关见 `docs/networking.md`。

### 自定义 API 的字段映射

URL 占位符：`{lat}` `{lon}` `{name}` `{key}` `{units}`（固定传 `metric`）`{lang}`。

`{key}` 的取值来自设置页「自定义 API」下的 Key 输入框（`weather/custom.key`，明文存本机，
与 OpenWeather Key 同一约定）。模板里写了 `{key}` 却没填 Key 时，该源在降级链里按
**未配置**跳过——不会拿空值去请求上游。

字段用点路径描述，数组用数字下标；留空表示该字段不存在：

| 设置项 | 默认提示 | 用途 |
| :--- | :--- | :--- |
| 当前温度 | `current.temperature_2m` | 必填，缺失会导致该源被判定无效 |
| 天气码 | `current.weather_code` | WMO 0–99；缺失时显示"未知" |
| 逐小时时间 | `hourly.time` | ISO 或 unix 秒/毫秒 |
| 逐小时温度 | `hourly.temperature_2m` | 与时间数组等长 |
| 逐小时天气码 | `hourly.weather_code` | 可空 |
| 逐小时降水概率 | `hourly.precipitation_probability` | 0–100，可空 |
| 逐日日期 | `daily.time` | ISO 日期/时间 |
| 逐日最高温 | `daily.temperature_2m_max` | °C |
| 逐日最低温 | `daily.temperature_2m_min` | °C |
| 逐日天气码 | `daily.weather_code` | 可空 |

自定义源按公制（°C / km/h / mm）解析，显示层再按设置换算。

## 单位与时间

- **内部一律公制**：°C、km/h、mm、hPa。解析器不分支，显示层用
  `tempValue/windValue/precipValue` 换算；这样四个数据源共用一套断言。
- **时间一律 epoch 毫秒**，显示时用 `dateParts(epoch, offsetSeconds)` 把时刻平移到
  "地点本地时间"再读 UTC 字段，不依赖设备时区。
- Open-Meteo 返回的 `utc_offset_seconds` 会被写回地点（`adoptOffset`），
  于是切到 MET Norway 这类不返回时区的源时仍能显示正确当地时间；
  MET Norway 的结果标记 `offsetApproximate`，页面底部提示"夏令时可能差一小时"。
- 设备时钟本身由「时间」页的校时负责；天气页不重复校时。

## 布局

与时间页同一套约束：

    twoPane = width >= 760 * uiScale
    leftPaneWidth = clamp(240 * uiScale, width * 0.42, 460)

- 双栏时两卡撑满视口高度，正文在卡片内部滚动（复用 `TimePane` 的滚动条与底部渐隐）；
  单栏时整页滚动，卡片按内容高。
- 大号温度字号同时受宽度与高度约束（`min(width/9, height*0.13)`，上限 72），
  800×480 预览下也不会把指标行顶出卡片。
- 逐小时条固定高度 104，横向滚动；右侧 28px 渐隐只在还能继续滑时出现。
- 地点弹层是页面内的遮罩 + 卡片（不是 Popup），整块内容放在一个 Flickable 里，
  窄屏/大字档下不会把"添加"按钮挤出屏幕。
- 输入框只在**点击**时请求屏幕键盘（`MouseArea` 包一层），不跟随 `activeFocus`：
  键盘关闭时焦点回弹到输入框，跟随焦点会在那一刻再次弹出，表现为"键盘关了又开、
  关不掉"——与时间页 `stepperInput` 的处理一致。

## 语音播报

播报不新开通道：`WeatherTools` 发 `announceRequested(text)`，`Main.qml` 接到 `win.announce(text)`，
再由 `SystemTools::speak()` 走新主线的 TTS（含汉字 → 词典分词 → `voice.zhvox` 拼接 → 临时 WAV →
`QSoundEffect`；纯英文走 `cmu_us_slt`；都不可用才退回 espeak）。因此：

- 音色、输出设备、「中文语音播报」开关都在既有「声音与语音 / 语音音色」里，天气页不重复设置；
- 单条 300 字上限、单槽合并（新播报覆盖旧播报）、15 s 超时由 `SystemTools` 统一保证；
- 没有被朗读的占位符：无数据时按钮禁用；只有存在对应字段才拼进句子
  （例如数据源不给降水概率，就不念"降水概率"）。

文案示例（公制）：`珠海，当前 26 摄氏度，阴天。今天最低 25 摄氏度，最高 29 摄氏度，降水概率 0%。未来 2 小时 降水概率 0%`。

## 持久化键

全部经 `SystemTools.settingsRead/Write`，白名单前缀 `weather/`（单值上限 16 KB）：

| 键 | 内容 |
| :--- | :--- |
| `weather/places` | 地点数组 `{name, admin, country, lat, lon, utcOffsetSeconds}` |
| `weather/placeIndex` | 当前地点下标 |
| `weather/units` | `metric` / `imperial` |
| `weather/refreshMinutes` | 5–120，默认 15 |
| `weather/sources` | 有序数组 `[{id, enabled}]` |
| `weather/openweather.key` | 明文 Key |
| `weather/openweather.mode` | `onecall` / `2.5` |
| `weather/custom.url` | URL 模板 |
| `weather/custom.key` | 明文 Key；仅在模板含 `{key}` 时使用，空则跳过该源 |
| `weather/custom.mapping` | 字段路径对象 |
| `weather/metno.contact` | 写进 User-Agent 的联系方式 |
| `weather/cache/<lat>,<lon>` | 紧凑缓存（当前 + 24 小时 + 7 天，约 1–2 KB） |

页面/引擎在 `Component.onCompleted` 之前会把默认值写进属性，`loadingSettings` 门控
保证 `load()` 结束前不落盘——与时间功能踩过的坑一致。

## 隐私与署名

- 不接第三方分析、不埋点；唯一的外部请求是所选数据源、地理编码与 MET Norway；
- OpenWeather Key 明文保存在本机 QSettings，设置页明确提示，不做加密假象；
- 卡片底部固定显示数据源署名：Open-Meteo `天气数据 © Open-Meteo.com · CC BY 4.0`，
  MET Norway `Data from MET Norway · CC BY 4.0 / NLOD`，
  OpenWeather `Weather data © OpenWeather · CC BY-SA 4.0`。

## 测试

```bash
# 纯函数：直接执行线上那份 WeatherMath.js（Node）
node pi_terminal/tests/weather_math_test.cjs

# 页面：真实 WeatherTools.qml + 桩宿主，注入归一化结果，不联网
cd <build>
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./weather_tools_test
```

`weather_math_test.cjs` 覆盖：WMO/OpenWeather/MET Norway 码映射、风向、单位换算、
地点本地时间、四类 URL 构造、四个解析器（含 2.5 双请求合并）、地理编码、缓存往返、
数据源去重/排序、逐日聚合、默认地点、**缓存 6 小时 TTL 与 `{key}` 判定**。
该脚本已注册为 ctest `weather_math_functions`（找不到 node 时自动跳过）。

`weather_tools_test.cpp` 覆盖：默认珠海、双栏断点、实况/逐小时渲染、公制↔英制切换、
地点弹层开关、设置经宿主落盘、**自定义源缺 Key 时跳过**、**缓存过期后只换标签不丢数据**。

固定样本在 `tests/fixtures/weather/`：Open-Meteo 与 MET Norway 为真实响应，
OpenWeather 两份按官方响应结构构造（无 Key 也能测），`custom.json` 覆盖字段映射。

## 已知边界

- **未用真实 Key 验证 OpenWeather**：解析器对着固定样本与官方字段文档实现；填入 Key 后
  设置页的「测试」按钮会给出可用/失败与温度，便于首次联调。
- **MET Norway 的时区是推断的**：接口不返回地点时区，只能用地点里存的偏移并标注；
  跨夏令时切换可能出现一小时偏差。
- **不伪造数据**：无网络且无缓存时显示"暂无数据"；有缓存时标注"缓存 · HH:MM"，
  超过 6 小时改标"缓存已过期 · HH:MM"——只换标签，不清数据、不改数值。
- **自定义 Key 未在真实上游验证**：`{key}` 的替换与"缺 Key 跳过"有测试覆盖，
  但没有任何真实第三方接口的联调记录。
- **不做后台刷新**：应用不运行就不更新（与时闹钟一致）；页面打开时按设置间隔刷新。
- **不做雷达/地图/灾害预警**：这些需要额外的数据源与渲染层，不在本功能范围。
- 地理编码依赖 Open-Meteo 的公共接口；离线时只能手输经纬度。

## 图标

新增 12 个 Material Icons Round 天气图标（`wb_sunny`、`nights_stay`、`wb_cloudy`、`cloud`、
`grain`、`thunderstorm`、`ac_unit`、`dehaze`、`air`、`water_drop`、`thermostat`、`umbrella`），
Apache-2.0，源 URL 与 SHA-256 记录在 `qml/icons/material/SOURCES.json`，运行时按主题重着色。
