import { directionFor, getZoomFactor, sampleStick, scrollDelta } from "../src/joystick.js";
import { setJoystickEnabled } from "../src/joystick-toggle.js";
import { installContextTracking, scrollContext, setScrollContext } from "../src/scroll-context.js";
import { activateBrowserTab } from "../src/browser-tabs.js";
import { installStopHandlers } from "../src/stop-on-navigation.js";

let passed = 0;
function assert(condition, message) {
  if (!condition) throw new Error(`FAIL: ${message}`);
  passed += 1;
  print(`PASS: ${message}`);
}

assert(directionFor(1, 0) === "right" && directionFor(-1, 0) === "left", "horizontal sectors map to left/right");
assert(directionFor(0, -1) === "up" && directionFor(0, 1) === "down", "vertical sectors map to up/down");
assert(directionFor(1, -1) === "right" && directionFor(1, 1) === "right", "diagonal sectors resolve to one cardinal direction");
assert(sampleStick(50, 50, { width: 100, height: 100 }).direction === null, "center dead zone prevents accidental scroll");
assert(sampleStick(100, 50, { width: 100, height: 100 }).direction === "right", "outer wheel activates its direction");
assert(sampleStick(100, 50, { width: 100, height: 100 }).magnitude === 1, "stick magnitude is capped at the wheel edge");
assert(scrollDelta("down", 1, 50).y === 36, "maximum tick duration is bounded and speed is predictable");
assert(scrollDelta("left", 1, 16).x < 0 && scrollDelta("up", 1, 16).y < 0, "scroll direction follows selected sector");
assert(getZoomFactor({ devicePixelRatio: 2 }, 1) === 2, "browser zoom factor follows device-pixel-ratio changes");
assert(getZoomFactor({ devicePixelRatio: 2, visualViewport: { scale: 1.5 } }, 1) === 3, "pinch zoom is included in the zoom factor");
assert(scrollDelta("down", 1, 50, 720, 2).y === 18, "scroll speed is compensated for a 2x page zoom");

const tabState = (id) => ({ id, button: { attributes: {}, setAttribute(key, value) { this.attributes[key] = value; } }, panel: { hidden: true } });
const firstTab = tabState("page-one"), secondTab = tabState("page-two");
let tabStopCalls = 0, activeContext = null;
assert(activateBrowserTab([firstTab, secondTab], "page-two", () => { tabStopCalls += 1; }, (panel) => { activeContext = panel; }),
  "tab switching accepts a registered browser tab");
assert(tabStopCalls === 1 && secondTab.button.attributes["aria-selected"] === "true", "switching browser tabs stops the active scroll and announces selection");
assert(firstTab.panel.hidden && !secondTab.panel.hidden && activeContext === secondTab.panel, "tab switch reveals the new page and updates scroll context");
assert(!activateBrowserTab([firstTab, secondTab], "missing", () => { tabStopCalls += 1; }, () => {}) && tabStopCalls === 1,
  "unknown tab IDs are ignored safely");

const stopEvents = {};
const windowEvents = { addEventListener: (name, callback) => { stopEvents[`window:${name}`] = callback; } };
const documentEvents = { hidden: false, addEventListener: (name, callback) => { stopEvents[`document:${name}`] = callback; } };
let lifecycleStops = 0;
installStopHandlers(windowEvents, documentEvents, () => { lifecycleStops += 1; });
for (const eventName of ["blur", "pagehide", "beforeunload", "hashchange", "popstate", "load"]) stopEvents[`window:${eventName}`]();
documentEvents.hidden = false; stopEvents["document:visibilitychange"]();
assert(lifecycleStops === 6, "page lifecycle events stop scrolling while visible state does not");
documentEvents.hidden = true; stopEvents["document:visibilitychange"]();
assert(lifecycleStops === 7, "backgrounding the page stops scrolling");

