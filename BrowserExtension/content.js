(() => {
  "use strict";

  const VERSION = "0.1.29-friends";
  const EVENT_NAME = "sofa-theater-command-0.1.29-friends";
  const READY_ATTR = "data-sofa-theater-helper";
  const COMMAND_ATTR = "data-sofa-theater-command";
  const STATUS_ATTR = "data-sofa-theater-status";
  const ACTIVE_ATTR = "data-sofa-theater-active";
  const NETFLIX_ATTR = "data-sofa-theater-netflix";
  const YOUTUBE_ATTR = "data-sofa-theater-youtube";
  const RESIZE_CURSOR_ATTR = "data-sofa-theater-resize-cursor";
  const STYLE_ID = "sofa-theater-style";
  const RESIZE_HIT_RADIUS = 8;
  const MIN_RESERVED_WIDTH = 260;
  const MAX_RESERVED_WIDTH = 600;
  const MIN_VIDEO_WIDTH = 640;

  const html = document.documentElement;
  if (!html) return;

  // The WebExtension and Sofa's built-in fallback share this DOM marker. The
  // first one installed owns the command listener; a second copy is unnecessary.
  if (html.getAttribute(READY_ATTR) === VERSION) return;

  let activeTarget = null;
  let activeKind = null;
  let reservedWidth = 0;
  let autoReserve = false;
  let preferredReservedWidth = null;
  let refreshQueued = false;
  let sizingRule = null;
  let resizePointerID = null;
  let pendingReservedWidth = null;
  let resizeFrame = 0;

  function setStatus(value) {
    html.setAttribute(STATUS_ATTR, value);
  }

  function cleanLegacyLayout() {
    // Restore layouts left by Sofa 0.1.15 if the app was replaced while
    // Theater was active. The new implementation never reparents a player.
    const legacy = globalThis.__sofaCinema;
    if (legacy) {
      try {
        if (legacy.moved !== false && legacy.root && legacy.placeholder && legacy.placeholder.parentNode) {
          legacy.placeholder.parentNode.replaceChild(legacy.root, legacy.placeholder);
        } else if (legacy.moved !== false && legacy.root && legacy.parent && legacy.parent.isConnected) {
          if (legacy.next && legacy.next.parentNode === legacy.parent) {
            legacy.parent.insertBefore(legacy.root, legacy.next);
          } else {
            legacy.parent.appendChild(legacy.root);
          }
        }
      } catch (_) {}
      try {
        (legacy.marks || []).forEach((mark) => {
          if (mark.had) mark.e.setAttribute(mark.n, mark.v);
          else mark.e.removeAttribute(mark.n);
        });
      } catch (_) {}
      try { if (legacy.overlay) legacy.overlay.remove(); } catch (_) {}
      try { if (legacy.style) legacy.style.remove(); } catch (_) {}
      try { delete globalThis.__sofaCinema; } catch (_) {}
    }

    document.getElementById("sofa-cinema-overlay")?.remove();
    document.getElementById("sofa-cinema-style")?.remove();
    document.querySelectorAll(
      "[data-sofa-cinema],[data-sofa-cinema-root],[data-sofa-cinema-box],[data-sofa-cinema-netflix]"
    ).forEach((element) => {
      element.removeAttribute("data-sofa-cinema");
      element.removeAttribute("data-sofa-cinema-root");
      element.removeAttribute("data-sofa-cinema-box");
      element.removeAttribute("data-sofa-cinema-netflix");
    });
  }

  function siteKind() {
    const host = location.hostname.toLowerCase();
    if (host === "netflix.com" || host.endsWith(".netflix.com")) return "netflix";
    if (host === "youtube.com" || host.endsWith(".youtube.com")) return "youtube";
    return null;
  }

  function findTarget(kind) {
    if (kind === "netflix") {
      return document.querySelector(".watch-video--player-view") ||
        document.querySelector('[data-uia="watch-video"]');
    }
    if (kind === "youtube") return document.querySelector("#movie_player");
    return null;
  }

  function compatibleFullscreen(target) {
    const owner = document.fullscreenElement || document.webkitFullscreenElement;
    if (!owner || !target) return false;
    return owner === document.documentElement || owner === document.body ||
      owner === target || owner.contains(target) || target.contains(owner);
  }

  function hasReservation() {
    return autoReserve || reservedWidth > 0;
  }

  function effectiveReservedWidth() {
    if (!hasReservation()) return 0;
    const requested = autoReserve
      ? Math.round(Math.min(460, Math.max(MIN_RESERVED_WIDTH, innerWidth * 0.26)))
      : reservedWidth;
    return clampReservedWidth(requested);
  }

  function reservationRange() {
    const availableAfterMinimumVideo = Math.max(0, innerWidth - MIN_VIDEO_WIDTH);
    const minimum = Math.min(MIN_RESERVED_WIDTH, innerWidth);
    const maximum = Math.max(
      minimum,
      Math.min(MAX_RESERVED_WIDTH, availableAfterMinimumVideo)
    );
    return { minimum, maximum };
  }

  function clampReservedWidth(value) {
    const range = reservationRange();
    return Math.round(Math.min(range.maximum, Math.max(range.minimum, Number(value) || 0)));
  }

  function videoWidthCSS(kind) {
    if (!hasReservation()) return kind === "netflix" ? "100%" : "100vw";
    const reservation = `${effectiveReservedWidth()}px`;
    if (kind === "netflix") {
      return `calc(100% - ${reservation})`;
    }
    return `calc(100vw - ${reservation})`;
  }

  function stylesheet(kind) {
    const width = videoWidthCSS(kind);
    const interactionCSS = hasReservation() ? `
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}],
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] * {
        cursor: col-resize !important;
      }
      html[${RESIZE_CURSOR_ATTR}]:fullscreen::backdrop,
      html[${RESIZE_CURSOR_ATTR}] :fullscreen::backdrop,
      html[${RESIZE_CURSOR_ATTR}]:-webkit-full-screen::backdrop,
      html[${RESIZE_CURSOR_ATTR}] :-webkit-full-screen::backdrop {
        cursor: col-resize !important;
      }
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] #movie_player[${YOUTUBE_ATTR}],
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${NETFLIX_ATTR}] {
        overflow: visible !important;
      }
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] #movie_player[${YOUTUBE_ATTR}]::after,
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${NETFLIX_ATTR}]::after {
        content: "" !important;
        position: absolute !important;
        right: -10px !important;
        top: 50% !important;
        width: 6px !important;
        height: 64px !important;
        margin: 0 !important;
        padding: 0 !important;
        border: 1px solid rgba(28, 28, 30, 0.34) !important;
        border-radius: 999px !important;
        box-sizing: border-box !important;
        background: rgba(205, 205, 210, 0.82) !important;
        box-shadow: 0 1px 5px rgba(0, 0, 0, 0.52) !important;
        transform: translateY(-50%) !important;
        pointer-events: none !important;
        visibility: visible !important;
        opacity: 1 !important;
        z-index: 2147483647 !important;
      }
    ` : "";

    if (kind === "netflix") {
      // With no call Netflix naturally fills the fullscreen viewport, so zero
      // reserve means zero CSS mutation on its protected playback tree.
      if (!hasReservation()) return "";
      // This is the same minimal seam Teleparty uses. Netflix remains in charge
      // of the DRM video, its transform, canvas, controls, and React hierarchy.
      return `${interactionCSS}
        [${NETFLIX_ATTR}] {
          left: 0 !important;
          width: ${width} !important;
        }
      `;
    }

    // Keep #movie_player under #container. Moving it breaks YouTube's Polymer
    // lifecycle; sizing the existing node preserves video, controls and captions.
    return `${interactionCSS}
      html[${ACTIVE_ATTR}], html[${ACTIVE_ATTR}] body {
        overflow: hidden !important;
        background: #000 !important;
      }
      html[${ACTIVE_ATTR}] ytd-app {
        pointer-events: none !important;
        visibility: hidden !important;
        background: #000 !important;
      }
      #movie_player[${YOUTUBE_ATTR}] {
        position: fixed !important;
        left: 0 !important;
        top: 0 !important;
        width: ${width} !important;
        height: 100vh !important;
        min-width: 0 !important;
        min-height: 0 !important;
        max-width: none !important;
        max-height: none !important;
        margin: 0 !important;
        z-index: 2147483646 !important;
        background: #000 !important;
        pointer-events: auto !important;
        visibility: visible !important;
      }
      #movie_player[${YOUTUBE_ATTR}] .html5-video-container,
      #movie_player[${YOUTUBE_ATTR}] video.html5-main-video {
        width: 100% !important;
        height: 100% !important;
        left: 0 !important;
        top: 0 !important;
        object-fit: contain !important;
      }
    `;
  }

  function findSizingRule() {
    const style = document.getElementById(STYLE_ID);
    const rules = style?.sheet?.cssRules;
    if (!rules) return null;
    for (const rule of rules) {
      if (rule.style?.getPropertyValue("width")?.includes("calc(")) return rule;
    }
    return null;
  }

  function ensureSizingRule() {
    let style = document.getElementById(STYLE_ID);
    if (!style?.isConnected && activeKind && hasReservation()) {
      style = document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = stylesheet(activeKind);
      (document.head || html).appendChild(style);
    }
    if (!style?.isConnected) return null;
    if (!sizingRule?.style || sizingRule.parentStyleSheet !== style.sheet) {
      sizingRule = findSizingRule();
    }
    return sizingRule;
  }

  function setReservedWidthCSS(width) {
    const rule = ensureSizingRule();
    if (!rule?.style || !activeKind) return false;
    const base = activeKind === "netflix" ? "100%" : "100vw";
    rule.style.setProperty("width", `calc(${base} - ${width}px)`, "important");
    return true;
  }

  function updateActiveStatus() {
    if (!activeKind || !activeTarget) return;
    const rect = activeTarget.getBoundingClientRect();
    setStatus(
      `SOFA_OK|on|${activeKind}|${Math.round(rect.width)}x${Math.round(rect.height)}|` +
      `${document.fullscreenElement || document.webkitFullscreenElement ? "pagefs" : "windowed"}`
    );
  }

  function applyReservedWidth(width) {
    if (!activeKind || !hasReservation()) return false;
    const nextWidth = clampReservedWidth(width);
    if (!setReservedWidthCSS(nextWidth)) {
      setStatus("SOFA_ERR|resize-style-missing");
      cancelResizeInteraction();
      return false;
    }
    autoReserve = false;
    reservedWidth = nextWidth;
    preferredReservedWidth = reservedWidth;
    return true;
  }

  function flushPendingResize() {
    if (resizeFrame) cancelAnimationFrame(resizeFrame);
    resizeFrame = 0;
    if (pendingReservedWidth === null) return true;
    const width = pendingReservedWidth;
    pendingReservedWidth = null;
    return applyReservedWidth(width);
  }

  function scheduleReservedWidth(clientX) {
    pendingReservedWidth = clampReservedWidth(innerWidth - clientX);
    if (resizeFrame) return;
    resizeFrame = requestAnimationFrame(() => {
      resizeFrame = 0;
      if (pendingReservedWidth === null) return;
      const width = pendingReservedWidth;
      pendingReservedWidth = null;
      applyReservedWidth(width);
    });
  }

  function setResizeCursor(visible) {
    if (visible === html.hasAttribute(RESIZE_CURSOR_ATTR)) return;
    if (visible) html.setAttribute(RESIZE_CURSOR_ATTR, "1");
    else html.removeAttribute(RESIZE_CURSOR_ATTR);
  }

  function pointerIsOnBoundary(event) {
    if (!activeTarget || !hasReservation()) return false;
    const rect = activeTarget.getBoundingClientRect();
    return event.clientY >= 0 && event.clientY <= innerHeight &&
      Math.abs(event.clientX - rect.right) <= RESIZE_HIT_RADIUS;
  }

  function finishResize(event, notifyYouTube = true) {
    if (resizePointerID === null) return;
    if (event && event.pointerId !== resizePointerID) return;
    const pointerID = resizePointerID;
    resizePointerID = null;
    const resizeApplied = flushPendingResize();
    try {
      if (html.hasPointerCapture?.(pointerID)) html.releasePointerCapture(pointerID);
    } catch (_) {}
    setResizeCursor(resizeApplied && event ? pointerIsOnBoundary(event) : false);
    if (resizeApplied) updateActiveStatus();
    if (notifyYouTube && activeKind === "youtube") {
      try { window.dispatchEvent(new Event("resize")); } catch (_) {}
    }
  }

  function cancelResizeInteraction() {
    if (resizeFrame) cancelAnimationFrame(resizeFrame);
    resizeFrame = 0;
    pendingReservedWidth = null;
    const pointerID = resizePointerID;
    resizePointerID = null;
    if (pointerID !== null) {
      try {
        if (html.hasPointerCapture?.(pointerID)) html.releasePointerCapture(pointerID);
      } catch (_) {}
    }
    setResizeCursor(false);
  }

  function handlePointerMove(event) {
    if (!activeKind || !hasReservation()) {
      setResizeCursor(false);
      return;
    }
    if (resizePointerID !== null) {
      if (event.pointerId !== resizePointerID) return;
      if ((event.buttons & 1) === 0) {
        finishResize(event);
        return;
      }
      scheduleReservedWidth(event.clientX);
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    setResizeCursor(pointerIsOnBoundary(event));
  }

  function handlePointerDown(event) {
    if (resizePointerID !== null || event.button !== 0 || event.isPrimary === false ||
        !pointerIsOnBoundary(event)) return;
    resizePointerID = event.pointerId;
    setResizeCursor(true);
    try { html.setPointerCapture?.(resizePointerID); } catch (_) {}
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  function handlePointerUp(event) {
    if (resizePointerID === null || event.pointerId !== resizePointerID) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    finishResize(event);
  }

  function handlePointerCancel(event) {
    if (resizePointerID === null || (event && event.pointerId !== resizePointerID)) return;
    finishResize(null);
  }

  function handleWindowBlur() {
    if (resizePointerID !== null) handlePointerCancel(null);
    else setResizeCursor(false);
  }

  function handlePointerLeave(event) {
    if (resizePointerID !== null && (event.buttons & 1) === 0) finishResize(event);
    else if (resizePointerID === null) setResizeCursor(false);
  }

  function handleMouseUpFallback(event) {
    if (resizePointerID !== null && event.button === 0) finishResize(null);
  }

  function handleViewportResize() {
    if (!activeKind || !hasReservation()) return;
    const nextWidth = effectiveReservedWidth();
    if (setReservedWidthCSS(nextWidth) && !autoReserve) reservedWidth = nextWidth;
  }

  function handleFullscreenChange() {
    if (activeKind && !compatibleFullscreen(activeTarget)) clearLayout(true);
  }

  function clearLayout(updateStatus = true, notifyResize = true) {
    const layoutNeedsResize = activeKind === "youtube";
    cancelResizeInteraction();
    cleanLegacyLayout();
    document.getElementById(STYLE_ID)?.remove();
    document.querySelectorAll(`[${NETFLIX_ATTR}]`).forEach((element) => {
      element.removeAttribute(NETFLIX_ATTR);
    });
    document.querySelectorAll(`[${YOUTUBE_ATTR}]`).forEach((element) => {
      element.removeAttribute(YOUTUBE_ATTR);
    });
    html.removeAttribute(ACTIVE_ATTR);
    html.removeAttribute(RESIZE_CURSOR_ATTR);
    activeTarget = null;
    activeKind = null;
    reservedWidth = 0;
    autoReserve = false;
    sizingRule = null;
    if (notifyResize && layoutNeedsResize) {
      try { window.dispatchEvent(new Event("resize")); } catch (_) {}
      setTimeout(() => {
        try { window.dispatchEvent(new Event("resize")); } catch (_) {}
      }, 250);
    }
    if (updateStatus) setStatus("SOFA_OK|off");
  }

  function installLayout(width) {
    clearLayout(false, false);

    const kind = siteKind();
    if (!kind) {
      setStatus("SOFA_ERR|unsupported-site");
      return;
    }

    const target = findTarget(kind);
    if (!target) {
      setStatus(`SOFA_ERR|no-${kind}-player`);
      return;
    }
    // Theater augments the fullscreen the viewer explicitly opened with F. It
    // must never manufacture a different fullscreen or reshape a normal page.
    if (!compatibleFullscreen(target)) {
      setStatus("SOFA_ERR|requires-page-fullscreen");
      return;
    }

    // "auto" tracks the native full-screen call rail responsively as Safari or
    // Chrome settles into its final viewport. Numeric widths remain supported
    // for direct diagnostics.
    if (width === "auto" && preferredReservedWidth !== null) {
      autoReserve = false;
      reservedWidth = clampReservedWidth(preferredReservedWidth);
    } else {
      autoReserve = width === "auto";
      const requestedWidth = Math.max(0, Number(width) || 0);
      reservedWidth = autoReserve
        ? 0
        : (requestedWidth > 0 ? clampReservedWidth(requestedWidth) : 0);
    }
    activeTarget = target;
    activeKind = kind;

    const css = stylesheet(kind);
    if (css) {
      const style = document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = css;
      (document.head || html).appendChild(style);
      sizingRule = findSizingRule();
    }

    html.setAttribute(ACTIVE_ATTR, kind);
    // Do not mutate Netflix's protected video/canvas/player subtree or
    // synthesize a resize; Widevine remains entirely under Netflix's control.
    if (kind !== "netflix" || hasReservation()) {
      target.setAttribute(kind === "netflix" ? NETFLIX_ATTR : YOUTUBE_ATTR, "1");
      if (kind === "youtube") {
        try { window.dispatchEvent(new Event("resize")); } catch (_) {}
      }
    }

    const rect = target.getBoundingClientRect();
    const expectedWidth = Math.max(0, innerWidth - effectiveReservedWidth());
    const geometryOK = Math.abs(rect.left) <= 4 && Math.abs(rect.top) <= 4 &&
      Math.abs(rect.width - expectedWidth) <= 6 && Math.abs(rect.height - innerHeight) <= 6;
    if (!geometryOK) {
      clearLayout(false);
      setStatus(
        `SOFA_ERR|not-covering|${kind}|${Math.round(rect.width)}x${Math.round(rect.height)}|` +
        `${Math.round(expectedWidth)}x${Math.round(innerHeight)}`
      );
      return;
    }

    setStatus(
      `SOFA_OK|on|${kind}|${Math.round(rect.width)}x${Math.round(rect.height)}|` +
      `${document.fullscreenElement || document.webkitFullscreenElement ? "pagefs" : "windowed"}`
    );
  }

  function handleCommand() {
    const raw = html.getAttribute(COMMAND_ATTR) || "";
    const [command, width] = raw.split("|");
    if (command === "on") installLayout(width);
    else if (command === "off") clearLayout(true);
    else if (command === "probe") {
      setStatus(activeKind ? `SOFA_OK|active|${activeKind}` : "SOFA_OK|ready");
    } else {
      setStatus("SOFA_ERR|bad-command");
    }
  }

  function refreshTargetAfterPageUpdate() {
    refreshQueued = false;
    if (!activeKind) return;
    const target = findTarget(activeKind);
    if (!target) return;
    if (target !== activeTarget) {
      cancelResizeInteraction();
      activeTarget?.removeAttribute(
        activeKind === "netflix" ? NETFLIX_ATTR : YOUTUBE_ATTR
      );
      activeTarget = target;
      if (activeKind !== "netflix" || hasReservation()) {
        target.setAttribute(
          activeKind === "netflix" ? NETFLIX_ATTR : YOUTUBE_ATTR,
          "1"
        );
        if (activeKind === "youtube") {
          try { window.dispatchEvent(new Event("resize")); } catch (_) {}
        }
      }
    }
  }

  document.addEventListener(EVENT_NAME, handleCommand, false);
  window.addEventListener("pointermove", handlePointerMove, true);
  window.addEventListener("pointerdown", handlePointerDown, true);
  window.addEventListener("pointerup", handlePointerUp, true);
  window.addEventListener("pointercancel", handlePointerCancel, true);
  window.addEventListener("pointerleave", handlePointerLeave, true);
  window.addEventListener("mouseup", handleMouseUpFallback, true);
  window.addEventListener("blur", handleWindowBlur, true);
  window.addEventListener("resize", handleViewportResize, true);
  html.addEventListener("lostpointercapture", handlePointerCancel, true);
  document.addEventListener("fullscreenchange", handleFullscreenChange, true);
  document.addEventListener("webkitfullscreenchange", handleFullscreenChange, true);
  new MutationObserver(() => {
    if (!activeKind || refreshQueued) return;
    refreshQueued = true;
    requestAnimationFrame(refreshTargetAfterPageUpdate);
  }).observe(html, { childList: true, subtree: true });

  html.setAttribute(READY_ATTR, VERSION);
  setStatus(`SOFA_OK|ready|${VERSION}`);

  // A command may have been written just before the document-start content
  // script finished installing. Process it once rather than losing the click.
  if (html.hasAttribute(COMMAND_ATTR)) handleCommand();
})();
