.pragma library

// 天气页的纯函数层：数据源 URL、响应归一化、WMO 码映射、时间/单位换算、缓存编解码。
//
// 与 TimeMath.js 一样，这个文件不引用任何 Qt/QML 类型：
// pi_terminal/tests/weather_math_test.cjs 用 Node 直接执行同一份文件，
// 所以线上跑的就是被测的代码。保持 ES5.1 + let/const/箭头函数可用的子集，
// 不要用 Intl、可选链、Array.prototype.at —— Qt 6.4 的 V4 引擎没有这些。
//
// 单位约定：内部一律公制（°C、km/h、mm、hPa），只在显示层换算。
// 这样四个数据源的解析器共用同一条窄口径，测试也只需要一套期望值。

// ---------------------------------------------------------------- 基础工具

function num(value, fallback) {
    var n = Number(value);
    if (!isFinite(n)) return fallback === undefined ? 0 : fallback;
    return n;
}

function round1(value) {
    return Math.round(num(value) * 10) / 10;
}

function clamp(value, minimum, maximum) {
    var n = num(value);
    return n < minimum ? minimum : (n > maximum ? maximum : n);
}

function pad2(value) {
    var n = Math.floor(Math.abs(num(value)));
    return n < 10 ? "0" + n : String(n);
}

function isFiniteNumber(value) {
    return typeof value === "number" && isFinite(value);
}

// ---------------------------------------------------------------- WMO 天气码

// WMO 4677 的 0–99 段。只归并到界面上真正会区分的 9 类，
// 太细的码（冻雨、米雪）在播报里没有独立价值，归到最近的母类。
function wmoCategory(code) {
    var c = Math.round(num(code, -1));
    if (c === 0 || c === 1) return "clear";
    if (c === 2) return "partly";
    if (c === 3) return "cloudy";
    if (c === 45 || c === 48) return "fog";
    if (c >= 51 && c <= 57) return "drizzle";
    if (c >= 61 && c <= 67) return "rain";
    if (c >= 71 && c <= 77) return "snow";
    if (c >= 80 && c <= 82) return "showers";
    if (c === 85 || c === 86) return "snow";
    if (c >= 95) return "thunder";
    return "unknown";
}

// 返回中文母类；UI 再套 I18n.t() 翻译，英文词条只维护这 10 条。
function wmoText(code) {
    switch (wmoCategory(code)) {
    // 全部用两字词，避免 I18n.t() 的单字替换误伤其它文案（例如「雨」命中「降雨」）。
    case "clear": return "晴朗";
    case "partly": return "多云";
    case "cloudy": return "阴天";
    case "fog": return "有雾";
    case "drizzle": return "毛毛雨";
    case "rain": return "降雨";
    case "showers": return "阵雨";
    case "snow": return "降雪";
    case "thunder": return "雷雨";
    default: return "未知";
    }
}

function wmoIcon(code, isDay) {
    switch (wmoCategory(code)) {
    case "clear": return isDay === false ? "nights_stay" : "wb_sunny";
    case "partly": return "wb_cloudy";
    case "cloudy": return "cloud";
    case "fog": return "dehaze";
    case "drizzle": return "grain";
    case "rain": return "grain";
    case "showers": return "grain";
    case "snow": return "ac_unit";
    case "thunder": return "thunderstorm";
    default: return "cloud";
    }
}

// OpenWeather condition id → WMO。范围表来自其官方文档的 2xx/3xx/5xx/6xx/7xx/800/80x。
function owmToWmo(id) {
    var c = Math.round(num(id, -1));
    if (c >= 200 && c < 300) return 95;
    if (c >= 300 && c < 400) return 53;
    if (c === 511) return 66;
    if (c === 500) return 61;
    if (c === 501) return 63;
    if (c >= 502 && c <= 504) return 65;
    if (c >= 520 && c < 600) return 80;
    if (c >= 600 && c < 700) return 73;
    if (c >= 700 && c < 800) return 45;
    if (c === 800) return 0;
    if (c === 801) return 1;
    if (c === 802) return 2;
    if (c >= 803) return 3;
    return -1;
}

