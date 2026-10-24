export function setJoystickEnabled(enabled, controls, stop) {
  const { button, dock, wheel, status } = controls;
  const isEnabled = Boolean(enabled);
  if (!isEnabled) stop();
  dock.hidden = !isEnabled;
  wheel.tabIndex = isEnabled ? 0 : -1;
  wheel.setAttribute("aria-disabled", String(!isEnabled));
  button.setAttribute("aria-pressed", String(isEnabled));
  button.textContent = isEnabled ? "摇杆：开" : "摇杆：关";
  status.textContent = isEnabled ? "方向轮盘已开启" : "方向轮盘已关闭";
}
