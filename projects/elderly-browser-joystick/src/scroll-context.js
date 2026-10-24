const trackingKey = "__calmBrowseJoystickContext";

export function setScrollContext(element, documentRef = document) {
  if (!documentRef[trackingKey]) documentRef[trackingKey] = { element: null, focusedAtPointer: null };
  documentRef[trackingKey].element = element;
  documentRef[trackingKey].focusedAtPointer = documentRef.activeElement;
}

export function installContextTracking(documentRef = document) {
  function isJoystickControl(event) {
    const path = typeof event.composedPath === "function" ? event.composedPath() : [event.target];
    return path.some((node) => node?.id === "joystick-dock" || node?.closest?.("#joystick-dock"));
  }
  function install(doc) {
    if (!doc || doc[trackingKey]) return;
    doc[trackingKey] = { element: null, focusedAtPointer: null };
    const remember = (event) => {
      if (isJoystickControl(event)) return;
      const path = typeof event.composedPath === "function" ? event.composedPath() : [];
      doc[trackingKey].element = path[0] || event.target;
      doc[trackingKey].focusedAtPointer = doc.activeElement;
    };
    doc.addEventListener("pointermove", remember, { passive: true });
    doc.addEventListener("pointerdown", remember, { passive: true });
    doc.addEventListener("focusin", (event) => {
      if (!isJoystickControl(event)) doc[trackingKey].element = event.target;
    }, { passive: true });
    doc.addEventListener("load", () => installFrames(doc), true);
    installFrames(doc);
  }
  function installFrames(doc) {
    for (const frame of doc.querySelectorAll("iframe,frame")) {
      try { if (frame.contentDocument) install(frame.contentDocument); } catch { /* Cross-origin frames stay isolated. */ }
    }
  }
  install(documentRef);
}

function contextElement(doc) {
  const state = doc[trackingKey];
  let element = state?.element;
  const active = doc.activeElement;
  if (!element || !element.isConnected || (active && active !== doc.body && active !== doc.documentElement && active !== state.focusedAtPointer)) {
    element = active;
  }
  if (!element || element === doc.body || element === doc.documentElement) {
    element = doc.elementFromPoint(doc.defaultView.innerWidth / 2, doc.defaultView.innerHeight / 2);
  }
  return element || doc.scrollingElement;
}

export function scrollContext(dx, dy, documentRef = document) {
  if (!Number.isFinite(dx) || !Number.isFinite(dy)) return { x: 0, y: 0 };
  let doc = documentRef;
  let element = contextElement(doc);
  const frameAncestors = [];
  for (let depth = 0; element && depth < 8 && /^(IFRAME|FRAME)$/.test(element.tagName); depth += 1) {
    try {
      if (!element.contentDocument) break;
      frameAncestors.push({ document: doc, frame: element });
      doc = element.contentDocument;
      element = contextElement(doc);
    } catch { break; }
  }
  let remainingX = dx, remainingY = dy, movedX = 0, movedY = 0;
  for (let count = 0; element && count < 64; count += 1) {
    if (element.nodeType === 1) {
      const style = doc.defaultView.getComputedStyle(element);
      const page = element === doc.scrollingElement;
      const allowX = page || /^(auto|scroll|overlay)$/.test(style.overflowX);
      const allowY = page || /^(auto|scroll|overlay)$/.test(style.overflowY);
      const oldX = element.scrollLeft, oldY = element.scrollTop;
      element.scrollTo({ left: oldX + (allowX ? remainingX : 0), top: oldY + (allowY ? remainingY : 0), behavior: "instant" });
      const usedX = element.scrollLeft - oldX, usedY = element.scrollTop - oldY;
      remainingX -= usedX; remainingY -= usedY;
      movedX += usedX; movedY += usedY;
      if (allowX && /^(contain|none)$/.test(style.overscrollBehaviorX)) remainingX = 0;
      if (allowY && /^(contain|none)$/.test(style.overscrollBehaviorY)) remainingY = 0;
    }
    if (Math.abs(remainingX) < 0.01 && Math.abs(remainingY) < 0.01) break;
    if (element.parentElement) element = element.parentElement;
    else if (typeof element.getRootNode === "function" && element.getRootNode().host) element = element.getRootNode().host;
    else if (element !== doc.scrollingElement) element = doc.scrollingElement;
    else if (frameAncestors.length) {
      const ancestor = frameAncestors.pop();
      doc = ancestor.document;
      element = ancestor.frame;
    }
    else break;
  }
  return { x: movedX, y: movedY };
}