// MET Norway 的 symbol_code 是 "clearsky_day" / "lightrainandthunder" 这类复合词。
function metNoToWmo(symbol) {
    var s = String(symbol || "").toLowerCase();
    if (s === "") return -1;
    if (s.indexOf("thunder") >= 0) return 95;
    if (s.indexOf("sleet") >= 0) return 66;
    if (s.indexOf("snow") >= 0) return 73;
    if (s.indexOf("drizzle") >= 0) return 53;
    if (s.indexOf("rain") >= 0) {
        if (s.indexOf("heavy") >= 0) return 65;
        if (s.indexOf("light") >= 0) return 61;
        return 63;
    }
    if (s.indexOf("fog") >= 0) return 45;
    if (s.indexOf("partlycloudy") >= 0) return 2;
    if (s.indexOf("cloudy") >= 0) return 3;
    if (s.indexOf("fair") >= 0) return 1;
    if (s.indexOf("clearsky") >= 0) return 0;
    return 3;
}

function metNoIsDay(symbol) {
    return String(symbol || "").indexOf("_night") < 0;
}

// 八方位中文；UI 用 I18n.t() 翻译。
function windDirText(degrees) {
    var names = ["北风", "东北风", "东风", "东南风", "南风", "西南风", "西风", "西北风"];
    var d = num(degrees) % 360;
    if (d < 0) d += 360;
    return names[Math.round(d / 45) % 8];
}

// ---------------------------------------------------------------- 单位换算

function normalizeUnits(units) {
    return String(units) === "imperial" ? "imperial" : "metric";
}

function tempValue(celsius, units) {
    return normalizeUnits(units) === "imperial" ? num(celsius) * 9 / 5 + 32 : num(celsius);
}

function windValue(kmh, units) {
    return normalizeUnits(units) === "imperial" ? num(kmh) / 1.609344 : num(kmh);
}

function precipValue(mm, units) {
    return normalizeUnits(units) === "imperial" ? num(mm) / 25.4 : num(mm);
}

function tempText(celsius, units) {
    return Math.round(tempValue(celsius, units)) + "°";
}

function tempWithUnit(celsius, units) {
    return tempText(celsius, units) + (normalizeUnits(units) === "imperial" ? "F" : "C");
}

function windText(kmh, units) {
    return Math.round(windValue(kmh, units)) + " " + (normalizeUnits(units) === "imperial" ? "mph" : "km/h");
}

function precipText(mm, units) {
    var v = precipValue(mm, units);
    var text = v >= 10 ? String(Math.round(v)) : String(Math.round(v * 10) / 10);
    return text + " " + (normalizeUnits(units) === "imperial" ? "in" : "mm");
}

// 大号温度只显示数字，单位单独一个小字；这样 3 位数（-10 / 100）也不会换行。
function tempNumberText(celsius, units) {
    return String(Math.round(tempValue(celsius, units)));
}

// ---------------------------------------------------------------- 地点

function defaultPlaces() {
    // 需求指定：珠海做默认地点。经纬度取市区（香洲），时区固定 UTC+8，
    // 这样即使第一个数据源是 MET Norway（不返回时区）也能正确显示当地时间。
    return [{ name: "珠海", admin: "广东", country: "中国", lat: 22.2707, lon: 113.5767, utcOffsetSeconds: 28800 }];
}

function normalizePlace(record) {
    var r = record || {};
    var lat = clamp(num(r.lat), -90, 90);
    var lon = clamp(num(r.lon), -180, 180);
    return {
        name: String(r.name || "").slice(0, 32) || (lat.toFixed(2) + ", " + lon.toFixed(2)),
        admin: String(r.admin || "").slice(0, 32),
        country: String(r.country || "").slice(0, 32),
        lat: lat,
        lon: lon,
        utcOffsetSeconds: Math.round(num(r.utcOffsetSeconds))
    };
}

function placeKey(place) {
    var p = normalizePlace(place);
    return p.lat.toFixed(3) + "," + p.lon.toFixed(3);
}

function placeLabel(place) {
    var p = normalizePlace(place);
    var tail = p.admin !== "" ? p.admin : p.country;
    return tail === "" ? p.name : p.name + " " + tail;
}

// ---------------------------------------------------------------- 时间

// Open-Meteo 的 time 是"地点本地时间且不带偏移"的 ISO 字符串，例如 2026-10-28T14:00。
// 先当 UTC 解析，再减掉地点偏移，得到真正的 UTC 毫秒。
function parseLocalIso(text, offsetSeconds) {
    var s = String(text || "");
    if (s === "") return NaN;
    if (s.charAt(s.length - 1) !== "Z") s += "Z";
    var ms = Date.parse(s);
    if (!isFinite(ms)) return NaN;
    return ms - num(offsetSeconds) * 1000;
}

