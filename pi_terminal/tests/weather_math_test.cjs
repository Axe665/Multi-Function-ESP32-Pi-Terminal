// Executes the shipping WeatherMath.js instead of a second implementation.
// Run: node pi_terminal/tests/weather_math_test.cjs
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync(path.join(__dirname, '../qml/WeatherMath.js'), 'utf8')
    // ".pragma library" is a QML-JS preprocessor line, not JavaScript.
    .replace(/^\s*\.pragma[^\n]*$/gm, '');
const context = { Date, Math, Number, String, isFinite, isNaN, JSON, encodeURIComponent, Array, RegExp, parseFloat };
vm.createContext(context);
vm.runInContext(source, context);

function fixture(name) {
    return JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/weather', name), 'utf8'));
}

// --- WMO / provider mapping ------------------------------------------------
assert.equal(context.wmoCategory(0), 'clear');
assert.equal(context.wmoCategory(2), 'partly');
assert.equal(context.wmoCategory(3), 'cloudy');
assert.equal(context.wmoCategory(45), 'fog');
assert.equal(context.wmoCategory(51), 'drizzle');
assert.equal(context.wmoCategory(61), 'rain');
assert.equal(context.wmoCategory(71), 'snow');
assert.equal(context.wmoCategory(80), 'showers');
assert.equal(context.wmoCategory(95), 'thunder');
assert.equal(context.wmoCategory(-1), 'unknown');
assert.equal(context.wmoText(0), '晴朗');
assert.equal(context.wmoText(61), '降雨');
assert.equal(context.wmoIcon(0, true), 'wb_sunny');
assert.equal(context.wmoIcon(0, false), 'nights_stay');
assert.equal(context.wmoIcon(61, true), 'grain');
assert.equal(context.wmoIcon(73, true), 'ac_unit');
assert.equal(context.wmoIcon(95, true), 'thunderstorm');

assert.equal(context.owmToWmo(200), 95);
assert.equal(context.owmToWmo(500), 61);
assert.equal(context.owmToWmo(501), 63);
assert.equal(context.owmToWmo(502), 65);
assert.equal(context.owmToWmo(520), 80);
assert.equal(context.owmToWmo(600), 73);
assert.equal(context.owmToWmo(701), 45);
assert.equal(context.owmToWmo(800), 0);
assert.equal(context.owmToWmo(801), 1);
assert.equal(context.owmToWmo(802), 2);
assert.equal(context.owmToWmo(803), 3);

assert.equal(context.metNoToWmo('clearsky_day'), 0);
assert.equal(context.metNoToWmo('partlycloudy_night'), 2);
assert.equal(context.metNoToWmo('cloudy'), 3);
assert.equal(context.metNoToWmo('lightrain'), 61);
assert.equal(context.metNoToWmo('heavyrainandthunder'), 95);
assert.equal(context.metNoToWmo('snow'), 73);
assert.equal(context.metNoToWmo('fog'), 45);
assert.equal(context.metNoIsDay('clearsky_day'), true);
assert.equal(context.metNoIsDay('clearsky_night'), false);

assert.equal(context.windDirText(0), '北风');
assert.equal(context.windDirText(45), '东北风');
assert.equal(context.windDirText(135), '东南风');
assert.equal(context.windDirText(350), '北风');

// --- units -----------------------------------------------------------------
assert.equal(context.tempValue(0, 'imperial'), 32);
assert.equal(context.tempText(0, 'imperial'), '32°');
assert.equal(context.tempWithUnit(0, 'imperial'), '32°F');
assert.equal(context.windText(16.09344, 'imperial'), '10 mph');
assert.equal(context.windText(12.4, 'metric'), '12 km/h');
assert.equal(context.precipText(25.4, 'imperial'), '1 in');
assert.equal(context.tempNumberText(-9.6, 'metric'), '-10');