const toggleState = { button: { textContent: "", attributes: {}, setAttribute(key, value) { this.attributes[key] = value; } },
  dock: { hidden: false }, wheel: { tabIndex: 0, attributes: {}, setAttribute(key, value) { this.attributes[key] = value; } },
  status: { textContent: "" } };
let stopCalls = 0;
const controls = { button: toggleState.button, dock: toggleState.dock, wheel: toggleState.wheel, status: toggleState.status };
setJoystickEnabled(false, controls, () => { stopCalls += 1; });
assert(toggleState.dock.hidden && toggleState.wheel.tabIndex === -1, "disabling hides the wheel and removes it from keyboard focus");
assert(toggleState.button.attributes["aria-pressed"] === "false" && toggleState.wheel.attributes["aria-disabled"] === "true", "disabled state is announced accessibly");
assert(toggleState.button.textContent === "摇杆：关" && stopCalls === 1, "off switch is visible and immediately stops active scrolling");
setJoystickEnabled(true, controls, () => { stopCalls += 1; });
assert(!toggleState.dock.hidden && toggleState.wheel.tabIndex === 0, "enabling restores the wheel and keyboard focus");
assert(toggleState.button.attributes["aria-pressed"] === "true" && toggleState.button.textContent === "摇杆：开", "on switch state is announced and labeled");

function makeDocument() {
  const listeners = {};
  const page = makeElement("HTML", null, { overflowX: "auto", overflowY: "auto" }, 1000, 1000);
  const doc = {
    body: {}, documentElement: {}, scrollingElement: page, activeElement: null,
    defaultView: { innerWidth: 800, innerHeight: 600, getComputedStyle: (element) => element.style },
    addEventListener: (type, callback) => { listeners[type] = callback; },
    querySelectorAll: () => [], elementFromPoint: () => target,
  };
  const target = makeElement("DIV", page, { overflowX: "auto", overflowY: "auto", overscrollBehaviorX: "auto", overscrollBehaviorY: "auto" }, 100, 100);
  target.ownerDocument = doc;
  page.ownerDocument = doc;
  return { doc, page, target, listeners };
}
function makeElement(tagName, parentElement, style, maxX, maxY) {
  return {
    tagName, nodeType: 1, parentElement, style, scrollLeft: 0, scrollTop: 0,
    maxX, maxY, isConnected: true,
    scrollTo({ left, top }) { this.scrollLeft = Math.max(0, Math.min(this.maxX, left)); this.scrollTop = Math.max(0, Math.min(this.maxY, top)); },
    getRootNode() { return {}; },
  };
}

const { doc, page, target, listeners } = makeDocument();
installContextTracking(doc);
const installedListenerCount = Object.keys(listeners).length;
installContextTracking(doc);
assert(installedListenerCount === 4 && Object.keys(listeners).length === installedListenerCount,
  "context tracking installs safely and idempotently");
listeners.pointermove({ target, composedPath: () => [target] });
const alternateContext = makeElement("DIV", page, { overflowX: "auto", overflowY: "auto" }, 50, 50);
setScrollContext(alternateContext, doc);
assert(scrollContext(0, 10, doc).y === 10 && alternateContext.scrollTop === 10,
  "explicit active-tab context is selected for scrolling");
setScrollContext(target, doc);
const moved = scrollContext(40, 60, doc);
assert(target.scrollLeft === 40 && target.scrollTop === 60, "wheel scrolls the last active nested context first");
assert(page.scrollTop === 0, "page remains still while nested context can scroll");
scrollContext(100, 100, doc);
assert(target.scrollTop === 100 && page.scrollTop > 0, "remaining scroll transfers to the page at the nested boundary");
assert(moved.x === 40 && moved.y === 60, "scroll reports actual movement");
target.style.overscrollBehaviorY = "contain";
target.scrollTop = 0; page.scrollTop = 0;
scrollContext(0, 50, doc);
assert(page.scrollTop === 0, "overscroll containment is respected");
assert(scrollContext(Number.NaN, 2, doc).x === 0, "invalid movement is safely ignored");
print(`\n${passed} checks passed.`);