// 接受 unix 秒、unix 毫秒、ISO（含 Z 或 ±HH:MM）。
function toEpochMs(value) {
    if (typeof value === "number") return value > 100000000000 ? value : value * 1000;
    var s = String(value || "");
    if (s === "") return NaN;
    if (/^-?[0-9]+$/.test(s)) return toEpochMs(Number(s));
    var ms = Date.parse(s);
    return isFinite(ms) ? ms : NaN;
}

// 把某一时刻按"地点本地时间"拆开：先用偏移平移，再统一读 UTC 字段。
// 这样不依赖设备时区，也不会被设备时区带偏。
function dateParts(epochMs, offsetSeconds) {
    var d = new Date(num(epochMs) + num(offsetSeconds) * 1000);
    return {
        year: d.getUTCFullYear(),
        month: d.getUTCMonth() + 1,
        day: d.getUTCDate(),
        hour: d.getUTCHours(),
        minute: d.getUTCMinutes(),
        second: d.getUTCSeconds(),
        weekday: d.getUTCDay()
    };
}

function formatHm(epochMs, offsetSeconds) {
    var p = dateParts(epochMs, offsetSeconds);
    return pad2(p.hour) + ":" + pad2(p.minute);
}

function formatMonthDay(epochMs, offsetSeconds) {
    var p = dateParts(epochMs, offsetSeconds);
    return p.month + "/" + p.day;
}

function formatWeekday(epochMs, offsetSeconds) {
    var names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
    return names[dateParts(epochMs, offsetSeconds).weekday % 7];
}

function formatDayLabel(epochMs, offsetSeconds, nowMs) {
    var p = dateParts(epochMs, offsetSeconds);
    var n = dateParts(nowMs, offsetSeconds);
    if (p.year === n.year && p.month === n.month && p.day === n.day) return "今天";
    if (p.year === n.year && p.month === n.month && p.day === n.day + 1) return "明天";
    return formatWeekday(epochMs, offsetSeconds);
}

// 地点本地日的中午（用于逐日数据排序/显示，避开 00:00 的时区边界）。
function localNoonEpoch(epochMs, offsetSeconds) {
    var p = dateParts(epochMs, offsetSeconds);
    return Date.UTC(p.year, p.month - 1, p.day, 12, 0, 0) - num(offsetSeconds) * 1000;
}

function localDayKey(epochMs, offsetSeconds) {
    var p = dateParts(epochMs, offsetSeconds);
    return p.year + "-" + pad2(p.month) + "-" + pad2(p.day);
}

function isDayTime(epochMs, offsetSeconds) {
    var hour = dateParts(epochMs, offsetSeconds).hour;
    return hour >= 6 && hour < 18;
}

// ---------------------------------------------------------------- URL 构造

function buildOpenMeteoUrl(place) {
    var p = normalizePlace(place);
    return "https://api.open-meteo.com/v1/forecast"
        + "?latitude=" + p.lat.toFixed(4) + "&longitude=" + p.lon.toFixed(4)
        + "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,"
        + "wind_direction_10m,relative_humidity_2m,is_day,precipitation_probability"
        + "&hourly=temperature_2m,weather_code,precipitation_probability,precipitation,wind_speed_10m"
        + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
        + "&timezone=auto&forecast_days=7&forecast_hours=24"
        + "&temperature_unit=celsius&wind_speed_unit=kmh&precipitation_unit=mm";
}

// OpenWeather 两种版本：onecall 一次给全；2.5 需要 weather + forecast 两个请求。
function buildOpenWeatherUrls(place, key, mode, lang) {
    var p = normalizePlace(place);
    var query = "lat=" + p.lat + "&lon=" + p.lon
        + "&units=metric&lang=" + (String(lang) === "en" ? "en" : "zh_cn")
        + "&appid=" + encodeURIComponent(String(key || ""));
    if (String(mode) === "2.5") {
        return ["https://api.openweathermap.org/data/2.5/weather?" + query,
                "https://api.openweathermap.org/data/2.5/forecast?" + query];
    }
    return ["https://api.openweathermap.org/data/3.0/onecall?" + query + "&exclude=minutely,alerts"];
}

