export const DEAD_ZONE = 0.16;

export function directionFor(x, y) {
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  if (x === 0 && y === 0) return null;
  if (Math.abs(x) >= Math.abs(y)) return x >= 0 ? "right" : "left";
  return y >= 0 ? "down" : "up";
}

export function sampleStick(pointerX, pointerY, bounds, deadZone = DEAD_ZONE) {
  const radius = Math.min(bounds.width, bounds.height) * 0.3;
  if (!(radius > 0)) return { direction: null, magnitude: 0, strength: 0 };
  const dx = (pointerX - bounds.width / 2) / radius;
  const dy = (pointerY - bounds.height / 2) / radius;
  const magnitude = Math.min(1, Math.hypot(dx, dy));
  const direction = magnitude <= deadZone ? null : directionFor(dx, dy);
  const strength = direction ? Math.max(0, (magnitude - deadZone) / (1 - deadZone)) : 0;
  return { direction, magnitude, strength };
}

export function getZoomFactor(windowRef = window, baselinePixelRatio = windowRef.devicePixelRatio || 1) {
  const pixelRatio = windowRef.devicePixelRatio || baselinePixelRatio;
  const browserZoom = pixelRatio / Math.max(0.1, baselinePixelRatio);
  const pinchZoom = windowRef.visualViewport?.scale || 1;
  return Math.max(0.1, browserZoom * pinchZoom);
}

export function scrollDelta(direction, strength, elapsedMs, speed = 720, zoomFactor = 1) {
  const zoom = Number.isFinite(zoomFactor) ? Math.max(0.1, zoomFactor) : 1;
  const distance = Math.max(0, Math.min(50, elapsedMs)) / 1000 * speed * Math.max(0, Math.min(1, strength)) / zoom;
  switch (direction) {
    case "up": return { x: 0, y: -distance };
    case "down": return { x: 0, y: distance };
    case "left": return { x: -distance, y: 0 };
    case "right": return { x: distance, y: 0 };
    default: return { x: 0, y: 0 };
  }
}
