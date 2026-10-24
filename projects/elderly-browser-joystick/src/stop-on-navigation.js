export function installStopHandlers(windowRef, documentRef, stop) {
  for (const eventName of ["blur", "pagehide", "beforeunload", "hashchange", "popstate", "load"]) {
    windowRef.addEventListener(eventName, stop);
  }
  documentRef.addEventListener("visibilitychange", () => {
    if (documentRef.hidden) stop();
  });
}