function buildMetNoUrl(place) {
    var p = normalizePlace(place);
    return "https://api.met.no/weatherapi/locationforecast/2.0/compact"
        + "?lat=" + p.lat.toFixed(4) + "&lon=" + p.lon.toFixed(4);
}

// MET Norway 要求 User-Agent 能识别应用；联系方式由设置页补充。
function metNoUserAgent(contact) {
    var tail = String(contact || "").trim();
    return "OrangePiTerminal/1.0 (weather module"
        + (tail === "" ? "; +https://github.com/Axe665/Multi-Function-ESP32-Pi-Terminal" : "; " + tail)
        + ")";
}

function buildGeocodingUrl(query, lang) {
    return "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(String(query || ""))
        + "&count=8&language=" + (String(lang) === "en" ? "en" : "zh") + "&format=json";
}

// 自定义源的 URL 模板：{lat} {lon} {name} {key} {units} {lang}。
// 未替换的占位符原样保留，配合设置页的"测试"按钮能立刻看出漏配。
function buildCustomUrl(template, place, key, lang) {
    var p = normalizePlace(place);
    return String(template || "")
        .split("{lat}").join(String(p.lat))
        .split("{lon}").join(String(p.lon))
        .split("{name}").join(encodeURIComponent(p.name))
        .split("{key}").join(encodeURIComponent(String(key || "")))
        .split("{units}").join("metric")
        .split("{lang}").join(String(lang || "zh"));
}

// 模板是否要求密钥。要求了但没填，就在降级链里按"未配置"跳过——
// 与 OpenWeather 无 Key 时的处理一致，不拿空值去请求上游。
function customUrlNeedsKey(template) {
    return String(template || "").indexOf("{key}") >= 0;
}

// ---------------------------------------------------------------- 归一化结果

function emptyModel(source, place) {
    return {
        source: source || "",
        place: place || null,
        fetchedAt: 0,
        utcOffsetSeconds: place ? num(place.utcOffsetSeconds) : 0,
        current: null,
        hourly: [],
        daily: []
    };
}

// 从"现在"往后取 count 条；数据源给的序列可能从整点开始，
// 也可能已经过去一两个小时，统一裁掉明显过期的条目。
function takeHourly(rows, nowMs, count) {
    var limit = count || 24;
    var cutoff = num(nowMs) - 3600 * 1000;
    var out = [];
    for (var i = 0; i < rows.length && out.length < limit; ++i) {
        if (num(rows[i].t) >= cutoff) out.push(rows[i]);
    }
    if (out.length === 0) out = rows.slice(0, limit);
    return out;
}

// 把 3 小时 / 6 小时粒度的序列按地点本地日聚合成逐日。
function summarizeDays(rows, offsetSeconds, maxDays) {
    var order = [];
    var byKey = {};
    for (var i = 0; i < rows.length; ++i) {
        var row = rows[i];
        if (!isFinite(num(row.t))) continue;
        var key = localDayKey(row.t, offsetSeconds);
        var entry = byKey[key];
        if (!entry) {
            entry = byKey[key] = {
                t: localNoonEpoch(row.t, offsetSeconds),
                code: -1, max: -Infinity, min: Infinity, pop: -1,
                codeCount: {}, codeBest: 0
            };
            order.push(key);
        }
        entry.max = Math.max(entry.max, num(row.temp));
        entry.min = Math.min(entry.min, num(row.temp));
        if (isFiniteNumber(row.pop)) entry.pop = Math.max(entry.pop, num(row.pop));
        var code = Math.round(num(row.code, -1));
        if (code >= 0) {
            entry.codeCount[code] = (entry.codeCount[code] || 0) + 1;
            if (entry.codeCount[code] > entry.codeBest) {
                entry.codeBest = entry.codeCount[code];
                entry.code = code;
            }
        }
    }
    var out = [];
    for (var j = 0; j < order.length && out.length < (maxDays || 7); ++j) {
        var d = byKey[order[j]];
        out.push({
            t: d.t,
            code: d.code,
            max: isFinite(d.max) ? d.max : 0,
            min: isFinite(d.min) ? d.min : 0,
            pop: d.pop
        });
    }
    return out;
}

// ---------------------------------------------------------------- 解析：Open-Meteo