// --- time ------------------------------------------------------------------
assert.equal(context.dateParts(0, 28800).hour, 8);
assert.equal(context.formatHm(0, 28800), '08:00');
assert.equal(context.formatWeekday(0, 0), '周四');
assert.equal(context.formatMonthDay(0, 28800), '1/1');
const localMidnight = Date.UTC(2026, 9, 27, 16, 0, 0);
assert.equal(context.parseLocalIso('2026-10-28T00:00', 28800), localMidnight);
assert.equal(context.toEpochMs('2026-10-28T00:00:00Z'), 1793145600000);
assert.equal(context.toEpochMs(1793188800), 1793188800000);
assert.equal(context.formatDayLabel(localMidnight, 28800, localMidnight + 3600 * 1000), '今天');
assert.equal(context.formatDayLabel(localMidnight + 86400000, 28800, localMidnight + 3600 * 1000), '明天');

// --- URLs ------------------------------------------------------------------
const place = { name: '珠海', lat: 22.2707, lon: 113.5767 };
const omUrl = context.buildOpenMeteoUrl(place);
assert.ok(omUrl.indexOf('latitude=22.2707') > 0);
assert.ok(omUrl.indexOf('timezone=auto') > 0);
assert.ok(omUrl.indexOf('forecast_hours=24') > 0);
assert.ok(omUrl.indexOf('temperature_unit=celsius') > 0);

const owOneCall = context.buildOpenWeatherUrls(place, 'KEY123', 'onecall', 'zh');
assert.equal(owOneCall.length, 1);
assert.ok(owOneCall[0].indexOf('data/3.0/onecall') > 0);
assert.ok(owOneCall[0].indexOf('appid=KEY123') > 0);
assert.ok(owOneCall[0].indexOf('units=metric') > 0);
const ow25 = context.buildOpenWeatherUrls(place, 'KEY123', '2.5', 'en');
assert.equal(ow25.length, 2);
assert.ok(ow25[0].indexOf('data/2.5/weather') > 0);
assert.ok(ow25[1].indexOf('data/2.5/forecast') > 0);

assert.ok(context.buildMetNoUrl(place).indexOf('locationforecast/2.0/compact') > 0);
assert.ok(context.buildGeocodingUrl('珠海', 'zh').indexOf('name=%E7%8F%A0%E6%B5%B7') > 0);
assert.ok(context.metNoUserAgent('me@example.com').indexOf('me@example.com') > 0);

const customUrl = context.buildCustomUrl(
    'https://example.com/w?lat={lat}&lon={lon}&key={key}&u={units}', place, 'abc', 'zh');
assert.ok(customUrl.indexOf('lat=22.2707') > 0);
assert.ok(customUrl.indexOf('key=abc') > 0);
assert.ok(customUrl.indexOf('u=metric') > 0);

// --- Open-Meteo ------------------------------------------------------------
const om = fixture('open-meteo-zhuhai.json');
const omNow = context.parseLocalIso(om.current.time, om.utc_offset_seconds);
const omModel = context.parseOpenMeteo(om, omNow);
assert.equal(omModel.source, 'open-meteo');
assert.equal(omModel.utcOffsetSeconds, 28800);
assert.equal(omModel.hourly.length, 24);
assert.equal(omModel.daily.length, 7);
assert.ok(Math.abs(omModel.current.temp - om.current.temperature_2m) < 1e-6);
assert.equal(omModel.current.code, om.current.weather_code);
assert.equal(omModel.daily[0].max, om.daily.temperature_2m_max[0]);
assert.equal(omModel.daily[0].min, om.daily.temperature_2m_min[0]);
assert.equal(omModel.hourly[0].t, context.parseLocalIso(om.hourly.time[0], om.utc_offset_seconds));
assert.ok(omModel.hourly[0].t <= omNow);

