import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "WeatherMath.js" as WeatherMath

// 设置页的「天气」分区：数据源、OpenWeather、自定义 API、刷新与单位。
//
// 边界（与时间功能一致）：
// - 只做设置界面；地点、数据源顺序、缓存与请求状态都归 WeatherEngine.qml（Main 里
//   实例化一次），这里改完，天气页立刻是同一份状态。
// - Key 以明文存进 QSettings（设备本地、无安全 enclave），界面明确写清楚；
//   未配置 Key 时 OpenWeather 源在降级链里自动跳过，不会拿空 Key 去请求。
// - 控件全部复用 CarButton / CarField / Switch / IconButton 与 Theme token，
//   热区不小于 Theme.hit，不引入新依赖。

// 天气设置：分类卡片 + 滑入二级页（与「用户与权限」同一套导航）。
// 页内只保留最上面的主标题，分组内容不再带标题。
Item {
    id: settings
    objectName: "weatherSettingsPanel"


    property var weatherEngine: null
    property string keyNotice: ""
    property string customKeyNotice: ""
    property string contactNotice: ""
    property bool showMapping: false

    readonly property var engine: weatherEngine

    function sourceEnabled(id) {
        if (!engine) return false
        for (let i = 0; i < engine.sources.length; ++i)
            if (engine.sources[i].id === id) return engine.sources[i].enabled
        return false
    }

    function sourceStatus(id) {
        if (!engine) return ""
        if (id === "openweather" && engine.openWeatherKey === "") return I18n.t("未配置 Key")
        if (id === "custom") {
            if (engine.customUrl === "") return I18n.t("未配置 URL")
            // 模板里写了 {key} 却没填 Key：与 OpenWeather 同待遇，在降级链里跳过。
            if (WeatherMath.customUrlNeedsKey(engine.customUrl) && engine.customKey === "")
                return I18n.t("未配置 Key")
        }
        if (engine.probeSourceId === id) {
            if (engine.probing) return I18n.t("测试中…")
            if (engine.probeMessage !== "") return engine.probeMessage
        }
        return sourceEnabled(id) ? I18n.t("已启用") : I18n.t("已停用")
    }

    // 字段映射：留空表示按 Open-Meteo 兼容响应解析（"只改 base URL"模式）。
    readonly property var mappingFields: [
        { key: "currentTemp", label: "当前温度", hint: "current.temperature_2m" },
        { key: "currentCode", label: "天气码", hint: "current.weather_code" },
        { key: "hourlyTime", label: "逐小时时间", hint: "hourly.time" },
        { key: "hourlyTemp", label: "逐小时温度", hint: "hourly.temperature_2m" },
        { key: "hourlyCode", label: "逐小时天气码", hint: "hourly.weather_code" },
        { key: "hourlyPop", label: "逐小时降水概率", hint: "hourly.precipitation_probability" },
        { key: "dailyDate", label: "逐日日期", hint: "daily.time" },
        { key: "dailyMax", label: "逐日最高温", hint: "daily.temperature_2m_max" },
        { key: "dailyMin", label: "逐日最低温", hint: "daily.temperature_2m_min" },
        { key: "dailyCode", label: "逐日天气码", hint: "daily.weather_code" }
    ]


    // -1 = 主页；0..4 = 分类页。
    property int section: -1

    // 只做界面提示，不参与业务：键盘由宿主 Main 打开。
    signal keyboardRequested()

    // 分类卡片：与「用户与权限」主页同一套卡片语言。
    readonly property var cards: [
        { icon: "public", color: "#35a9ff", title: I18n.t("数据源"), desc: I18n.t("顺序、启用与连通性测试") },
        { icon: "lock", color: "#ffb74d", title: I18n.t("OpenWeather"), desc: I18n.t("API Key 与接口版本") },
        { icon: "code", color: "#4c9dff", title: I18n.t("自定义 API"), desc: I18n.t("URL、Key 与字段映射") },
        { icon: "language", color: "#4fd4a4", title: I18n.t("MET Norway"), desc: I18n.t("请求头里的联系邮箱") },
        { icon: "refresh", color: "#10b7a8", title: I18n.t("刷新与单位"), desc: I18n.t("自动刷新间隔与公制/英制") }
    ]

    // ------------------------------------------------------------ 主页
    Flickable {
        anchors.fill: parent
        visible: settings.section < 0
        contentWidth: width
        contentHeight: homeColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        ColumnLayout {
            id: homeColumn
            // 左右各留一格：卡片不能贴面板右边，否则右侧看起来被边框盖住。
            x: Theme.gap
            // 右侧再多留一格：卡片右边缘原来离面板比左边近，整体看着偏右。
            width: Math.max(1, parent.width - Theme.gap * 3)
            spacing: Theme.gap

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                rowSpacing: Theme.gap
                columnSpacing: Theme.gap

                Repeater {
                    model: settings.cards
                    delegate: Rectangle {
                        id: settingCard
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.preferredHeight: 112 * Theme.scaleFactor
                        radius: Theme.shapeLarge
                        color: cardMouse.containsMouse ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                        border.width: 1
                        border.color: cardMouse.containsMouse ? Theme.accent : Theme.outlineVariant

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.gap
                            spacing: Theme.gap
                            Rectangle {
                                Layout.preferredWidth: 44 * Theme.scaleFactor
                                Layout.preferredHeight: width
                                radius: width / 2
                                color: Qt.darker(settingCard.modelData.color, 2.1)
                                border.color: Qt.lighter(settingCard.modelData.color, 1.15)
                                MaterialIcon {
                                    anchors.centerIn: parent
                                    width: 24 * Theme.scaleFactor
                                    height: width
                                    name: settingCard.modelData.icon
                                    light: true
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                CarText {
                                    Layout.fillWidth: true
                                    text: settingCard.modelData.title
                                    fontPixelSize: Theme.fontStrong
                                    color: Theme.foreground
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                CarText {
                                    Layout.fillWidth: true
                                    text: settingCard.modelData.desc
                                    fontPixelSize: Theme.fontCaption
                                    color: Theme.outline
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }
                            }
                            MaterialIcon {
                                Layout.preferredWidth: Theme.icon
                                Layout.preferredHeight: Theme.icon
                                name: "chevron_right"
                                light: true
                            }
                        }
                        MouseArea {
                            id: cardMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: settings.section = settingCard.index
                        }
                    }
                }
            }

            // 数据来源与许可：原来挂在天气页底部，现在统一收进设置里。
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.gap / 2
                Layout.bottomMargin: Theme.gap
                spacing: 2
                CarText {
                    Layout.fillWidth: true
                    text: I18n.t("数据来源与许可")
                    fontPixelSize: Theme.fontCaption
                    color: Theme.outline
                }
                CarText {
                    objectName: "weatherSettingsAttribution"
                    Layout.fillWidth: true
                    subdued: true
                    fontPixelSize: Theme.fontCaption
                    wrapMode: Text.Wrap
                    visible: text !== ""
                    text: settings.engine ? settings.engine.attribution : ""
                }
            }
        }
    }

    // ------------------------------------------------------------ 分类二级页
    RightSlidePage {
        id: detail
        objectName: "weatherSettingsDetail"
        width: settings.width
        height: settings.height
        z: 20
        open: settings.section >= 0
        onCloseRequested: settings.section = -1

        // 二级页背景：内缩一格并用面板同色，右边缘不再压在面板边框上。
        Rectangle {
            anchors.fill: parent
            anchors.margins: Theme.gap / 2
            radius: Theme.shapeMedium
            color: Theme.surface
        }

        ColumnLayout {
            anchors.fill: parent
            // 返回键往左靠：左边距只留半格，右边仍留一格。
            anchors.leftMargin: Theme.gap / 2
            anchors.rightMargin: Theme.gap
            anchors.topMargin: Theme.gap / 2
            anchors.bottomMargin: Theme.gap
            spacing: Theme.gap

            RowLayout {
                Layout.fillWidth: true
                // 返回键与标题之间留一格，避免图标与文字贴在一起。
                spacing: Theme.gap
                IconButton {
                    objectName: "weatherSettingsDetailBack"
                    iconName: "arrow_back"
                    label: I18n.t("返回")
                    onClicked: settings.section = -1
                }
                CarText {
                    Layout.fillWidth: true
                    heading: true
                    elide: Text.ElideRight
                    text: settings.section >= 0 && settings.section < settings.cards.length
                          ? settings.cards[settings.section].title : ""
                }
            }

            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: detailColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                ColumnLayout {
                    id: detailColumn
                    // 与主页同一套左右留白。
                    x: Theme.gap
                    width: Math.max(1, parent.width - Theme.gap * 3)
                    spacing: Theme.gap

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: settings.section === 0
                        spacing: Theme.gap
    // ------------------------------------------------------------ 数据源


    // 数据源：一行一个源（名称 + 状态 + 开关），排序/测试收在下一行，
    // 避免一行挤五个控件（Windows「应用与功能」/ Android 列表的做法）。
    Repeater {
        model: settings.engine ? settings.engine.sources : []
        delegate: ColumnLayout {
            required property var modelData
            required property int index
            Layout.fillWidth: true
            spacing: Theme.gap / 2

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarText {
                    Layout.fillWidth: true
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    // 数据源名是这一行的主语：和卡片标题同一档，不要被按钮压小。
                    fontPixelSize: Theme.fontStrong
                    color: Theme.foreground
                    text: WeatherMath.sourceLabel(modelData.id)
                }
                CarText {
                    fontPixelSize: Theme.fontCaption
                    color: (modelData.id === "openweather" && settings.engine.openWeatherKey === "")
                           || (modelData.id === "custom" && settings.engine.customUrl === "")
                           ? Theme.warning : Theme.secondary
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    Layout.maximumWidth: 190 * Theme.scaleFactor
                    text: settings.sourceStatus(modelData.id)
                }
                Switch {
                    objectName: "weatherSourceSwitch_" + modelData.id
                    checked: modelData.enabled
                    implicitHeight: Theme.hit
                    onToggled: if (settings.engine) settings.engine.setSourceEnabled(modelData.id, checked)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                Item { Layout.fillWidth: true }
                CarButton {
                    fontPixelSize: Theme.fontLabel
                    text: I18n.t("上移")
                    enabled: settings.engine !== null && index > 0
                    onClicked: if (settings.engine) settings.engine.moveSource(modelData.id, -1)
                }
                CarButton {
                    fontPixelSize: Theme.fontLabel
                    text: I18n.t("下移")
                    enabled: settings.engine !== null && index < settings.engine.sources.length - 1
                    onClicked: if (settings.engine) settings.engine.moveSource(modelData.id, 1)
                }
                CarButton {
                    fontPixelSize: Theme.fontLabel
                    objectName: "weatherProbe_" + modelData.id
                    text: settings.engine && settings.engine.probing
                          && settings.engine.probeSourceId === modelData.id ? I18n.t("测试中…") : I18n.t("测试")
                    enabled: settings.engine !== null && !settings.engine.probing
                    onClicked: if (settings.engine) settings.engine.probe(modelData.id)
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                Layout.topMargin: Theme.gap / 2
                visible: index < settings.engine.sources.length - 1
                color: Theme.outlineVariant
            }
        }
    }

                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: settings.section === 1
                        spacing: Theme.gap
    // ------------------------------------------------------------ OpenWeather

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.gap / 2
        CarField { plainHint: true
            id: openWeatherKeyField
            Layout.fillWidth: true
            placeholderText: settings.engine && settings.engine.openWeatherKey !== ""
                             ? I18n.t("已保存 Key（重新输入可覆盖）") : I18n.t("粘贴 OpenWeather API Key")
            echoMode: TextInput.Password
            // 只在「点输入框」时请求键盘：跟随焦点变化会在键盘关闭、焦点回弹时
            // 再次触发，表现为键盘关了又开、关不掉（TimeTools 踩过同一个坑）。
            MouseArea {
                anchors.fill: parent
                onClicked: { openWeatherKeyField.forceActiveFocus(); settings.keyboardRequested() }
            }
            onAccepted: {
                if (!settings.engine) return
                settings.engine.setOpenWeatherKey(text)
                settings.keyNotice = I18n.t("已保存")
                text = ""
            }
        }
        CarButton {
            text: I18n.t("保存")
            onClicked: {
                if (!settings.engine) return
                settings.engine.setOpenWeatherKey(openWeatherKeyField.text)
                openWeatherKeyField.text = ""
                settings.keyNotice = I18n.t("已保存")
            }
        }
    }
    CarText {
        Layout.fillWidth: true
        visible: settings.keyNotice !== ""
        subdued: true
        fontPixelSize: Theme.fontCaption
        text: I18n.t("Key 以明文保存在本机设置中，请勿在公共设备上填写。")
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.gap / 2
        CarText { Layout.fillWidth: true; text: I18n.t("接口版本") }
        CarButton {
            text: "One Call 3.0"
            checked: settings.engine && settings.engine.openWeatherMode === "onecall"
            onClicked: if (settings.engine) settings.engine.setOpenWeatherMode("onecall")
        }
        CarButton {
            text: "2.5"
            checked: settings.engine && settings.engine.openWeatherMode === "2.5"
            onClicked: if (settings.engine) settings.engine.setOpenWeatherMode("2.5")
        }
    }

                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: settings.section === 2
                        spacing: Theme.gap
    // ------------------------------------------------------------ 自定义 API

    CarField { plainHint: true
        id: customUrlField
        Layout.fillWidth: true
        placeholderText: "https://example.com/weather?lat={lat}&lon={lon}&key={key}"
        text: settings.engine ? settings.engine.customUrl : ""
        // 只在「点输入框」时请求键盘：跟随焦点变化会在键盘关闭、焦点回弹时
        // 再次触发，表现为键盘关了又开、关不掉（TimeTools 踩过同一个坑）。
        MouseArea {
            anchors.fill: parent
            onClicked: { customUrlField.forceActiveFocus(); settings.keyboardRequested() }
        }
        onEditingFinished: if (settings.engine) settings.engine.setCustomUrl(text)
    }
    // Key 只在 URL 模板里出现 {key} 时需要；形态与 OpenWeather Key 一致
    // （已保存时提示可覆盖、独立保存按钮、明文写清楚、只在点击时请求键盘）。
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.gap / 2
        CarField { plainHint: true
            id: customKeyField
            objectName: "weatherCustomKey"
            Layout.fillWidth: true
            placeholderText: settings.engine && settings.engine.customKey !== ""
                             ? I18n.t("已保存 Key（重新输入可覆盖）") : I18n.t("粘贴自定义 API Key（可选）")
            echoMode: TextInput.Password
            MouseArea {
                anchors.fill: parent
                onClicked: { customKeyField.forceActiveFocus(); settings.keyboardRequested() }
            }
            onAccepted: {
                if (!settings.engine) return
                settings.engine.setCustomKey(text)
                settings.customKeyNotice = I18n.t("已保存")
                text = ""
            }
        }
        CarButton {
            text: I18n.t("保存")
            onClicked: {
                if (!settings.engine) return
                settings.engine.setCustomKey(customKeyField.text)
                customKeyField.text = ""
                settings.customKeyNotice = I18n.t("已保存")
            }
        }
    }
    CarText {
        Layout.fillWidth: true
        visible: settings.customKeyNotice !== ""
        subdued: true
        fontPixelSize: Theme.fontCaption
        text: I18n.t("Key 以明文保存在本机设置中，请勿在公共设备上填写。")
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.gap / 2
        CarButton {
            text: settings.showMapping ? I18n.t("隐藏字段映射") : I18n.t("字段映射")
            checked: settings.showMapping
            onClicked: settings.showMapping = !settings.showMapping
        }
        CarButton {
            text: I18n.t("测试")
            enabled: settings.engine !== null && !settings.engine.probing
                    && settings.engine.customUrl !== ""
            onClicked: if (settings.engine) settings.engine.probe("custom")
        }
        CarText {
            Layout.fillWidth: true
            visible: settings.engine && settings.engine.probeSourceId === "custom"
                     && settings.engine.probeMessage !== ""
            fontPixelSize: Theme.fontCaption
            color: settings.engine && settings.engine.probeOk ? Theme.secondary : Theme.warning
            text: settings.engine ? settings.engine.probeMessage : ""
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
        }
    }
    ColumnLayout {
        Layout.fillWidth: true
        visible: settings.showMapping
        spacing: 2
        Repeater {
            model: settings.mappingFields
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarText {
                    Layout.preferredWidth: 110 * Theme.scaleFactor
                    fontPixelSize: Theme.fontCaption
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    text: modelData.label
                }
                CarField { plainHint: true
                    id: mappingField
                    Layout.fillWidth: true
                    font.pointSize: Theme.body
                    implicitHeight: Math.max(40, Theme.hit - 8)
                    placeholderText: modelData.hint
                    Component.onCompleted: text = settings.engine && settings.engine.customMapping[modelData.key]
                                             ? settings.engine.customMapping[modelData.key] : ""
                    // 只在「点输入框」时请求键盘：跟随焦点变化会在键盘关闭、焦点回弹时
                    // 再次触发，表现为键盘关了又开、关不掉（TimeTools 踩过同一个坑）。
                    MouseArea {
                        anchors.fill: parent
                        onClicked: { mappingField.forceActiveFocus(); settings.keyboardRequested() }
                    }
                    onEditingFinished: if (settings.engine) settings.engine.setCustomMappingField(modelData.key, text)
                }
            }
        }
    }

                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: settings.section === 3
                        spacing: Theme.gap
    // ------------------------------------------------------------ MET Norway

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.gap / 2
        CarField { plainHint: true
            id: contactField
            Layout.fillWidth: true
            placeholderText: I18n.t("联系邮箱（写进 User-Agent）")
            text: settings.engine ? settings.engine.metNoContact : ""
            // 只在「点输入框」时请求键盘：跟随焦点变化会在键盘关闭、焦点回弹时
            // 再次触发，表现为键盘关了又开、关不掉（TimeTools 踩过同一个坑）。
            MouseArea {
                anchors.fill: parent
                onClicked: { contactField.forceActiveFocus(); settings.keyboardRequested() }
            }
        }
        CarButton {
            text: I18n.t("保存")
            onClicked: {
                if (!settings.engine) return
                settings.engine.setMetNoContact(contactField.text)
                settings.contactNotice = I18n.t("已保存")
            }
        }
    }
    CarText {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        subdued: true
        fontPixelSize: Theme.fontCaption
        text: settings.contactNotice !== ""
              ? I18n.t("已保存")
              : I18n.t("MET Norway 要求请求头能识别应用并提供联系方式；留空时使用应用默认标识。")
    }

                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: settings.section === 4
                        spacing: Theme.gap
    // ------------------------------------------------------------ 刷新与单位

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.gap / 2
        CarText { Layout.fillWidth: true; text: I18n.t("自动刷新") }
        Repeater {
            model: [5, 15, 30, 60]
            delegate: CarButton {
                required property int modelData
                text: modelData + " " + I18n.t("分钟")
                checked: settings.engine && settings.engine.refreshMinutes === modelData
                onClicked: if (settings.engine) settings.engine.setRefreshMinutes(modelData)
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.gap / 2
        CarText { Layout.fillWidth: true; text: I18n.t("单位") }
        CarButton {
            text: I18n.t("公制 °C")
            checked: settings.engine && settings.engine.units === "metric"
            onClicked: if (settings.engine) settings.engine.setUnits("metric")
        }
        CarButton {
            text: I18n.t("英制 °F")
            checked: settings.engine && settings.engine.units === "imperial"
            onClicked: if (settings.engine) settings.engine.setUnits("imperial")
        }
    }
    CarText {
        Layout.fillWidth: true
        subdued: true
        fontPixelSize: Theme.fontCaption
        wrapMode: Text.Wrap
        text: I18n.t("风速随单位切换 km/h ↔ mph；数据来源：Open-Meteo（CC BY 4.0）、MET Norway（CC BY 4.0 / NLOD）、OpenWeather（CC BY-SA 4.0）。")
    }

                    }

                }
            }
        }
    }
}