function parseOpenMeteo(json, nowMs) {
    var offset = num(json && json.utc_offset_seconds, 0);
    var c = (json && json.current) || {};
    var h = (json && json.hourly) || {};
    var d = (json && json.daily) || {};
    var model = emptyModel("open-meteo", null);
    model.utcOffsetSeconds = offset;
    model.current = {
        t: parseLocalIso(c.time, offset),
        temp: num(c.temperature_2m),
        apparent: num(c.apparent_temperature, num(c.temperature_2m)),
        code: num(c.weather_code, -1),
        wind: num(c.wind_speed_10m),
        windDir: num(c.wind_direction_10m),
        humidity: num(c.relative_humidity_2m),
        isDay: num(c.is_day, 1) === 1,
        pop: num(c.precipitation_probability, -1)
    };
    var times = h.time || [];
    var rows = [];
    for (var i = 0; i < times.length; ++i) {
        rows.push({
            t: parseLocalIso(times[i], offset),
            temp: num((h.temperature_2m || [])[i]),
            code: num((h.weather_code || [])[i], -1),
            pop: num((h.precipitation_probability || [])[i], -1),
            precip: num((h.precipitation || [])[i]),
            wind: num((h.wind_speed_10m || [])[i])
        });
    }
    model.hourly = takeHourly(rows, nowMs, 24);
    var dates = d.time || [];
    for (var j = 0; j < dates.length && model.daily.length < 7; ++j) {
        model.daily.push({
            t: parseLocalIso(String(dates[j]) + "T12:00", offset),
            code: num((d.weather_code || [])[j], -1),
            max: num((d.temperature_2m_max || [])[j]),
            min: num((d.temperature_2m_min || [])[j]),
            pop: num((d.precipitation_probability_max || [])[j], -1)
        });
    }
    model.fetchedAt = num(nowMs, Date.now());
    return model;
}

// ---------------------------------------------------------------- 解析：OpenWeather

function parseOpenWeatherOneCall(json, nowMs) {
    var offset = num(json && json.timezone_offset, 0);
    var c = (json && json.current) || {};
    var cw = ((c.weather || [])[0]) || {};
    var model = emptyModel("openweather", null);
    model.utcOffsetSeconds = offset;
    var sunrise = num(c.sunrise, NaN);
    var sunset = num(c.sunset, NaN);
    var t = num(c.dt) * 1000;
    model.current = {
        t: t,
        temp: num(c.temp),
        apparent: num(c.feels_like, num(c.temp)),
        code: owmToWmo(cw.id),
        wind: num(c.wind_speed) * 3.6,          // OpenWeather 公制风是 m/s
        windDir: num(c.wind_deg),
        humidity: num(c.humidity),
        isDay: isFinite(sunrise) && isFinite(sunset) ? (t >= sunrise * 1000 && t < sunset * 1000)
                                                     : isDayTime(t, offset),
        pop: num(c.pop, -1) * 100
    };
    var hours = json.hourly || [];
    var rows = [];
    for (var i = 0; i < hours.length; ++i) {
        var hour = hours[i] || {};
        var hw = ((hour.weather || [])[0]) || {};
        rows.push({
            t: num(hour.dt) * 1000,
            temp: num(hour.temp),
            code: owmToWmo(hw.id),
            pop: num(hour.pop, -1) * 100,
            precip: num((hour.rain || {})["1h"]),
            wind: num(hour.wind_speed) * 3.6
        });
    }
    model.hourly = takeHourly(rows, nowMs, 24);
    var days = json.daily || [];
    for (var j = 0; j < days.length && model.daily.length < 7; ++j) {
        var day = days[j] || {};
        var dw = ((day.weather || [])[0]) || {};
        var temps = day.temp || {};
        model.daily.push({
            t: num(day.dt) * 1000,
            code: owmToWmo(dw.id),
            max: num(temps.max),
            min: num(temps.min),
            pop: num(day.pop, -1) * 100
        });
    }
    model.fetchedAt = num(nowMs, Date.now());
    return model;
}

function parseOpenWeatherCurrent(json, nowMs) {
    var offset = num(json && json.timezone, 0);
    var cw = ((json.weather || [])[0]) || {};
    var model = emptyModel("openweather", null);
    model.utcOffsetSeconds = offset;
    var t = num(json && json.dt) * 1000;
    model.current = {
        t: t,
        temp: num(json && json.main && json.main.temp),
        apparent: num(json && json.main && json.main.feels_like, num(json && json.main && json.main.temp)),
        code: owmToWmo(cw.id),
        wind: num(json && json.wind && json.wind.speed) * 3.6,
        windDir: num(json && json.wind && json.wind.deg),
        humidity: num(json && json.main && json.main.humidity),
        isDay: isDayTime(t, offset),
        pop: -1
    };
    model.fetchedAt = num(nowMs, Date.now());
    return model;
}

