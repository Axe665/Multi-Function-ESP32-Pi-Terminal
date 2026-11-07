import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "WeatherMath.js" as WeatherMath

// 天气：一个内置应用页（section 14），与「时间」同级。
//
// 边界（与作者约定一致）：
// - 本文件只负责界面；地点、数据源、缓存与网络请求都归 WeatherEngine.qml
//   （在 Main 实例化一次），设置页的「天气」分区与这里看到的是同一份状态。
// - 左右双栏在可用宽度 >= 760 * uiScale 时生效；短屏不降级为单栏，正文在卡片内部滚动。
// - 不在页面里直接发请求，也不伪造数据：无数据时显示「暂无数据」，失败时显示原因，
//   有缓存时标注「缓存」与上次更新时间。
// - 数据源顺序、OpenWeather Key、自定义 API、刷新间隔、单位都在设置页；页面上只保留
//   一个刷新按钮与地点切换，避免把设置项塞进主界面。

Item {
    id: root
    objectName: "weatherToolsPage"

    property bool active: false
    property real uiScale: 1
    property var weatherEngine: null
    // 复用宿主已有的 FloatingKeyboard：这里只负责「请宿主打开键盘」。
    signal keyboardRequested()
    // 走宿主的 announce()：新主线的 TTS 引擎（flite 单文件声库）按设置里的音色播报。
    signal announceRequested(string text)

    readonly property var engine: weatherEngine
    readonly property var place: engine ? engine.place : null
    readonly property var current: engine ? engine.current : null
    readonly property var hourly: engine ? engine.hourly : []
    readonly property var daily: engine ? engine.daily : []
    readonly property var sourceMeta: {
        const units = engine ? engine.units : "metric"
        return {
            units: units,
            tempSuffix: WeatherMath.normalizeUnits(units) === "imperial" ? "°F" : "°C"
        }
    }
    readonly property int offsetSeconds: engine ? engine.utcOffsetSeconds : 0
    readonly property bool hasData: engine ? engine.hasData : false

    // 七天温度条：以本周最低/最高为 0..1 的映射基准（单位随数据源）。
    readonly property real weekMin: {
        let value = Infinity
        for (const day of root.daily) value = Math.min(value, WeatherMath.num(day.min))
        return isFinite(value) ? value : 0
    }
    readonly property real weekMax: {
        let value = -Infinity
        for (const day of root.daily) value = Math.max(value, WeatherMath.num(day.max))
        return isFinite(value) ? value : 1
    }
    function dayStartFrac(day) {
        const span = Math.max(1, root.weekMax - root.weekMin)
        return Math.max(0, Math.min(1, (WeatherMath.num(day.min) - root.weekMin) / span))
    }
    function dayEndFrac(day) {
        const span = Math.max(1, root.weekMax - root.weekMin)
        return Math.max(0, Math.min(1, (WeatherMath.num(day.max) - root.weekMin) / span))
    }

    // 页面设置：从右上角齿轮滑入，盖住内容区，工具栏保留（齿轮变返回）。
    property bool settingsOpen: false

    function openSettings() { settingsOpen = true }
    function closeSettings() { settingsOpen = false }
    // 切走/最小化时立即收起设置层，避免下次回到天气页时还停在上一个菜单。
    onActiveChanged: if (!active) {
        settingsOpen = false
        if (settingsLayer) settingsLayer.hideImmediately()
    }

    // 与时间页同一断点：760 * uiScale，不看高度。
    readonly property bool twoPane: width >= 760 * uiScale
    // 左右栏接近等宽：右栏原来明显更宽，整页视觉重心偏右。
    readonly property real leftPaneWidth: Math.max(240 * uiScale, Math.min(560, width * 0.47))
    // 短屏（800×480 预览）也留得住指标行：字号跟着高度收一档，宽屏不变。
    readonly property real bigTempFont: Math.min(72 * uiScale,
                                                 Math.max(40 * uiScale, Math.min(width / 9, height * 0.13)))

    property bool placeDialogOpen: false
    property string searchText: ""
    property string manualLat: ""
    property string manualLon: ""
    property string manualName: ""
    property string manualNotice: ""

    function openPlaceDialog() {
        placeDialogOpen = true
        manualNotice = ""
        if (engine) engine.clearSearch()
    }

    function closePlaceDialog() {
        placeDialogOpen = false
        if (engine) engine.clearSearch()
    }

    function submitManualPlace() {
        const lat = Number(manualLat)
        const lon = Number(manualLon)
        if (!isFinite(lat) || lat < -90 || lat > 90) {
            manualNotice = I18n.t("纬度需在 -90 到 90 之间")
            return
        }
        if (!isFinite(lon) || lon < -180 || lon > 180) {
            manualNotice = I18n.t("经度需在 -180 到 180 之间")
            return
        }
        const name = manualName.trim() !== "" ? manualName.trim()
                                              : lat.toFixed(2) + ", " + lon.toFixed(2)
        if (engine && engine.addPlace({ name: name, lat: lat, lon: lon, utcOffsetSeconds: 0 })) {
            manualLat = ""
            manualLon = ""
            manualName = ""
            manualNotice = ""
            closePlaceDialog()
        } else if (engine && engine.places.length >= engine.maxPlaces) {
            manualNotice = I18n.t("最多 8 个地点，先删除一个再添加")
        }
    }

    // 播报文案：实况 + 今日最低/最高 + 当前降水概率 + 未来 2 小时降水概率。
    // 只使用已完成的数据；没有数据时按钮禁用，不念占位符。
    function announceWeather() {
        if (!root.hasData || !root.current) return
        const units = root.sourceMeta.units
        const imperial = WeatherMath.normalizeUnits(units) === "imperial"
        const unitWord = imperial ? I18n.t("华氏度") : I18n.t("摄氏度")
        const temp = Math.round(WeatherMath.tempValue(root.current.temp, units))
        let text = (root.place ? root.place.name : "") + "，" + I18n.t("当前") + " " + temp + " " + unitWord
        text += "，" + I18n.t(WeatherMath.wmoText(root.current.code))
        const today = root.daily.length > 0 ? root.daily[0] : null
        if (today) {
            const low = Math.round(WeatherMath.tempValue(today.min, units))
            const high = Math.round(WeatherMath.tempValue(today.max, units))
            text += "。" + I18n.t("今天最低") + " " + low + " " + unitWord
                    + "，" + I18n.t("最高") + " " + high + " " + unitWord
        }
        if (WeatherMath.num(root.current.pop, -1) >= 0)
            text += "，" + I18n.t("降水概率") + " " + Math.round(root.current.pop) + "%"
        if (root.hourly.length >= 2) {
            let pop = -1
            for (let i = 0; i < 2; ++i) pop = Math.max(pop, WeatherMath.num(root.hourly[i].pop, -1))
            if (pop >= 0)
                text += "。" + I18n.t("未来 2 小时") + " " + I18n.t("降水概率") + " " + Math.round(pop) + "%"
        }
        root.announceRequested(text)
    }

    function updatedLabel() {
        if (!engine || !engine.hasData) return ""
        const time = WeatherMath.formatHm(engine.model.fetchedAt, offsetSeconds)
        // 三态：新鲜 → 「更新于」；用缓存 → 「缓存」；缓存超过 6 小时 → 「缓存已过期」。
        // 过期只是标签变化，数据照常显示，不删也不伪造。
        if (engine.cacheExpired) return I18n.t("缓存已过期 ") + time
        return (engine.stale ? I18n.t("缓存 ") : I18n.t("更新于 ")) + time
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        // 整页可以滚；「未来 7 天」卡片自己吃住垂直拖动（swallowVScroll），
        // 在那块区域滑动只滚卡片内部。
        contentHeight: weatherContent.item
                       ? Math.max(height, weatherContent.item.implicitHeight)
                       : height
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        clip: true

        // The hidden weather page is resized to 0 by StackLayout. Building its
        // wrapped forecast column there triggers a Qt 6.5 polish loop, so load
        // it only while the page is actually active.
        Loader {
            id: weatherContent
            width: flick.width
            // 双栏：底部留一格，卡片圆角不贴页面边缘；整页不滚动。
            height: root.twoPane
                    ? Math.max(0, flick.height - Theme.gap)
                    : (item ? item.implicitHeight : 0)
            // Tests create the page with active=false to avoid an automatic
            // refresh; a real hidden StackLayout page has width 0.
            active: root.active || root.width >= 240
            sourceComponent: Component {
        ColumnLayout {
            id: column
            // 双栏时整列正好等于视口，溢出交给卡片内部滚动；单栏按内容高，页面整体滚动。
            width: flick.width
            spacing: Theme.gap

            // ------------------------------------------------------ 工具栏
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2

                IconButton {
                    objectName: "weatherPreviousPlace"
                    iconName: "chevron_left"
                    label: I18n.t("上一个地点")
                    enabled: engine !== null && engine.places.length > 1
                    onClicked: if (engine) engine.shiftPlace(-1)
                }
                ColumnLayout {
                    Layout.fillWidth: false
                    Layout.maximumWidth: Math.max(160 * root.uiScale, root.width * 0.38)
                    spacing: 0
                    CarText {
                        objectName: "weatherPlaceName"
                        Layout.fillWidth: true
                        heading: true
                        maximumLineCount: 1
                        elide: Text.ElideRight
                        text: root.place ? root.place.name : I18n.t("天气")
                    }
                    CarText {
                        Layout.fillWidth: true
                        subdued: true
                        fontPixelSize: Theme.fontCaption
                        maximumLineCount: 1
                        elide: Text.ElideRight
                        text: {
                            if (!root.place) return I18n.t("正在读取地点")
                            const parts = [WeatherMath.placeLabel(root.place)]
                            if (root.engine && root.engine.loading) parts.push(I18n.t("更新中…"))
                            else if (root.updatedLabel() !== "") parts.push(root.updatedLabel())
                            return parts.join(" ")
                        }
                    }
                }
                IconButton {
                    objectName: "weatherNextPlace"
                    iconName: "chevron_right"
                    label: I18n.t("下一个地点")
                    enabled: engine !== null && engine.places.length > 1
                    onClicked: if (engine) engine.shiftPlace(1)
                }
                Item { Layout.fillWidth: true }
                IconButton {
                    objectName: "weatherPlaces"
                    iconName: "view_list"
                    label: I18n.t("地点")
                    onClicked: root.openPlaceDialog()
                }
                IconButton {
                    objectName: "weatherAnnounce"
                    iconName: "volume_up"
                    label: I18n.t("播报天气")
                    enabled: root.hasData
                    onClicked: root.announceWeather()
                }
                IconButton {
                    objectName: "weatherRefresh"
                    iconName: "refresh"
                    label: I18n.t("刷新天气")
                    enabled: engine !== null && !engine.loading
                    onClicked: if (engine) engine.refresh()
                }
                // 页面设置入口：放在最右、与高频操作之间留一个 gap，避免误触。
                Item { Layout.preferredWidth: Theme.gap / 2 }
                IconButton {
                    objectName: "weatherSettingsGear"
                    iconName: root.settingsOpen ? "arrow_back" : "settings"
                    label: root.settingsOpen ? I18n.t("返回") : I18n.t("设置")
                    onClicked: root.settingsOpen ? root.closeSettings() : root.openSettings()
                }
            }

            // ------------------------------------------------------ 双栏
            GridLayout {
                Layout.fillWidth: true
                Layout.fillHeight: root.twoPane
                // 底部留一格：卡片圆角不能贴着页面边缘被裁掉。
                Layout.bottomMargin: Theme.gap
                columns: root.twoPane ? 2 : 1
                columnSpacing: Theme.gap
                rowSpacing: Theme.gap

                TimePane {
                    objectName: "weatherCurrentPane"
                    Layout.fillWidth: !root.twoPane
                    Layout.preferredWidth: root.twoPane ? root.leftPaneWidth : -1
                    Layout.fillHeight: root.twoPane
                    scrollBody: root.twoPane
                    iconName: "wb_sunny"
                    accentColor: "#35a9ff"
                    // 地名由顶部的地点切换器负责，卡片里不再重复一遍。
                    title: I18n.t("实况")

                    // 大号温度 + 天气图标
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.gap / 2
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            RowLayout {
                                spacing: 2
                                CarText {
                                    objectName: "weatherTemperature"
                                    fontPixelSize: root.bigTempFont
                                    maximumLineCount: 1
                                    text: root.hasData && root.current
                                          ? WeatherMath.tempNumberText(root.current.temp, root.sourceMeta.units)
                                          : "--"
                                }
                                CarText {
                                    fontPixelSize: Theme.fontStrong
                                    subdued: true
                                    text: root.sourceMeta.tempSuffix
                                    Layout.alignment: Qt.AlignBottom
                                    Layout.bottomMargin: Theme.gap / 2
                                }
                            }
                            CarText {
                                Layout.fillWidth: true
                                maximumLineCount: 1
                                elide: Text.ElideRight
                                text: {
                                    if (!root.hasData || !root.current) return I18n.t("暂无数据")
                                    const today = root.daily.length > 0 ? root.daily[0] : null
                                    const highLow = today
                                        ? WeatherMath.tempText(today.max, root.sourceMeta.units) + " / "
                                          + WeatherMath.tempText(today.min, root.sourceMeta.units)
                                        : ""
                                    return I18n.t(WeatherMath.wmoText(root.current.code)) + "   " + highLow
                                }
                            }
                        }
                        MaterialIcon {
                            Layout.preferredWidth: Math.min(64 * root.uiScale, root.height * 0.12)
                            Layout.preferredHeight: Layout.preferredWidth
                            name: root.hasData && root.current
                                  ? WeatherMath.wmoIcon(root.current.code, root.current.isDay)
                                  : "wb_cloudy"
                            light: true
                        }
                    }

                    // 四项指标：2x2 小卡，图标 + 标签 + 值（Windows / GNOME 天气的指标块）
                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: Theme.gap / 2
                        rowSpacing: Theme.gap / 2
                        Repeater {
                            model: root.hasData && root.current ? [
                                { icon: "thermostat", label: I18n.t("体感"), value: WeatherMath.tempWithUnit(root.current.apparent, root.sourceMeta.units) },
                                { icon: "water_drop", label: I18n.t("湿度"), value: Math.round(root.current.humidity) + "%" },
                                { icon: "air", label: I18n.t("风速"), value: WeatherMath.windText(root.current.wind, root.sourceMeta.units) + " "
                                                              + I18n.t(WeatherMath.windDirText(root.current.windDir)) },
                                { icon: "umbrella", label: I18n.t("降水概率"), value: root.current.pop >= 0 ? Math.round(root.current.pop) + "%" : "—" }
                            ] : []
                            delegate: Rectangle {
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: metricColumn.implicitHeight + Theme.gap
                                radius: Theme.shapeMedium
                                color: Theme.surfaceContainer
                                border.width: 1
                                border.color: Theme.outlineVariant

                                ColumnLayout {
                                    id: metricColumn
                                    x: Theme.gap / 2
                                    y: Theme.gap / 2
                                    width: Math.max(1, parent.width - Theme.gap)
                                    spacing: 2

                                    RowLayout {
                                        spacing: Theme.gap / 2
                                        MaterialIcon {
                                            Layout.preferredWidth: 16 * root.uiScale
                                            Layout.preferredHeight: Layout.preferredWidth
                                            name: modelData.icon
                                            light: true
                                        }
                                        CarText {
                                            text: modelData.label
                                            subdued: true
                                            fontPixelSize: Theme.fontCaption
                                        }
                                    }
                                    CarText {
                                        Layout.fillWidth: true
                                        text: modelData.value
                                        fontPixelSize: Theme.fontLabel
                                        maximumLineCount: 1
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }

                    CarText {
                        Layout.fillWidth: true
                        visible: root.hourly.length >= 2
                        subdued: true
                        fontPixelSize: Theme.fontCaption
                        wrapMode: Text.Wrap
                        text: {
                            if (root.hourly.length < 2) return ""
                            let pop = -1
                            let low = Infinity
                            let high = -Infinity
                            for (let i = 0; i < 2 && i < root.hourly.length; ++i) {
                                pop = Math.max(pop, WeatherMath.num(root.hourly[i].pop))
                                low = Math.min(low, WeatherMath.num(root.hourly[i].temp))
                                high = Math.max(high, WeatherMath.num(root.hourly[i].temp))
                            }
                            const parts = [I18n.t("未来 2 小时")]
                            if (pop >= 0) parts.push(I18n.t("降水概率") + " " + Math.round(pop) + "%")
                            if (isFinite(low) && isFinite(high))
                                parts.push(WeatherMath.tempText(low, root.sourceMeta.units) + " ~ "
                                           + WeatherMath.tempText(high, root.sourceMeta.units))
                            return parts.join(" ")
                        }
                    }
                    CarText {
                        Layout.fillWidth: true
                        visible: root.engine !== null && root.engine.error !== ""
                        wrapMode: Text.Wrap
                        color: Theme.warning
                        fontPixelSize: Theme.fontCaption
                        text: root.engine ? root.engine.error : ""
                    }
                    // 数据来源署名移到「天气设置」里，天气页只放数据本身。
                }

                ColumnLayout {
                    objectName: "weatherForecastPane"
                    Layout.fillWidth: true
                    Layout.fillHeight: root.twoPane
                    spacing: Theme.gap

                    TimePane {
                        objectName: "weatherHourlyPane"
                        Layout.fillWidth: true
                        Layout.preferredHeight: 190 * root.uiScale
                        Layout.minimumHeight: 180 * root.uiScale
                        scrollBody: false
                        iconName: "wb_cloudy"
                        accentColor: "#4fd4a4"
                        title: I18n.t("24 小时")
                        subtitle: I18n.t("逐小时")
                        // 无数据：只给原因与重试，不摆空表格。
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: !root.hasData
                            spacing: Theme.gap / 2
                            CarText {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: root.engine && root.engine.error !== ""
                                      ? root.engine.error
                                      : I18n.t("暂无天气数据")
                            }
                            CarButton {
                                text: I18n.t("重试")
                                enabled: root.engine !== null && !root.engine.loading
                                onClicked: if (root.engine) root.engine.refresh()
                            }
                        }
                        // 24 小时横向条：时间 / 图标 / 温度 / 降水概率
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 92 * root.uiScale
                            visible: root.hasData
                        Flickable {
                            id: hourlyStrip
                            objectName: "weatherHourlyStrip"
                            anchors.fill: parent
                            clip: true
                            contentWidth: hourlyRow.width
                            contentHeight: height
                            boundsBehavior: Flickable.StopAtBounds
                            flickableDirection: Flickable.HorizontalFlick
                            Row {
                                id: hourlyRow
                                height: parent.height
                                spacing: Theme.gap / 2
                                Repeater {
                                    model: root.hourly
                                    delegate: Column {
                                        required property var modelData
                                        required property int index
                                        width: 56 * root.uiScale
                                        spacing: 2
                                        CarText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            fontPixelSize: Theme.fontCaption
                                            subdued: true
                                            text: index === 0 ? I18n.t("现在")
                                                              : WeatherMath.formatHm(modelData.t, root.offsetSeconds)
                                        }
                                        MaterialIcon {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 24 * root.uiScale
                                            height: width
                                            name: WeatherMath.wmoIcon(modelData.code, true)
                                            light: true
                                        }
                                        CarText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            fontPixelSize: Theme.fontLabel
                                            text: WeatherMath.tempText(modelData.temp, root.sourceMeta.units)
                                        }
                                        CarText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            fontPixelSize: Theme.fontCaption
                                            subdued: true
                                            text: modelData.pop >= 0 ? Math.round(modelData.pop) + "%" : " "
                                        }
                                    }
                                }
                            }
                        }
                        // 右侧渐隐：横向还能继续滑，但样式 ScrollBar 静止时会消失，
                        // 用一层与卡片同色的渐变提示"还有内容"，避免半截列看起来像裁切 bug。
                        Rectangle {
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: 28 * root.uiScale
                            visible: hourlyStrip.contentX + hourlyStrip.width < hourlyStrip.contentWidth - 1
                            gradient: Gradient {
                                GradientStop { position: 0; color: "transparent" }
                                GradientStop { position: 1; color: Theme.surface }
                            }
                        }
                        }
                    }

                    TimePane {
                        objectName: "weatherDailyPane"
                        Layout.fillWidth: true
                        Layout.fillHeight: root.twoPane
                        Layout.preferredHeight: 240 * root.uiScale
                        // 抬高下限：双栏内容高于视口，整页才有可滚的空间；
                        // 卡片内部仍然自己滚动（swallowVScroll 吃掉垂直手势）。
                        Layout.minimumHeight: 220 * root.uiScale
                        scrollBody: root.twoPane
                        // 只吃垂直拖动：这块区域滑动只滚 7 天列表，不带动整页。
                        swallowVScroll: true
                        iconName: "wb_cloudy"
                        accentColor: "#4fd4a4"
                        title: I18n.t("未来 7 天")
                        subtitle: I18n.t("逐日")
                        Repeater {
                            model: root.daily
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Theme.gap / 2
                                CarText {
                                    // 英文 "Tomorrow" 在 1.5× 字号下比中文长，留足宽度并允许省略。
                                    Layout.preferredWidth: 92 * root.uiScale
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                    text: WeatherMath.formatDayLabel(modelData.t, root.offsetSeconds, Date.now())
                                }
                                CarText {
                                    Layout.preferredWidth: 44 * root.uiScale
                                    subdued: true
                                    fontPixelSize: Theme.fontCaption
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                    text: WeatherMath.formatMonthDay(modelData.t, root.offsetSeconds)
                                }
                                MaterialIcon {
                                    Layout.preferredWidth: 22 * root.uiScale
                                    Layout.preferredHeight: 22 * root.uiScale
                                    name: WeatherMath.wmoIcon(modelData.code, true)
                                    light: true
                                }
                                CarText {
                                    Layout.preferredWidth: 46 * root.uiScale
                                    horizontalAlignment: Text.AlignRight
                                    subdued: true
                                    maximumLineCount: 1
                                    text: WeatherMath.tempText(modelData.min, root.sourceMeta.units)
                                }
                                // 温度条：这一天的低温~高温在本周区间里的位置。
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 6 * Theme.scaleFactor
                                    radius: height / 2
                                    color: Theme.surfaceContainerHigh
                                    Rectangle {
                                        x: parent.width * root.dayStartFrac(modelData)
                                        width: Math.max(6 * Theme.scaleFactor,
                                                        parent.width * (root.dayEndFrac(modelData) - root.dayStartFrac(modelData)))
                                        height: parent.height
                                        radius: height / 2
                                        color: Theme.accent
                                    }
                                }
                                CarText {
                                    Layout.preferredWidth: 46 * root.uiScale
                                    maximumLineCount: 1
                                    text: WeatherMath.tempText(modelData.max, root.sourceMeta.units)
                                }
                                CarText {
                                    visible: modelData.pop >= 0
                                    Layout.preferredWidth: 40 * root.uiScale
                                    horizontalAlignment: Text.AlignRight
                                    fontPixelSize: Theme.fontCaption
                                    subdued: true
                                    maximumLineCount: 1
                                    text: modelData.pop >= 0 ? Math.round(modelData.pop) + "%" : ""
                                }
                            }
                        }

                        CarText {
                            Layout.fillWidth: true
                            visible: root.engine !== null && root.engine.offsetApproximate && root.engine.hasData
                            wrapMode: Text.Wrap
                            subdued: true
                            fontPixelSize: Theme.fontCaption
                            text: I18n.t("当地时间按已保存的时区偏移显示，夏令时可能差一小时")
                        }
                    }
                }
            }


        }
    }

    // ------------------------------------------------------------ 地点弹层
    Item {
        id: placeOverlay
        objectName: "weatherPlaceDialog"
        anchors.fill: parent
        visible: root.placeDialogOpen
        z: 50

        Rectangle {
            anchors.fill: parent
            color: "#99040b14"
            MouseArea { anchors.fill: parent; onClicked: root.closePlaceDialog() }
        }

        Rectangle {
            id: placeCard
            anchors.centerIn: parent
            width: Math.min(root.width - Theme.gap * 2, 560 * root.uiScale)
            // 内容少时按内容高，内容多时封顶 620 并在卡片内滚动：避免空弹层留一大片空白。
            height: Math.min(root.height - Theme.gap * 2,
                             Math.min(620 * root.uiScale,
                                      dialogBody.implicitHeight + 48 * root.uiScale + Theme.gap * 4))
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outlineVariant
            clip: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.gap
                spacing: Theme.gap / 2

                RowLayout {
                    Layout.fillWidth: true
                    CarText { Layout.fillWidth: true; heading: true; text: I18n.t("地点") }
                    IconButton { iconName: "close"; label: I18n.t("关闭"); onClicked: root.closePlaceDialog() }
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: dialogBody.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: dialogBody
                        width: parent.width
                        spacing: Theme.gap / 2

                        Repeater {
                            model: root.engine ? root.engine.places : []
                            delegate: RowLayout {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                CarText {
                                    Layout.fillWidth: true
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                    text: WeatherMath.placeLabel(modelData)
                                }
                                CarText {
                                    visible: root.engine && root.engine.placeIndex === index
                                    fontPixelSize: Theme.fontCaption
                                    color: Theme.accent
                                    text: I18n.t("当前")
                                }
                                CarButton {
                                    text: I18n.t("切换")
                                    enabled: root.engine !== null && root.engine.placeIndex !== index
                                    onClicked: {
                                        if (!root.engine) return
                                        root.engine.setPlaceIndex(index)
                                        root.closePlaceDialog()
                                    }
                                }
                                IconButton {
                                    iconName: "delete"
                                    label: I18n.t("删除地点")
                                    enabled: root.engine !== null && root.engine.places.length > 1
                                    onClicked: if (root.engine) root.engine.removePlace(index)
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.gap / 2
                            CarField {
                                id: searchField
                                Layout.fillWidth: true
                                placeholderText: I18n.t("搜索城市，例如 珠海")
                                text: root.searchText
                                onTextChanged: root.searchText = text
                                // 只在「点输入框」时请求键盘：跟随焦点变化会在键盘关闭、焦点回弹时
                                // 再次触发，表现为键盘关了又开、关不掉（TimeTools 踩过同一个坑）。
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: { searchField.forceActiveFocus(); root.keyboardRequested() }
                                }
                                onAccepted: if (root.engine) root.engine.search(root.searchText)
                            }
                            CarButton {
                                text: root.engine && root.engine.searching ? I18n.t("搜索中…") : I18n.t("搜索")
                                enabled: root.engine !== null && !root.engine.searching && root.searchText.trim() !== ""
                                onClicked: if (root.engine) root.engine.search(root.searchText)
                            }
                        }

                        CarText {
                            Layout.fillWidth: true
                            visible: root.engine !== null && root.engine.searchError !== ""
                            wrapMode: Text.Wrap
                            color: Theme.warning
                            fontPixelSize: Theme.fontCaption
                            text: root.engine ? root.engine.searchError : ""
                        }

                        Repeater {
                            model: root.engine ? root.engine.searchResults : []
                            delegate: CarButton {
                                required property var modelData
                                Layout.fillWidth: true
                                text: WeatherMath.placeLabel(modelData) + "   "
                                      + Number(modelData.lat).toFixed(2) + ", " + Number(modelData.lon).toFixed(2)
                                onClicked: {
                                    if (!root.engine) return
                                    if (root.engine.addPlace(modelData)) root.closePlaceDialog()
                                    else if (root.engine.places.length >= root.engine.maxPlaces)
                                        root.manualNotice = I18n.t("最多 8 个地点，先删除一个再添加")
                                }
                            }
                        }

                        CarText {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.gap / 2
                            subdued: true
                            fontPixelSize: Theme.fontCaption
                            text: I18n.t("或手动输入经纬度")
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.gap / 2
                            CarField {
                                id: manualLatField
                                Layout.preferredWidth: 100 * root.uiScale
                                placeholderText: I18n.t("纬度")
                                text: root.manualLat
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                onTextChanged: root.manualLat = text
                                // 只在「点输入框」时请求键盘：跟随焦点变化会在键盘关闭、焦点回弹时
                                // 再次触发，表现为键盘关了又开、关不掉（TimeTools 踩过同一个坑）。
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: { manualLatField.forceActiveFocus(); root.keyboardRequested() }
                                }
                            }
                            CarField {
                                id: manualLonField
                                Layout.preferredWidth: 100 * root.uiScale
                                placeholderText: I18n.t("经度")
                                text: root.manualLon
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                onTextChanged: root.manualLon = text
                                // 只在「点输入框」时请求键盘：跟随焦点变化会在键盘关闭、焦点回弹时
                                // 再次触发，表现为键盘关了又开、关不掉（TimeTools 踩过同一个坑）。
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: { manualLonField.forceActiveFocus(); root.keyboardRequested() }
                                }
                            }
                            CarField {
                                id: manualNameField
                                Layout.fillWidth: true
                                placeholderText: I18n.t("名称（可选）")
                                text: root.manualName
                                onTextChanged: root.manualName = text
                                // 只在「点输入框」时请求键盘：跟随焦点变化会在键盘关闭、焦点回弹时
                                // 再次触发，表现为键盘关了又开、关不掉（TimeTools 踩过同一个坑）。
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: { manualNameField.forceActiveFocus(); root.keyboardRequested() }
                                }
                            }
                            CarButton {
                                text: I18n.t("添加")
                                onClicked: root.submitManualPlace()
                            }
                        }
                        CarText {
                            Layout.fillWidth: true
                            visible: root.manualNotice !== ""
                            color: Theme.warning
                            fontPixelSize: Theme.fontCaption
                            wrapMode: Text.Wrap
                            text: root.manualNotice
                        }
                    }
                }
            }
        }
            }
        }
    }

    // ------------------------------------------------------ 页面设置层
    // 整页不透明覆盖（连工具栏一起盖）：不依赖任何尺寸计算，下层一定被挡住。
    // 返回按钮由设置层自己提供；翻页过渡参考 VideoPlayer 的 transitionPanel。
    RightSlidePage {
        id: settingsLayer
        objectName: "weatherSettingsLayer"
        z: 20
        width: root.width
        height: root.height
        y: 0
        open: root.settingsOpen
        onCloseRequested: root.closeSettings()

        // 最外层也做圆角：整页铺满 + shapeExtraLarge 圆角，四角与窗口底色形成弧线。
        // 不透明底：先铺一层直角底把天气页彻底盖住（圆角处也不能漏），
        // 圆角交给上层面板画。
        // 边框区：与「预报」板块同一个圆角 token，四角跟着圆。
        Rectangle {
            anchors.fill: parent
            radius: Theme.shapeLarge
            color: Theme.surfaceContainer
            antialiasing: true
        }

        // 圆角面板：与设置页 SettingsGroup 同一套 token（surface + outlineVariant + shapeLarge）。
        Rectangle {
            anchors.fill: parent
            anchors.margins: Theme.gap
            radius: Theme.shapeLarge
            color: Theme.surface
            border.color: Theme.outlineVariant
            border.width: 1
            clip: true

        Loader {
            id: weatherSettingsContent
            anchors.fill: parent
            active: settingsLayer.visible
            sourceComponent: Component {
        ColumnLayout {
            x: Theme.gap
            y: Theme.gap
            width: Math.max(1, parent.width - Theme.gap * 2)
            height: Math.max(1, parent.height - Theme.gap * 2)
            spacing: Theme.gap

            // 标题在左、返回在右上角。
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarText {
                    Layout.fillWidth: true
                    heading: true
                    text: I18n.t("天气设置")
                }
                IconButton {
                    objectName: "weatherSettingsBack"
                    iconName: "arrow_back"
                    label: I18n.t("返回")
                    // 往左收一格：右侧不再贴着面板边框（那里看起来像被描边盖住）。
                    Layout.rightMargin: Theme.gap
                    onClicked: root.closeSettings()
                }
            }

            // 天气设置自己就是「主页卡片 + 滑入二级页」，这里只给它整块空间。
            WeatherSettings {
                Layout.fillWidth: true
                Layout.fillHeight: true
                weatherEngine: root.weatherEngine
                onKeyboardRequested: root.keyboardRequested()
            }
        }
            }
        }
        }
    }
}