// --- OpenWeather One Call --------------------------------------------------
const oneCall = fixture('openweather-onecall.json');
const owNow = 1793188800000;
const owModel = context.parseOpenWeatherOneCall(oneCall, owNow);
assert.equal(owModel.utcOffsetSeconds, 28800);
assert.equal(owModel.hourly.length, 24);
assert.equal(owModel.daily.length, 7);
assert.ok(Math.abs(owModel.current.wind - 4.2 * 3.6) < 1e-6);
assert.equal(owModel.current.code, 2);
assert.equal(owModel.hourly[0].pop, 10);
assert.ok(owModel.daily[0].max >= owModel.daily[0].min);

// --- OpenWeather 2.5 (two requests) ---------------------------------------
const owCurrent = fixture('openweather-25-current.json');
const owForecast = fixture('openweather-25-forecast.json');
const partial = context.parseOpenWeatherCurrent(owCurrent, owNow);
assert.equal(partial.current.code, 1);
assert.ok(Math.abs(partial.current.temp - 26.4) < 1e-6);
const merged = context.parseOpenWeatherForecast(owForecast, partial, owNow);
assert.equal(merged.hourly.length, 24);
assert.ok(merged.daily.length >= 5 && merged.daily.length <= 7);
for (const day of merged.daily) assert.ok(day.max >= day.min);

// --- MET Norway ------------------------------------------------------------
const metno = fixture('met-no-zhuhai.json');
const metnoRows = metno.properties.timeseries;
const metnoNow = context.toEpochMs(metnoRows[0].time);
const metnoModel = context.parseMetNo(metno, metnoNow, 28800);
assert.equal(metnoModel.utcOffsetSeconds, 28800);
assert.equal(metnoModel.offsetApproximate, true);
assert.equal(metnoModel.hourly.length, 24);
assert.ok(metnoModel.daily.length >= 7);
assert.ok(Math.abs(metnoModel.current.temp - metnoRows[0].data.instant.details.air_temperature) < 1e-6);

// --- custom ----------------------------------------------------------------
const custom = fixture('custom.json');
const mapping = {
    currentTemp: 'now.temp_c', currentCode: 'now.code', currentWind: 'now.wind_kph',
    currentWindDir: 'now.wind_deg', currentHumidity: 'now.humidity',
    hourlyTime: 'forecast.hourly.time', hourlyTemp: 'forecast.hourly.temp',
    hourlyCode: 'forecast.hourly.code', hourlyPop: 'forecast.hourly.pop',
    dailyDate: 'forecast.daily.date', dailyMax: 'forecast.daily.max',
    dailyMin: 'forecast.daily.min', dailyCode: 'forecast.daily.code'
};
const customModel = context.parseCustom(custom, mapping, Date.UTC(2026, 9, 28, 12, 0, 0), 28800);
assert.equal(customModel.source, 'custom');
assert.equal(customModel.current.temp, 21.5);
assert.equal(customModel.hourly.length, 3);
assert.equal(customModel.daily.length, 2);
assert.equal(customModel.daily[1].code, 61);

const compatible = context.parseCustom(om, {}, omNow, 28800);
assert.equal(compatible.source, 'custom');
assert.equal(compatible.hourly.length, 24);

// --- geocoding -------------------------------------------------------------
const geo = context.parseGeocoding({ results: [
    { name: '珠海', admin1: '广东', country: '中国', latitude: 22.27, longitude: 113.58 },
    { name: '珠海', admin1: '广东', country: '中国', latitude: 22.27, longitude: 113.58 }
] });
assert.equal(geo.length, 2);
assert.equal(geo[0].name, '珠海');
assert.equal(context.placeLabel(geo[0]), '珠海 广东');

// --- cache -----------------------------------------------------------------
const packed = context.packCache(omModel);
assert.ok(packed.length > 100);
const unpacked = context.unpackCache(packed);
assert.ok(unpacked !== null);
assert.equal(unpacked.current.temp, omModel.current.temp);
assert.equal(unpacked.hourly.length, 24);
assert.equal(unpacked.daily.length, 7);
assert.equal(unpacked.source, 'open-meteo');
assert.equal(context.unpackCache('not json'), null);
assert.ok(context.cacheAgeMs(unpacked, omNow + 60000) >= 0);

