export function activateBrowserTab(tabs, selectedId, stop, onContextChanged) {
  const selected = tabs.find((tab) => tab.id === selectedId);
  if (!selected) return false;
  stop();
  for (const tab of tabs) {
    const active = tab === selected;
    tab.button.setAttribute("aria-selected", String(active));
    tab.button.tabIndex = active ? 0 : -1;
    tab.panel.hidden = !active;
  }
  onContextChanged(selected.panel);
  return true;
}
