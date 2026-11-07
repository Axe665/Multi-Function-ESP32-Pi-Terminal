# 天气界面去掉分隔点（2026-11-01）

## 1. 需求

天气页里中文与中文之间用间隔号 `·` 拼接（地点、更新时间、未来 2 小时摘要、
数据来源署名），视觉上偏碎。要求把这些用作分隔的点全部去掉。

替换策略：`" · "` → `" "`。

- 只删符号，不引入新的分隔符（不加 `，`、`｜`、`/`），保持句子还是那几段；
- 整体替换 `" · "` 而不是只删 `·`，避免留下 `"  "` 双空格；
- 英文译文同步去点，中英两种语言表现一致。

## 2. 改动位置

| 文件 | 位置 | 原文 | 现在 |
| --- | --- | --- | --- |
| `qml/WeatherMath.js` | `placeLabel()` | `珠海 · 广东` | `珠海 广东` |
| `qml/WeatherMath.js` | `sourceAttribution()` | `天气数据 © Open-Meteo.com · CC BY 4.0` | `天气数据 © Open-Meteo.com CC BY 4.0` |
| `qml/WeatherTools.qml` | `updatedLabel()` | `缓存 · HH:MM` / `缓存已过期 · HH:MM` | `缓存 HH:MM` / `缓存已过期 HH:MM` |
| `qml/WeatherTools.qml` | 地点副标题 | `parts.join(" · ")` | `parts.join(" ")` |
| `qml/WeatherTools.qml` | 未来 2 小时摘要 | `parts.join(" · ")` | `parts.join(" ")` |
| `qml/WeatherEngine.qml` | 全部数据源失败 | `所有数据源均不可用 · <原因>` | `所有数据源均不可用 <原因>` |
| `qml/WeatherEngine.qml` | 数据源测试成功 | `可用 · 27°C` | `可用 27°C` |
| `qml/WeatherEngine.qml` | 单源失败 | `<源名> · <原因>` | `<源名> <原因>` |
| `qml/WeatherSettings.qml` | 单位按钮 | `公制 · °C` / `英制 · °F` | `公制 °C` / `英制 °F` |

顺带清掉的死条目（`I18n.words` 里只有定义、全仓无引用）：

- `"24 小时 · 7 天"` → `"24 小时 7 天"`
- `"公制 °C · km/h"` / `"英制 °F · mph"` → 去点

## 3. 翻译表同步

`I18n.t()` 的 key 就是中文原文（`qml/I18n.qml` 的 `words`），
所以代码里改中文必须同步改 key，否则英文模式会退化成显示中文：

```qml
"缓存 ":"Cached ",
"缓存已过期 ":"Cached, expired ",
"公制 °C":"Metric °C",
"英制 °F":"Imperial °F",
```

注意 `"缓存 "` 只有 3 个字符：`I18n.t()` 按 key 长度降序做子串替换，
`"缓存已过期 "`（6 字符）先命中，不会把 `"缓存 "` 拆进它里面；
`"清除浏览缓存"` 这类不带空格的词也不受影响。

## 4. 测试同步

删掉分隔点会让断言里的期望串失配，四处一起改：

| 测试 | 断言 |
| --- | --- |
| `tests/weather_tools_test.cpp` | `contains("缓存 ")` / `contains("缓存已过期 ")` |
| `tests/weather_math_test.cjs` | `placeLabel(geo[0]) === '珠海 广东'` |

## 5. 验证

- `cmake --build /tmp/oobe-build -j8` 通过（QML 走 qmlcachegen，改完即嵌进资源）；
- `ctest -R weather`：`weather_tools_page`、`weather_math_functions` 2/2 通过；
- `ctest` 全量：**72 项，69 通过（96%）**，失败仍是既有的 3 项
  （`arkpets_sprite_packing`、`ui_responsive_touch`、`ui_highdpi_touch`），本次未引入新失败；
- 真机截图确认：
  - 天气页副标题 `珠海 广东 更新于 22:34`；
  - 未来 2 小时 `未来 2 小时 降水概率 0% 27° ~ 27°`；
  - 来源署名 `天气数据 © Open-Meteo.com CC BY 4.0`；
  - 设置 →「刷新与单位」按钮 `公制 °C` / `英制 °F`。