// --- sources ---------------------------------------------------------------
const sources = context.normalizeSources([{ id: 'custom', enabled: true }, { id: 'bogus', enabled: true }]);
assert.equal(sources.length, 4);
assert.equal(sources[0].id, 'custom');
assert.equal(sources[0].enabled, true);
assert.ok(sources.every(function(item) { return item.id !== 'bogus'; }));
assert.equal(context.sourceLabel('met-no'), 'MET Norway');
assert.ok(context.sourceAttribution('open-meteo').indexOf('CC BY 4.0') > 0);

// --- places ----------------------------------------------------------------
const defaults = context.defaultPlaces();
assert.equal(defaults.length, 1);
assert.equal(defaults[0].name, '珠海');
assert.equal(defaults[0].utcOffsetSeconds, 28800);
assert.equal(context.placeKey(defaults[0]), '22.271,113.577');

// --- daily aggregation -----------------------------------------------------
const rows = [
    { t: Date.UTC(2026, 9, 28, 1), temp: 20, code: 3, pop: 10 },
    { t: Date.UTC(2026, 9, 28, 7), temp: 24, code: 61, pop: 40 },
    { t: Date.UTC(2026, 9, 28, 13), temp: 22, code: 61, pop: 80 },
    { t: Date.UTC(2026, 9, 29, 1), temp: 18, code: 0, pop: -1 }
];
const days = context.summarizeDays(rows, 28800, 7);
assert.equal(days.length, 2);
assert.equal(days[0].max, 24);
assert.equal(days[0].min, 20);
assert.equal(days[0].code, 61);
assert.equal(days[0].pop, 80);

// --- cache TTL ------------------------------------------------------------
// 6 小时内算新鲜，超过才标「缓存已过期」；边界严格大于，正好 6 小时仍是新鲜。
assert.equal(context.CACHE_TTL_MS, 6 * 60 * 60 * 1000);
const hour = 60 * 60 * 1000;
const cached = { fetchedAt: 1000 };
assert.equal(context.cacheAgeMs(cached, 1000 + hour), hour);
assert.equal(context.cacheExpired(cached, 1000 + hour), false);
assert.equal(context.cacheExpired(cached, 1000 + 6 * hour), false);
assert.equal(context.cacheExpired(cached, 1000 + 6 * hour + 1), true);
assert.equal(context.cacheExpired(null, Date.now()), true);
// 时钟回拨（model 比 now 还晚）不能让缓存显示成"未来"，age 夹到 0。
assert.equal(context.cacheAgeMs({ fetchedAt: 5000 }, 1000), 0);
assert.equal(context.cacheExpired({ fetchedAt: 5000 }, 1000), false);

// --- custom API key -------------------------------------------------------
// 模板里没有 {key} 就不该要求 Key，否则没配 Key 的合法自建源会被误跳过。
assert.equal(context.customUrlNeedsKey('https://a/b?lat={lat}&lon={lon}'), false);
assert.equal(context.customUrlNeedsKey('https://a/b?lat={lat}&key={key}'), true);
assert.equal(context.customUrlNeedsKey(''), false);
assert.equal(context.customUrlNeedsKey(undefined), false);
const customUrlWithKey = context.buildCustomUrl(
    'https://a/b?lat={lat}&lon={lon}&key={key}&units={units}&lang={lang}',
    { name: '珠海', lat: 22.27, lon: 113.58 }, 'k y&1', 'en');
assert.ok(customUrlWithKey.indexOf('key=k%20y%261') > 0, customUrlWithKey);
assert.ok(customUrlWithKey.indexOf('lat=22.27') > 0, customUrlWithKey);
assert.ok(customUrlWithKey.indexOf('units=metric') > 0, customUrlWithKey);
assert.ok(customUrlWithKey.indexOf('lang=en') > 0, customUrlWithKey);

console.log('weather_math_test: all assertions passed');
