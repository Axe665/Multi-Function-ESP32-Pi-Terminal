import QtQuick
import "WeatherMath.js" as WeatherMath

// 天气状态拥有者：在 Main.qml 实例化一次。
// 页面（WeatherTools）与设置分区（WeatherSettings）读的是同一份地点、数据源与缓存。
//
// 边界（沿用时间功能的约定）：
// - 只负责网络请求、数据源降级、缓存与地点管理；不渲染、不建通知层、不改主题。
// - 四个内置源按"设置里的顺序"串成降级链：前一个失败（网络 / HTTP / 解析）自动换
//   下一个；全部失败时保留上次成功结果并标记 stale，绝不用默认值伪造天气。
// - 数据源开关、OpenWeather Key、自定义 API、刷新间隔、单位都走 SystemTools 的
//   "weather/" 前缀持久化；QML 不能直接写 QSettings，白名单在 SystemTools.cpp。
// - 内部一律公制（°C / km/h / mm），显示层再换算；四个解析器共用一套断言。

Item {
    id: engine

    // ---------------------------------------------------------------- 设置

    // 珠海是需求指定的默认地点；其余地点由用户搜索或手输经纬度添加。
    property var places: WeatherMath.defaultPlaces()
    property int placeIndex: 0
    property string units: "metric"                 // metric | imperial
    property int refreshMinutes: 15
    property var sources: WeatherMath.defaultSources()
    property string openWeatherKey: ""
    property string openWeatherMode: "onecall"      // onecall | 2.5
    property string customUrl: ""
    // 自定义源的 Key：只有模板里出现 {key} 时才需要。明文存 QSettings，
    // 与 OpenWeather Key 同一约定（设置页明确写清）。
    property string customKey: ""
    property var customMapping: ({})
    property string metNoContact: ""
    // 初值 true：QML 会在 Component.onCompleted 之前写属性，此间落盘会把默认值
    // 覆盖到磁盘上（时间功能踩过的坑），load() 结束才放开。
    property bool loadingSettings: true

    // ---------------------------------------------------------------- 运行态

    property var model: null           // 当前地点的最近一次成功结果（可能来自缓存）
    property bool loading: false       // 正在请求
    property bool stale: false         // model 来自缓存 / 上次失败
    property string error: ""          // 最近一次失败原因；成功后清空
    property string activeSource: ""   // 最近一次成功的源 id
    property bool active: false        // 页面是否在前台（控制自动刷新）
    // 与时间页的世界时钟同量级：8 个地点足够覆盖"家/公司/老家/出差"，再多页头切换就没法用了。
    readonly property int maxPlaces: 8
    property double lastAttemptAt: 0

    // 搜索（地理编码）与数据源探测各自独立的请求槽，互不打断。
    property bool searching: false
    property var searchResults: []
    property string searchError: ""
    property bool probing: false
    property string probeSourceId: ""
    property bool probeOk: false
    property string probeMessage: ""

    property var queue: []             // 本次刷新的降级链
    property int attempt: 0
    // 界面用的"当前时刻"：只有它变化，cacheExpired 的绑定才会重算。
    property double nowTick: Date.now()
    property var xhr: null
    property var searchXhr: null
    // 所有请求共用一个代次：刷新、探测、切换地点都会 ++generation，
    // 旧请求的回调看到代次不匹配就丢弃（TimeSync 的 token 同款做法）。
    property int generation: 0
    property int searchToken: 0

    signal searchFinished(var results)
    signal searchFailed(string message)
    signal probeFinished(string sourceId, bool ok, string message)

    readonly property var place: places.length > 0
                                  ? places[Math.max(0, Math.min(placeIndex, places.length - 1))]
                                  : null
    readonly property var current: model ? model.current : null
    readonly property var hourly: model ? model.hourly : []
    readonly property var daily: model ? model.daily : []
    readonly property bool hasData: model !== null && model.current !== null
    // 当前地点的本地偏移：优先用数据源返回值，其次用地点里存的（珠海默认 +8）。
    readonly property int utcOffsetSeconds: model
                                            ? model.utcOffsetSeconds
                                            : (place ? WeatherMath.num(place.utcOffsetSeconds) : 0)
    readonly property bool offsetApproximate: model ? model.offsetApproximate === true : true
    readonly property string attribution: WeatherMath.sourceAttribution(model ? model.source : activeSource)
    readonly property string sourceLabel: WeatherMath.sourceLabel(model ? model.source : activeSource)
    readonly property bool canRefresh: !loading
    readonly property bool hasUsableSource: enabledSourceIds().length > 0
    // 缓存已超过 6 小时：界面把「缓存 HH:MM」换成「缓存已过期 HH:MM」。
    // 只是标签变化——数据照常显示，不删、不伪造。
    readonly property bool cacheExpired: model !== null && WeatherMath.cacheExpired(model, nowTick)

    // ---------------------------------------------------------------- 设置读写

    function settingRead(key, fallback) {
        if (typeof systemTools === "undefined" || !systemTools ||
            typeof systemTools.settingsRead !== "function") return fallback
        return systemTools.settingsRead(key, fallback)
    }

    function settingWrite(key, value) {
        if (typeof systemTools === "undefined" || !systemTools ||
            typeof systemTools.settingsWrite !== "function") return false
        return systemTools.settingsWrite(key, value)
    }

    function parseJson(text, fallback) {
        try {
            const value = JSON.parse(text)
            return value === null || value === undefined ? fallback : value
        } catch (error) {
            return fallback
        }
    }

    function load() {
        loadingSettings = true
        const storedPlaces = parseJson(settingRead("weather/places", "[]"), [])
        if (Array.isArray(storedPlaces) && storedPlaces.length > 0)
            places = storedPlaces.map(WeatherMath.normalizePlace)
        else
            places = WeatherMath.defaultPlaces()
        if (places.length === 0) places = WeatherMath.defaultPlaces()
        placeIndex = WeatherMath.clamp(Number(settingRead("weather/placeIndex", "0")), 0, places.length - 1)
        units = WeatherMath.normalizeUnits(settingRead("weather/units", "metric"))
        refreshMinutes = WeatherMath.clamp(Number(settingRead("weather/refreshMinutes", "15")), 5, 120)
        sources = WeatherMath.normalizeSources(parseJson(settingRead("weather/sources", "null"), null))
        openWeatherKey = settingRead("weather/openweather.key", "")
        openWeatherMode = settingRead("weather/openweather.mode", "onecall") === "2.5" ? "2.5" : "onecall"
        customUrl = settingRead("weather/custom.url", "")
        customKey = settingRead("weather/custom.key", "")
        customMapping = parseJson(settingRead("weather/custom.mapping", "{}"), {})
        metNoContact = settingRead("weather/metno.contact", "")
        loadingSettings = false
        applyCacheForPlace()
    }

    function persistPlaces() {
        if (loadingSettings) return
        settingWrite("weather/places", JSON.stringify(places))
        settingWrite("weather/placeIndex", String(placeIndex))
    }

    function persistSources() {
        if (loadingSettings) return
        settingWrite("weather/sources", JSON.stringify(sources))
    }

    function setUnits(value) {
        units = WeatherMath.normalizeUnits(value)
        if (!loadingSettings) settingWrite("weather/units", units)
    }

    function setRefreshMinutes(value) {
        refreshMinutes = WeatherMath.clamp(Number(value), 5, 120)
        if (!loadingSettings) settingWrite("weather/refreshMinutes", String(refreshMinutes))
    }

    function setSourceEnabled(id, enabled) {
        const next = []
        for (let i = 0; i < sources.length; ++i)
            next.push({ id: sources[i].id, enabled: sources[i].id === id ? enabled === true : sources[i].enabled })
        sources = next
        persistSources()
    }

    // 设置页的上下箭头：只改顺序，不启用/停用。
    function moveSource(id, delta) {
        let index = -1
        for (let i = 0; i < sources.length; ++i) if (sources[i].id === id) index = i
        const target = index + delta
        if (index < 0 || target < 0 || target >= sources.length) return
        const copy = sources.slice()
        const moved = copy.splice(index, 1)[0]
        copy.splice(target, 0, moved)
        sources = copy
        persistSources()
    }

    function setOpenWeatherKey(value) {
        openWeatherKey = String(value || "")
        if (!loadingSettings) settingWrite("weather/openweather.key", openWeatherKey)
    }

    function setOpenWeatherMode(value) {
        openWeatherMode = String(value) === "2.5" ? "2.5" : "onecall"
        if (!loadingSettings) settingWrite("weather/openweather.mode", openWeatherMode)
    }

    function setCustomUrl(value) {
        customUrl = String(value || "")
        if (!loadingSettings) settingWrite("weather/custom.url", customUrl)
    }

    function setCustomKey(value) {
        customKey = String(value || "")
        if (!loadingSettings) settingWrite("weather/custom.key", customKey)
    }

    function setCustomMappingField(field, value) {
        const next = {}
        for (const key in customMapping) next[key] = customMapping[key]
        next[field] = String(value || "")
        customMapping = next
        if (!loadingSettings) settingWrite("weather/custom.mapping", JSON.stringify(customMapping))
    }

    function setMetNoContact(value) {
        metNoContact = String(value || "")
        if (!loadingSettings) settingWrite("weather/metno.contact", metNoContact)
    }

    // ---------------------------------------------------------------- 地点

    function setPlaceIndex(index) {
        if (places.length === 0) return
        const next = WeatherMath.clamp(index, 0, places.length - 1)
        if (next === placeIndex && model !== null) return
        placeIndex = next
        persistPlaces()
        applyCacheForPlace()
        if (active) refresh()
    }

    function addPlace(record) {
        const place = WeatherMath.normalizePlace(record)
        if (place.name === "" || !isFinite(place.lat) || !isFinite(place.lon)) return false
        for (let i = 0; i < places.length; ++i) {
            if (WeatherMath.placeKey(places[i]) === WeatherMath.placeKey(place)) {
                setPlaceIndex(i)
                return true
            }
        }
        if (places.length >= maxPlaces) return false
        places = places.concat([place])
        placeIndex = places.length - 1
        persistPlaces()
        placesChanged()
        applyCacheForPlace()
        if (active) refresh()
        return true
    }

    function removePlace(index) {
        if (index < 0 || index >= places.length || places.length <= 1) return false
        const copy = places.slice()
        copy.splice(index, 1)
        places = copy
        placeIndex = WeatherMath.clamp(placeIndex > index ? placeIndex - 1 : placeIndex, 0, places.length - 1)
        persistPlaces()
        placesChanged()
        applyCacheForPlace()
        return true
    }

    function shiftPlace(delta) {
        if (places.length === 0) return
        setPlaceIndex((placeIndex + delta + places.length) % places.length)
    }

    // 远端返回的时区偏移比地点里存的更新（例如夏令时），顺手写回地点，
    // 这样 MET Norway 这类不返回时区的源也能显示正确当地时间。
    function adoptOffset(next) {
        if (!next || places.length === 0) return
        const index = placeIndex
        if (index < 0 || index >= places.length) return
        const offset = Math.round(WeatherMath.num(next.utcOffsetSeconds))
        if (Math.abs(offset) > 18 * 3600) return
        if (Math.round(WeatherMath.num(places[index].utcOffsetSeconds)) === offset) return
        const copy = places.slice()
        copy[index] = WeatherMath.normalizePlace({
            name: places[index].name, admin: places[index].admin, country: places[index].country,
            lat: places[index].lat, lon: places[index].lon, utcOffsetSeconds: offset
        })
        places = copy
        persistPlaces()
    }

    // ---------------------------------------------------------------- 缓存

    function cacheKey() {
        return place ? "weather/cache/" + WeatherMath.placeKey(place) : ""
    }

    function applyCacheForPlace() {
        const key = cacheKey()
        const cached = key === "" ? null : WeatherMath.unpackCache(settingRead(key, ""))
        model = cached
        activeSource = cached ? String(cached.source || "") : ""
        stale = cached !== null
        error = ""
    }

    function storeCache(next) {
        const key = cacheKey()
        if (key === "") return
        const packed = WeatherMath.packCache(next)
        if (packed !== "") settingWrite(key, packed)
    }

    // ---------------------------------------------------------------- 联网门控

    // 发外网请求前的统一判定：走 NetworkGate::allow()，与浏览器/音乐/校时同一个
    // 策略点（Purpose::Weather），总开关或「天气联网」关闭时一律拒绝。
    // 单元测试环境没有 networkGate 这个上下文属性，按放行处理。
    function networkAllowed() {
        if (typeof networkGate === "undefined" || !networkGate) return true
        if (typeof networkGate.allow !== "function") return networkGate.enabled !== false
        return networkGate.allow("weather") === true
    }

    // ---------------------------------------------------------------- 刷新

    function enabledSourceIds() {
        const out = []
        for (let i = 0; i < sources.length; ++i) {
            const id = sources[i].id
            if (!sources[i].enabled) continue
            if (id === "openweather" && openWeatherKey === "") continue
            if (id === "custom") {
                if (customUrl === "") continue
                // 模板写了 {key} 却没填 Key：按"未配置"跳过，不拿空值去请求上游。
                if (WeatherMath.customUrlNeedsKey(customUrl) && customKey === "") continue
            }
            out.push(id)
        }
        return out
    }

    function cancelRequests() {
        generation++
        loading = false
        probing = false
        queue = []
        attempt = 0
    }

    function refresh() {
        if (loading) return
        cancelRequests()
        // 联网总开关关着：一个请求都不发，保留现有数据并如实说明原因。
        if (!networkAllowed()) {
            loading = false
            stale = model !== null
            error = I18n.t("联网已关闭")
            return
        }
        const chain = enabledSourceIds()
        lastAttemptAt = Date.now()
        error = ""
        if (chain.length === 0) {
            error = I18n.t("没有可用的数据源，请到设置里启用或配置")
            stale = model !== null
            return
        }
        queue = chain
        loading = true
        nextAttempt()
    }

    function nextAttempt() {
        if (attempt >= queue.length) {
            loading = false
            stale = model !== null
            if (error === "") error = I18n.t("所有数据源都不可用")
            else error = I18n.t("所有数据源均不可用") + " " + error
            return
        }
        const id = queue[attempt++]
        probeSourceId = id
        dispatch(id, false)
    }

    function requestJson(url, headers, capture, onOk, onError) {
        const request = new XMLHttpRequest()
        xhr = request
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE) return
            if (capture !== generation) return
            if (request.status < 200 || request.status >= 300) {
                onError(request.status === 0 ? I18n.t("网络不可用或服务不可达") : ("HTTP " + request.status))
                return
            }
            let parsed = null
            try {
                parsed = JSON.parse(request.responseText)
            } catch (parseError) {
                onError(I18n.t("数据格式无效"))
                return
            }
            onOk(parsed)
        }
        request.ontimeout = function() {
            if (capture === generation) onError(I18n.t("请求超时"))
        }
        request.open("GET", url)
        request.timeout = 15000
        if (headers) {
            for (const name in headers) {
                try { request.setRequestHeader(name, headers[name]) } catch (headerError) {}
            }
        }
        request.send()
    }

    // probe=true 时只更新设置页的探测结果，不覆盖页面上的 model。
    function dispatch(id, probe) {
        const capture = generation
        const now = Date.now()
        if (id === "open-meteo") {
            requestJson(WeatherMath.buildOpenMeteoUrl(place), null, capture, function(json) {
                finish(WeatherMath.parseOpenMeteo(json, now), probe, capture)
            }, function(message) { failed(id, message, probe, capture) })
            return
        }
        if (id === "met-no") {
            requestJson(WeatherMath.buildMetNoUrl(place),
                        { "User-Agent": WeatherMath.metNoUserAgent(metNoContact) },
                        capture, function(json) {
                finish(WeatherMath.parseMetNo(json, now, place ? place.utcOffsetSeconds : 0), probe, capture)
            }, function(message) { failed(id, message, probe, capture) })
            return
        }
        if (id === "custom") {
            const url = WeatherMath.buildCustomUrl(customUrl, place, customKey, "zh")
            requestJson(url, null, capture, function(json) {
                finish(WeatherMath.parseCustom(json, customMapping, now,
                                               place ? place.utcOffsetSeconds : 0), probe, capture)
            }, function(message) { failed(id, message, probe, capture) })
            return
        }
        if (id === "openweather") {
            const urls = WeatherMath.buildOpenWeatherUrls(place, openWeatherKey, openWeatherMode, "zh")
            if (openWeatherMode === "2.5" && urls.length === 2) {
                requestJson(urls[0], null, capture, function(currentJson) {
                    const partial = WeatherMath.parseOpenWeatherCurrent(currentJson, now)
                    requestJson(urls[1], null, generation, function(forecastJson) {
                        finish(WeatherMath.parseOpenWeatherForecast(forecastJson, partial, now), probe, capture)
                    }, function(message) { failed(id, message, probe, capture) })
                }, function(message) { failed(id, message, probe, capture) })
                return
            }
            requestJson(urls[0], null, capture, function(json) {
                finish(WeatherMath.parseOpenWeatherOneCall(json, now), probe, capture)
            }, function(message) { failed(id, message, probe, capture) })
            return
        }
        failed(id, I18n.t("未知数据源"), probe, capture)
    }

    function finish(next, probe, capture) {
        if (capture !== generation) return
        if (!next || !next.current || !isFinite(WeatherMath.num(next.current.t))) {
            failed(probeSourceId, I18n.t("数据格式无效"), probe, capture)
            return
        }
        next.place = place
        next.source = probeSourceId
        if (probe) {
            probing = false
            probeOk = true
            probeMessage = I18n.t("可用") + " " + WeatherMath.tempWithUnit(next.current.temp, units)
            probeFinished(probeSourceId, true, probeMessage)
            return
        }
        model = next
        activeSource = probeSourceId
        stale = false
        error = ""
        loading = false
        adoptOffset(next)
        storeCache(next)
    }

    function failed(id, message, probe, capture) {
        if (capture !== generation) return
        if (probe) {
            probing = false
            probeOk = false
            probeMessage = message
            probeFinished(id, false, message)
            return
        }
        error = WeatherMath.sourceLabel(id) + " " + message
        nextAttempt()
    }

    // 设置页的"测试"：允许测试未启用的源（例如刚填完 Key）。
    // 会取消进行中的刷新，避免两个请求互相覆盖 model。
    function probe(id) {
        if (probing) return
        cancelRequests()
        probeSourceId = id
        probeOk = false
        probeMessage = ""
        if (!networkAllowed()) {
            probeMessage = I18n.t("联网已关闭")
            probeFinished(id, false, probeMessage)
            return
        }
        probing = true
        dispatch(id, true)
    }

    // ---------------------------------------------------------------- 城市搜索

    function search(query) {
        const text = String(query || "").trim()
        if (text === "") return
        if (!networkAllowed()) {
            searching = false
            searchError = I18n.t("联网已关闭")
            searchFailed(searchError)
            return
        }
        searching = true
        searchError = ""
        searchResults = []
        searchToken++
        const capture = searchToken
        const request = new XMLHttpRequest()
        searchXhr = request
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE) return
            if (capture !== searchToken) return
            searching = false
            if (request.status < 200 || request.status >= 300) {
                searchError = request.status === 0 ? I18n.t("网络不可用或服务不可达")
                                                   : ("HTTP " + request.status)
                searchFailed(searchError)
                return
            }
            let json = null
            try { json = JSON.parse(request.responseText) } catch (error) {
                searchError = I18n.t("数据格式无效")
                searchFailed(searchError)
                return
            }
            searchResults = WeatherMath.parseGeocoding(json)
            if (searchResults.length === 0) searchError = I18n.t("没有找到匹配的地点")
            searchFinished(searchResults)
        }
        request.ontimeout = function() {
            if (capture !== searchToken) return
            searching = false
            searchError = I18n.t("请求超时")
            searchFailed(searchError)
        }
        request.open("GET", WeatherMath.buildGeocodingUrl(text, "zh"))
        request.timeout = 12000
        request.send()
    }

    function clearSearch() {
        searchToken++
        searching = false
        searchResults = []
        searchError = ""
    }

    // ---------------------------------------------------------------- 自动刷新

    onActiveChanged: {
        if (!active) return
        nowTick = Date.now()
        const age = model ? Date.now() - WeatherMath.num(model.fetchedAt) : Infinity
        if (!model || age > refreshMinutes * 60000) refresh()
    }

    Timer {
        // 页面在前台时每分钟走一次，让「缓存已过期」的判定跟着时间推移生效
        // （不加这个，标签会在页面打开的瞬间定住，跨过 6 小时也不会变）。
        interval: 60000
        repeat: true
        running: engine.active
        onTriggered: engine.nowTick = Date.now()
    }

    Timer {
        // 只在页面可见且没有请求在飞时跑；间隔在触发时读取，改设置立即生效。
        interval: Math.max(5, engine.refreshMinutes) * 60000
        repeat: true
        running: engine.active && !engine.loading
        onTriggered: engine.refresh()
    }

    Component.onCompleted: load()
}
