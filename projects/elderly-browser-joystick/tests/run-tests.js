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
const rightSample = sampleStick(80, 50, { width: 100, height: 100 });
assert(rightSample.direction === "right", "right wheel sector activates right scrolling");
assert(rightSample.magnitude === 1 && rightSample.offsetX === 1 && rightSample.offsetY === 0,
  "stick position reaches but never exceeds the wheel edge");
const shortDrag = sampleStick(65, 50, { width: 100, height: 100 });
assert(Math.abs(shortDrag.offsetX - 0.5) < 1e-9, "stick knob position reflects drag distance continuously");
const diagonalSample = sampleStick(70, 30, { width: 100, height: 100 });
assert(diagonalSample.direction === "right" && diagonalSample.offsetX > 0 && diagonalSample.offsetY < 0,
  "visual knob follows diagonal input while scrolling stays in one cardinal sector");
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
const wheelNode = { id: "joystick", closest: () => ({ id: "joystick-dock" }) };
listeners.pointerdown({ target: wheelNode, composedPath: () => [wheelNode, { id: "joystick-dock" }] });
listeners.focusin({ target: wheelNode, composedPath: () => [wheelNode, { id: "joystick-dock" }] });
assert(doc.__calmBrowseJoystickContext.element === target,
  "dragging/focusing the overlay wheel preserves the page's last scroll context");
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

const focusedContext = makeElement("TEXTAREA", page, { overflowX: "auto", overflowY: "auto" }, 0, 50);
setScrollContext(target, doc);
doc.activeElement = focusedContext;
assert(scrollContext(0, 10, doc).y === 10 && focusedContext.scrollTop === 10,
  "a newly focused scrollable element takes priority over an older pointer context");
doc.activeElement = null;

const fallbackFixture = makeDocument();
installContextTracking(fallbackFixture.doc);
fallbackFixture.doc.activeElement = fallbackFixture.doc.body;
assert(scrollContext(0, 10, fallbackFixture.doc).y === 10 && fallbackFixture.target.scrollTop === 10,
  "missing page context falls back to the viewport center");
fallbackFixture.doc.elementFromPoint = () => null;
assert(scrollContext(0, 10, fallbackFixture.doc).y === 10 && fallbackFixture.page.scrollTop === 10,
  "empty viewport-center hit falls back to whole-page scrolling");

const textarea = makeElement("TEXTAREA", page, { overflowX: "auto", overflowY: "auto" }, 0, 80);
setScrollContext(textarea, doc);
assert(scrollContext(0, 20, doc).y === 20 && textarea.scrollTop === 20, "textarea is supported as the active scroll context");

const shadowHost = makeElement("DIV", page, { overflowX: "hidden", overflowY: "auto" }, 0, 80);
const shadowChild = makeElement("SPAN", null, { overflowX: "hidden", overflowY: "hidden" }, 0, 0);
shadowChild.getRootNode = () => ({ host: shadowHost });
setScrollContext(shadowChild, doc);
assert(scrollContext(0, 20, doc).y === 20 && shadowHost.scrollTop === 20, "scroll traversal crosses an open shadow-root host");

const { doc: frameDoc, page: framePage, target: frameTarget } = makeDocument();
setScrollContext(frameTarget, frameDoc);
const sameOriginFrame = makeElement("IFRAME", page, { overflowX: "hidden", overflowY: "hidden" }, 0, 0);
sameOriginFrame.contentDocument = frameDoc;
setScrollContext(sameOriginFrame, doc);
assert(scrollContext(0, 20, doc).y === 20 && frameTarget.scrollTop === 20, "same-origin iframe context can be scrolled");
frameTarget.scrollTop = 100;
framePage.scrollTop = 1000;
page.scrollTop = 0;
setScrollContext(sameOriginFrame, doc);
assert(scrollContext(0, 20, doc).y === 20 && page.scrollTop === 20,
  "remaining movement crosses a same-origin iframe boundary to the outer page");

const crossOriginFrame = makeElement("IFRAME", page, { overflowX: "hidden", overflowY: "hidden" }, 0, 0);
Object.defineProperty(crossOriginFrame, "contentDocument", { get() { throw new Error("cross-origin access denied"); } });
page.scrollTop = 0;
setScrollContext(crossOriginFrame, doc);
assert(scrollContext(0, 20, doc).y === 20 && page.scrollTop === 20,
  "cross-origin iframe remains inaccessible and outer-page fallback stays safe");
print(`\n${passed} checks passed.`);