function parseOpenWeatherForecast(json, model, nowMs) {
    var offset = model ? num(model.utcOffsetSeconds) : 0;
    var list = (json && json.list) || [];
    var rows = [];
    for (var i = 0; i < list.length; ++i) {
        var item = list[i] || {};
        var w = ((item.weather || [])[0]) || {};
        rows.push({
            t: num(item.dt) * 1000,
            temp: num(item.main && item.main.temp),
            code: owmToWmo(w.id),
            pop: num(item.pop, -1) * 100,
            precip: num(item.rain && item.rain["3h"]),
            wind: num(item.wind && item.wind.speed) * 3.6
        });
    }
    if (!model) model = emptyModel("openweather", null);
    model.hourly = takeHourly(rows, nowMs, 24);
    model.daily = summarizeDays(rows, offset, 7);
    return model;
}

// ---------------------------------------------------------------- 解析：MET Norway

// MET Norway 不返回地点时区。优先用地点里存的 utcOffsetSeconds（默认珠海有值），
// 没有就退回设备时区；调用方通过 model.offsetApproximate 决定是否标注。
function parseMetNo(json, nowMs, fallbackOffsetSeconds) {
    var offset = num(fallbackOffsetSeconds, 0);
    var series = (json && json.properties && json.properties.timeseries) || [];
    var rows = [];
    for (var i = 0; i < series.length; ++i) {
        var item = series[i] || {};
        var data = item.data || {};
        var instant = (data.instant && data.instant.details) || {};
        var next1 = (data.next_1_hours && data.next_1_hours.details) || {};
        var next6 = (data.next_6_hours && data.next_6_hours.details) || {};
        var symbol = (data.next_1_hours && data.next_1_hours.summary && data.next_1_hours.summary.symbol_code)
            || (data.next_6_hours && data.next_6_hours.summary && data.next_6_hours.summary.symbol_code)
            || "";
        rows.push({
            t: toEpochMs(item.time),
            temp: num(instant.air_temperature),
            code: metNoToWmo(symbol),
            pop: -1,
            precip: num(next1.precipitation_amount, num(next6.precipitation_amount)),
            wind: num(instant.wind_speed) * 3.6,   // m/s → km/h
            windDir: num(instant.wind_from_direction),
            humidity: num(instant.relative_humidity),
            isDay: metNoIsDay(symbol)
        });
    }
    var model = emptyModel("met-no", null);
    model.utcOffsetSeconds = offset;
    model.offsetApproximate = true;
    if (rows.length > 0) {
        var first = rows[0];
        for (var k = 0; k < rows.length; ++k) {
            if (num(rows[k].t) <= num(nowMs)) first = rows[k];
            else break;
        }
        model.current = {
            t: first.t, temp: first.temp, apparent: first.temp, code: first.code,
            wind: first.wind, windDir: first.windDir, humidity: first.humidity,
            isDay: first.isDay, pop: -1
        };
    }
    model.hourly = takeHourly(rows, nowMs, 24);
    model.daily = summarizeDays(rows, offset, 7);
    model.fetchedAt = num(nowMs, Date.now());
    return model;
}

// ---------------------------------------------------------------- 解析：地理编码

function parseGeocoding(json) {
    var results = (json && json.results) || [];
    var out = [];
    for (var i = 0; i < results.length && out.length < 8; ++i) {
        var r = results[i] || {};
        out.push(normalizePlace({
            name: r.name,
            admin: r.admin1 || "",
            country: r.country || "",
            lat: r.latitude,
            lon: r.longitude,
            utcOffsetSeconds: 0
        }));
    }
    return out;
}

// ---------------------------------------------------------------- 解析：自定义

function getPath(object, path) {
    if (!object || !path) return undefined;
    var parts = String(path).split(".");
    var node = object;
    for (var i = 0; i < parts.length; ++i) {
        if (node === null || node === undefined) return undefined;
        var key = parts[i];
        if (Array.isArray(node) && /^[0-9]+$/.test(key)) node = node[Number(key)];
        else node = node[key];
    }
    return node;
}

