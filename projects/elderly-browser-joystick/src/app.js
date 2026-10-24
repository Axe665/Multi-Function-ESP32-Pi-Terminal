import { sampleStick, scrollDelta } from "./joystick.js";
import { installContextTracking, scrollContext } from "./scroll-context.js";

const wheel = document.querySelector("#joystick");
const status = document.querySelector("#live-status");
const fontToggle = document.querySelector("#font-toggle");
const contrastToggle = document.querySelector("#contrast-toggle");
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
  status.textContent = "方向轮盘已停止";
}

function updatePointer(event) {
  const rect = wheel.getBoundingClientRect();
  const sample = sampleStick(event.clientX - rect.left, event.clientY - rect.top, rect);
  direction = sample.direction;
  strength = sample.strength;
  if (direction) wheel.dataset.direction = direction;
  else delete wheel.dataset.direction;
}

function animate(time) {
  if (pointerId === null || !direction) { frame = 0; return; }
  const elapsed = previousTime ? time - previousTime : 16;
  previousTime = time;
  const delta = scrollDelta(direction, strength, elapsed);
  scrollContext(delta.x, delta.y);
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
  const delta = scrollDelta(directionKey, 0.65, 50);
  scrollContext(delta.x * 1.5, delta.y * 1.5);
  status.textContent = `已向${{ up: "上", down: "下", left: "左", right: "右" }[directionKey]}滚动`;
});
window.addEventListener("blur", stop);
document.addEventListener("visibilitychange", () => { if (document.hidden) stop(); });
fontToggle.addEventListener("click", () => {
  const enabled = document.body.classList.toggle("large-text");
  fontToggle.setAttribute("aria-pressed", String(enabled));
});
contrastToggle.addEventListener("click", () => {
  const enabled = document.body.classList.toggle("high-contrast");
  contrastToggle.setAttribute("aria-pressed", String(enabled));
});
