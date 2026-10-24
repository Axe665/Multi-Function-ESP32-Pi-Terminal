import { directionFor, sampleStick, scrollDelta } from "../src/joystick.js";
import { installContextTracking, scrollContext } from "../src/scroll-context.js";

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