// 自定义源：mapping 为空时按 Open-Meteo 兼容响应解析（"只改 base URL"模式）；
// 否则按字段路径逐项取值。数组字段写成 "hourly.time" 这种点路径。
function parseCustom(json, mapping, nowMs, fallbackOffsetSeconds) {
    // 没有任何字段路径 = "Open-Meteo 兼容 base URL"模式；只要填了温度或逐小时路径
    // 就按字段映射解析，避免用户填了一半却被当成兼容模式。
    if (!mapping || (!mapping.currentTemp && !mapping.hourlyTime)) {
        var model = parseOpenMeteo(json, nowMs);
        model.source = "custom";
        if (!json || json.utc_offset_seconds === undefined) {
            model.utcOffsetSeconds = num(fallbackOffsetSeconds, 0);
            model.offsetApproximate = true;
        }
        for (var i = 0; i < model.hourly.length; ++i) {
            if (model.current && model.hourly[i].code < 0) model.hourly[i].code = model.current.code;
        }
        return model;
    }
    var offset = num(fallbackOffsetSeconds, 0);
    var out = emptyModel("custom", null);
    out.utcOffsetSeconds = offset;
    out.offsetApproximate = true;
    var currentTemp = getPath(json, mapping.currentTemp);
    out.current = {
        t: toEpochMs(getPath(json, mapping.currentTime)) || num(nowMs),
        temp: num(currentTemp),
        apparent: num(getPath(json, mapping.currentApparent), num(currentTemp)),
        code: num(getPath(json, mapping.currentCode), -1),
        wind: num(getPath(json, mapping.currentWind)),
        windDir: num(getPath(json, mapping.currentWindDir)),
        humidity: num(getPath(json, mapping.currentHumidity)),
        isDay: isDayTime(num(nowMs), offset),
        pop: num(getPath(json, mapping.currentPop), -1)
    };
    var hourTimes = getPath(json, mapping.hourlyTime) || [];
    var hourTemps = getPath(json, mapping.hourlyTemp) || [];
    var hourCodes = getPath(json, mapping.hourlyCode) || [];
    var hourPops = getPath(json, mapping.hourlyPop) || [];
    var rows = [];
    for (var h = 0; h < hourTimes.length; ++h) {
        rows.push({
            t: toEpochMs(hourTimes[h]),
            temp: num(hourTemps[h]),
            code: num(hourCodes[h], -1),
            pop: num(hourPops[h], -1),
            precip: 0,
            wind: 0
        });
    }
    out.hourly = takeHourly(rows, nowMs, 24);
    var dayTimes = getPath(json, mapping.dailyDate) || [];
    var dayMax = getPath(json, mapping.dailyMax) || [];
    var dayMin = getPath(json, mapping.dailyMin) || [];
    var dayCodes = getPath(json, mapping.dailyCode) || [];
    for (var d = 0; d < dayTimes.length && out.daily.length < 7; ++d) {
        out.daily.push({
            t: toEpochMs(dayTimes[d]),
            code: num(dayCodes[d], -1),
            max: num(dayMax[d]),
            min: num(dayMin[d]),
            pop: -1
        });
    }
    out.fetchedAt = num(nowMs, Date.now());
    return out;
}

// ---------------------------------------------------------------- 缓存

// 只缓存展示所需的紧凑数组，避免把整份原始 JSON 塞进 QSettings（单值上限 16 KB）。
function packCache(model) {
    if (!model || !model.current) return "";
    var c = model.current;
    var packed = {
        v: 1,
        s: String(model.source || ""),
        o: Math.round(num(model.utcOffsetSeconds)),
        a: model.offsetApproximate === true,
        f: Math.round(num(model.fetchedAt)),
        c: [Math.round(num(c.t)), round1(c.temp), round1(c.apparent), Math.round(num(c.code)),
            round1(c.wind), Math.round(num(c.windDir)), Math.round(num(c.humidity)),
            c.isDay === false ? 0 : 1, Math.round(num(c.pop))],
        h: [],
        d: []
    };
    for (var i = 0; i < model.hourly.length; ++i) {
        var h = model.hourly[i];
        packed.h.push([Math.round(num(h.t)), round1(h.temp), Math.round(num(h.code)),
                       Math.round(num(h.pop)), round1(num(h.precip)), round1(num(h.wind))]);
    }
    for (var j = 0; j < model.daily.length; ++j) {
        var d = model.daily[j];
        packed.d.push([Math.round(num(d.t)), Math.round(num(d.code)), round1(d.max), round1(d.min),
                       Math.round(num(d.pop))]);
    }
    try { return JSON.stringify(packed); } catch (error) { return ""; }
}

