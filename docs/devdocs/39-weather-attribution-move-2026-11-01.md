# 天气署名迁移与地名去重（2026-11-01）

## 1. 需求

1. 「天气数据 © Open-Meteo.com CC BY 4.0」从天气页迁到「天气设置」；
2. 天气页左侧「实况」卡片里的地点大字去掉——顶部的地点切换器已经有一份，重复了。

## 2. 改动

### 2.1 天气页（`qml/WeatherTools.qml`）

| 位置 | 原 | 现 |
| --- | --- | --- |
| 实况卡片 `TimePane` 标题 | `title: 珠海`、`subtitle: 实况` | `title: 实况`，不再设 `subtitle` |
| 实况卡片底部 | `CarText { objectName: "weatherAttribution" }` | 删除 |

`TimePane` 的标题区本来就是「主标题左 + 副标题右」同一行（`qml/TimePane.qml` 的
`headingRow`，副标题为空时整条隐藏），所以去掉地名后卡片头只剩「实况」一行，
和其他卡片的「24 小时 + 逐小时」保持同一种行结构。

地名仍由顶部的 `weatherPlaceName`（`珠海`）与
`WeatherMath.placeLabel()`（`珠海 广东`）承担，信息没有丢。

### 2.2 天气设置（`qml/WeatherSettings.qml`）

主页 `homeColumn` 里，卡片 `GridLayout` 之后追加一段署名：

```qml
ColumnLayout {
    Layout.fillWidth: true
    Layout.topMargin: Theme.gap / 2
    Layout.bottomMargin: Theme.gap
    spacing: 2
    CarText { text: I18n.t("数据来源与许可"); fontPixelSize: Theme.fontCaption; color: Theme.outline }
    CarText {
        objectName: "weatherSettingsAttribution"
        subdued: true
        wrapMode: Text.Wrap
        visible: text !== ""
        text: settings.engine ? settings.engine.attribution : ""
    }
}
```

- 内容绑 `engine.attribution`（`WeatherEngine.qml`：
  `WeatherMath.sourceAttribution(model.source || activeSource)`），
  换数据源后署名跟着变，不会写死 Open-Meteo；
- 放主页底部而不是「数据源」二级页：5 张卡片下方正好是空白，同列左对齐，
  一眼能看到，不用再点一层；
- 「数据来源与许可」这个 key 早就在 `I18n.qml` 里（`Data sources and licences`），
  之前是死条目，这次用上了。

## 3. 验证

- `cmake --build /tmp/oobe-build -j8` 通过；
- `ctest -R weather`：2/2 通过；
- `ctest` 全量：72 项，69 通过，失败仍是既有的
  `arkpets_sprite_packing`、`ui_responsive_touch`、`ui_highdpi_touch`；
- 真机截图：
  - 天气页卡片头为「实况」，卡片底部与页面底部都没有署名；
  - 天气设置页底部出现「数据来源与许可 / 天气数据 © Open-Meteo.com CC BY 4.0」。

## 4. 备注

- `I18n.t("当前天气")` 随 `title` 改动失去引用，词条保留在 `I18n.qml` 里，未删；
- `weatherAttribution` 这个 objectName 只在 `WeatherTools.qml` 出现过，测试没有依赖，
  删除不影响 `weather_tools_page`。
