import { getZoomFactor, sampleStick, scrollDelta } from "./joystick.js";
import { installContextTracking, scrollContext, setScrollContext } from "./scroll-context.js";
import { setJoystickEnabled } from "./joystick-toggle.js";
import { activateBrowserTab } from "./browser-tabs.js";
import { installStopHandlers } from "./stop-on-navigation.js";

const wheel = document.querySelector("#joystick");
const dock = document.querySelector("#joystick-dock");
const status = document.querySelector("#live-status");
const joystickToggle = document.querySelector("#joystick-toggle");
const fontToggle = document.querySelector("#font-toggle");
const contrastToggle = document.querySelector("#contrast-toggle");
const tabs = [...document.querySelectorAll('[role="tab"]')].map((button) => ({
  id: button.getAttribute("aria-controls"), button, panel: document.getElementById(button.getAttribute("aria-controls")),
}));
const baselinePixelRatio = window.devicePixelRatio || 1;
let pointerId = null;
let direction = null;
let strength = 0;
let previousTime = 0;
let frame = 0;

installContextTracking();

function stop() {
  if (frame) cancelAnimationFrame(frame);
  frame = 0;
  pointerId = null;
  direction = null;
  strength = 0;
  previousTime = 0;
  delete wheel.dataset.direction;
  wheel.style.setProperty("--knob-x", "0%");
  wheel.style.setProperty("--knob-y", "0%");
  status.textContent = "方向轮盘已停止";
}

for (const tab of tabs) {
  tab.button.addEventListener("click", () => activateBrowserTab(tabs, tab.id, stop, (panel) => setScrollContext(panel)));
  tab.button.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    const index = tabs.indexOf(tab);
    const next = tabs[(index + (event.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
    activateBrowserTab(tabs, next.id, stop, (panel) => setScrollContext(panel));
    next.button.focus();
  });
}

joystickToggle.addEventListener("click", () => {
  const enabled = joystickToggle.getAttribute("aria-pressed") !== "true";
  setJoystickEnabled(enabled, { button: joystickToggle, dock, wheel, status }, stop);
});

function updatePointer(event) {
  const rect = wheel.getBoundingClientRect();
  const sample = sampleStick(event.clientX - rect.left, event.clientY - rect.top, rect);
  direction = sample.direction;
  strength = sample.strength;
  wheel.style.setProperty("--knob-x", `${sample.offsetX * 30}%`);
  wheel.style.setProperty("--knob-y", `${sample.offsetY * 30}%`);
  if (direction) wheel.dataset.direction = direction;
  else delete wheel.dataset.direction;
}

function animate(time) {
  if (pointerId === null || !direction) { frame = 0; return; }
  const elapsed = previousTime ? time - previousTime : 16;
  previousTime = time;
  const delta = scrollDelta(direction, strength, elapsed, 720, getZoomFactor(window, baselinePixelRatio));
  try {
    scrollContext(delta.x, delta.y);
  } catch {
    stop();
    return;
  }
  frame = requestAnimationFrame(animate);
}

wheel.addEventListener("pointerdown", (event) => {
  if (pointerId !== null) return;
  pointerId = event.pointerId;
  wheel.setPointerCapture(pointerId);
  updatePointer(event);
  previousTime = 0;
  status.textContent = direction ? `正在向${{ up: "上", down: "下", left: "左", right: "右" }[direction]}滚动` : "摇杆处于中心，网页不会滚动";
  if (direction) frame = requestAnimationFrame(animate);
  event.preventDefault();
});
wheel.addEventListener("pointermove", (event) => {
  if (event.pointerId !== pointerId) return;
  updatePointer(event);
  if (direction && !frame) frame = requestAnimationFrame(animate);
  if (!direction && frame) { cancelAnimationFrame(frame); frame = 0; }
  event.preventDefault();
});
wheel.addEventListener("pointerup", stop);
wheel.addEventListener("pointercancel", stop);
wheel.addEventListener("lostpointercapture", stop);
wheel.addEventListener("keydown", (event) => {
  const keys = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" };
  if (event.key === "Escape") { stop(); return; }
  if (!keys[event.key]) return;
  event.preventDefault();
  const directionKey = keys[event.key];
  const delta = scrollDelta(directionKey, 0.65, 50, 720, getZoomFactor(window, baselinePixelRatio));
  scrollContext(delta.x * 1.5, delta.y * 1.5);
  status.textContent = `已向${{ up: "上", down: "下", left: "左", right: "右" }[directionKey]}滚动`;
});
installStopHandlers(window, document, stop);
fontToggle.addEventListener("click", () => {
  const enabled = document.body.classList.toggle("large-text");
  fontToggle.setAttribute("aria-pressed", String(enabled));
});
contrastToggle.addEventListener("click", () => {
  const enabled = document.body.classList.toggle("high-contrast");
  contrastToggle.setAttribute("aria-pressed", String(enabled));
});