function unpackCache(text) {
    if (!text) return null;
    var raw = null;
    try { raw = JSON.parse(String(text)); } catch (error) { return null; }
    if (!raw || raw.v !== 1 || !raw.c || !isFinite(num(raw.c[0]))) return null;
    var model = emptyModel(String(raw.s || ""), null);
    model.utcOffsetSeconds = num(raw.o);
    model.offsetApproximate = raw.a === true;
    model.fetchedAt = num(raw.f);
    model.current = {
        t: num(raw.c[0]), temp: num(raw.c[1]), apparent: num(raw.c[2]), code: num(raw.c[3]),
        wind: num(raw.c[4]), windDir: num(raw.c[5]), humidity: num(raw.c[6]),
        isDay: num(raw.c[7]) === 1, pop: num(raw.c[8])
    };
    var hours = raw.h || [];
    for (var i = 0; i < hours.length; ++i) {
        model.hourly.push({
            t: num(hours[i][0]), temp: num(hours[i][1]), code: num(hours[i][2]),
            pop: num(hours[i][3]), precip: num(hours[i][4]), wind: num(hours[i][5])
        });
    }
    var days = raw.d || [];
    for (var j = 0; j < days.length; ++j) {
        model.daily.push({
            t: num(days[j][0]), code: num(days[j][1]),
            max: num(days[j][2]), min: num(days[j][3]), pop: num(days[j][4])
        });
    }
    return model;
}

// 缓存寿命：超过这个时长就只当"上次结果"展示，界面标注「缓存已过期」。
// 固定常量而不是设置项——多一个开关不值当，6 小时已写进 docs/weather.md。
var CACHE_TTL_MS = 6 * 60 * 60 * 1000;

// 距上次成功获取过去了多久（毫秒）。model 为空时返回 Infinity。
function cacheAgeMs(model, nowMs) {
    if (!model) return Infinity;
    return Math.max(0, num(nowMs) - num(model.fetchedAt));
}

// 缓存是否已过期。界面据此把「缓存 HH:MM」换成「缓存已过期 HH:MM」。
function cacheExpired(model, nowMs) {
    return cacheAgeMs(model, nowMs) > CACHE_TTL_MS;
}

// ---------------------------------------------------------------- 数据源描述

// 顺序即降级顺序：前一个失败自动换下一个。enabled 由设置页控制。
function defaultSources() {
    return [
        { id: "open-meteo", enabled: true },
        { id: "met-no", enabled: true },
        { id: "openweather", enabled: false },
        { id: "custom", enabled: false }
    ];
}

function normalizeSources(list) {
    var known = { "open-meteo": true, "met-no": true, "openweather": true, "custom": true };
    var out = [];
    var seen = {};
    if (Array.isArray(list)) {
        for (var i = 0; i < list.length; ++i) {
            var item = list[i] || {};
            var id = String(item.id || "");
            if (!known[id] || seen[id]) continue;
            seen[id] = true;
            out.push({ id: id, enabled: item.enabled === true });
        }
    }
    var defaults = defaultSources();
    for (var j = 0; j < defaults.length; ++j) {
        if (!seen[defaults[j].id]) out.push({ id: defaults[j].id, enabled: defaults[j].enabled });
    }
    return out;
}

function sourceLabel(id) {
    switch (String(id)) {
    case "open-meteo": return "Open-Meteo";
    case "openweather": return "OpenWeather";
    case "met-no": return "MET Norway";
    case "custom": return "自定义 API";
    default: return String(id || "");
    }
}

function sourceAttribution(id) {
    switch (String(id)) {
    case "open-meteo": return "天气数据 © Open-Meteo.com CC BY 4.0";
    case "openweather": return "Weather data © OpenWeather CC BY-SA 4.0";
    case "met-no": return "Data from MET Norway CC BY 4.0 / NLOD";
    case "custom": return "外部数据源 由用户提供";
    default: return "";
    }
}
