(() => {
  "use strict";

  const VERSION = "0.1.71-generic";
  // Derived, never written out a second time: Sofa builds the event name it
  // dispatches as "sofa-theater-command-" + the VERSION it parses out of this
  // file, so a hand-typed copy that lags a version bump is a listener bound to
  // an event nobody fires — which is exactly how Theater died on every site at
  // 0.1.69.
  const EVENT_NAME = `sofa-theater-command-${VERSION}`;
  const READY_ATTR = "data-sofa-theater-helper";
  const COMMAND_ATTR = "data-sofa-theater-command";
  const STATUS_ATTR = "data-sofa-theater-status";
  const ACTIVE_ATTR = "data-sofa-theater-active";
  const NETFLIX_ATTR = "data-sofa-theater-netflix";
  const YOUTUBE_ATTR = "data-sofa-theater-youtube";
  const DISNEY_ATTR = "data-sofa-theater-disney";
  const GENERIC_ATTR = "data-sofa-theater-generic";
  // Set on the fullscreen container only when the <video> is a direct child of
  // it, so the video's siblings (the control overlay) narrow with the video.
  const GENERIC_BOX_ATTR = "data-sofa-theater-generic-box";

  // The per-site marker attribute Theater puts on the element it width-sizes.
  function markerFor(kind) {
    if (kind === "netflix") return NETFLIX_ATTR;
    if (kind === "disney") return DISNEY_ATTR;
    if (kind === "generic") return GENERIC_ATTR;
    return YOUTUBE_ATTR;
  }
  // Disney mirrors Netflix's behaviour: a naturally-filling player that only
  // needs a width seam, with no fixed-fill scaffolding or synthetic resize.
  // The generic path assumes the same, because a site the viewer has already
  // put into fullscreen is by definition filling the viewport itself.
  function fillsNatively(kind) {
    return kind === "netflix" || kind === "disney" || kind === "generic";
  }
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
  try { globalThis.__sofaTheaterHelper?.destroy?.(); } catch (_) {}

  let activeTarget = null;
  let activeKind = null;
  let reservedWidth = 0;
  let autoReserve = false;
  let preferredReservedWidth = null;
  let refreshQueued = false;
  let refreshFrame = 0;
  let refreshObserver = null;
  let activeListenersInstalled = false;
  let sizingRules = [];
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
    if (host === "disneyplus.com" || host.endsWith(".disneyplus.com")) return "disney";
    // Everything else gets the generic seam. A named entry above is only needed
    // where the generic element hunt picks the wrong node (YouTube) or the site
    // wants extra guards (Disney) — not for every new service. installLayout
    // measures the result and reverts cleanly if the guess was wrong, so
    // attempting an unknown site cannot leave the page broken.
    return "generic";
  }

  /// The element to narrow, worked out from structure rather than from a
  /// per-site selector: the fullscreen element itself can never be shrunk (the
  /// UA's `:fullscreen { width:100% !important }` outranks author CSS), so take
  /// the outermost normal-flow descendant that still contains the video. This
  /// is the same walk Disney needed, promoted to the default.
  function findGenericTarget() {
    const fs = document.fullscreenElement || document.webkitFullscreenElement;
    if (!fs) return null; // Theater's fullscreen gate rejects this anyway
    const video = fs.querySelector && fs.querySelector("video");
    if (!video || video === fs) return null;
    let node = video.parentElement;
    let child = null;
    while (node && node !== fs) {
      child = node;
      node = node.parentElement;
    }
    // HBO Max puts the <video> straight inside the element it fullscreens, so
    // there is no wrapper to narrow. Size the video itself; installLayout then
    // also marks the container so the absolutely-positioned control overlay
    // sitting next to the video is pulled in with it instead of staying wide.
    return child || video;
  }

  /// When the sized element IS the video, its siblings inside the fullscreen
  /// container must narrow too, or the site's control overlay stays stretched
  /// across the column reserved for the call.
  function markGenericBox(target) {
    if (!target || target.tagName !== "VIDEO") return;
    const parent = target.parentElement;
    if (parent) parent.setAttribute(GENERIC_BOX_ATTR, "1");
  }

  function findTarget(kind) {
    if (kind === "generic") return findGenericTarget();
    if (kind === "netflix") {
      return document.querySelector(".watch-video--player-view") ||
        document.querySelector('[data-uia="watch-video"]');
    }
    if (kind === "youtube") return document.querySelector("#movie_player");
    if (kind === "disney") {
      // A width seam can NEVER shrink the fullscreen top-layer element itself —
      // the UA `:fullscreen { width:100% !important }` rule outranks author
      // CSS. So size a normal-flow DESCENDANT of the promoted element. On the
      // 2026 player (/play/ routes) Disney fullscreens #app_body_content and
      // the old #hudson-wrapper id is gone; these class anchors survive.
      const wrap = document.querySelector(
        "#hudson-wrapper, .video_view--theater, .hudson-container, .player-container-root, .btm-media-player"
      );
      const fs = document.fullscreenElement || document.webkitFullscreenElement;
      if (!fs) return wrap; // Theater's fullscreen gate rejects this anyway
      if (wrap && fs !== wrap && fs.contains(wrap)) return wrap;
      // The wrapper IS (or contains) the promoted element: size the outermost
      // video-bearing descendant of the top-layer element instead.
      return findGenericTarget() || wrap;
    }
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
    if (!hasReservation()) return fillsNatively(kind) ? "100%" : "100vw";
    const reservation = `${effectiveReservedWidth()}px`;
    if (fillsNatively(kind)) {
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
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${NETFLIX_ATTR}],
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${DISNEY_ATTR}],
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${GENERIC_ATTR}] {
        overflow: visible !important;
      }
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] #movie_player[${YOUTUBE_ATTR}]::after,
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${NETFLIX_ATTR}]::after,
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${DISNEY_ATTR}]::after,
      html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${GENERIC_ATTR}]::after {
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

    if (kind === "generic") {
      // The seam Netflix and Disney both reduce to, with nothing site-specific
      // in it: narrow the container and let the <video> letterbox into what is
      // left. With no call column to reserve there is nothing to change, so an
      // unknown site is not touched at all until the viewer needs the space.
      if (!hasReservation()) return "";
      return `${interactionCSS}
        html[${ACTIVE_ATTR}], html[${ACTIVE_ATTR}] body {
          background: #000 !important;
        }
        [${GENERIC_ATTR}] {
          left: 0 !important;
          width: ${width} !important;
        }
        [${GENERIC_ATTR}] video {
          width: 100% !important;
          height: 100% !important;
          object-fit: contain !important;
        }
        /* Video-is-a-direct-child players (HBO Max): narrow every child of the
           container together, so the control overlay tracks the video instead
           of staying stretched across the reserved column. Resetting right to
           auto is what releases an inset:0 overlay so its width takes effect. */
        [${GENERIC_BOX_ATTR}] > * {
          left: 0 !important;
          right: auto !important;
          width: ${width} !important;
        }
        [${GENERIC_BOX_ATTR}] > video {
          height: 100% !important;
          object-fit: contain !important;
        }
        /* The grip cannot be drawn on the sized element when that element is
           the <video>: a replaced element renders no ::after, so the pill was
           simply invisible on those players. Draw it on the container, parked
           at the seam by the same calc the widths use, so one update moves
           both. */
        html[${ACTIVE_ATTR}][${RESIZE_CURSOR_ATTR}] [${GENERIC_BOX_ATTR}]::after {
          content: "" !important;
          position: absolute !important;
          left: ${width} !important;
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
          transform: translate(4px, -50%) !important;
          pointer-events: none !important;
          visibility: visible !important;
          opacity: 1 !important;
          z-index: 2147483647 !important;
        }
      `;
    }

    if (kind === "disney") {
      // Same minimal seam as Netflix: Disney+'s player fills the fullscreen
      // viewport on its own, so with no call we mutate nothing. With a call,
      // constrain the promoted container's width and let the <video>
      // (object-fit: contain) letterbox into the reduced area — a belt-and-
      // suspenders cap on the video guards against it keeping its old width.
      if (!hasReservation()) return "";
      return `${interactionCSS}
        html[${ACTIVE_ATTR}], html[${ACTIVE_ATTR}] body,
        html[${ACTIVE_ATTR}] #app_body_content,
        html[${ACTIVE_ATTR}] .video_view--theater,
        html[${ACTIVE_ATTR}] .hudson-container,
        html[${ACTIVE_ATTR}] .player-container-root {
          background: #000 !important;
        }
        [${DISNEY_ATTR}] {
          left: 0 !important;
          width: ${width} !important;
        }
        [${DISNEY_ATTR}] video, [${DISNEY_ATTR}] .btm-media-client-element {
          width: 100% !important;
          height: 100% !important;
          object-fit: contain !important;
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

  /// EVERY rule the seam drives, not just the first one found.
  ///
  /// A player whose <video> is a direct child of the fullscreen element (HBO
  /// Max) needs two width rules — the video and its siblings — and the later,
  /// equally specific one wins. Updating only the first meant the pointer could
  /// drag the seam and the picture never moved, and a window resize left the
  /// column at its old width. `left` is collected too, for the grip that has to
  /// be drawn on the container.
  function findSizingRules() {
    const style = document.getElementById(STYLE_ID);
    const rules = style?.sheet?.cssRules;
    if (!rules) return [];
    const sized = [];
    for (const rule of rules) {
      if (!rule.style) continue;
      const width = !!rule.style.getPropertyValue("width")?.includes("calc(");
      const left = !!rule.style.getPropertyValue("left")?.includes("calc(");
      if (width || left) sized.push({ rule, width, left });
    }
    return sized;
  }

  function ensureSizingRules() {
    let style = document.getElementById(STYLE_ID);
    if (!style?.isConnected && activeKind && hasReservation()) {
      style = document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = stylesheet(activeKind);
      (document.head || html).appendChild(style);
    }
    if (!style?.isConnected) return [];
    if (!sizingRules.length || sizingRules[0].rule.parentStyleSheet !== style.sheet) {
      sizingRules = findSizingRules();
    }
    return sizingRules;
  }

  function setReservedWidthCSS(width) {
    const sized = ensureSizingRules();
    if (!sized.length || !activeKind) return false;
    const base = fillsNatively(activeKind) ? "100%" : "100vw";
    const seam = `calc(${base} - ${width}px)`;
    for (const entry of sized) {
      if (entry.width) entry.rule.style.setProperty("width", seam, "important");
      if (entry.left) entry.rule.style.setProperty("left", seam, "important");
    }
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

  function attachActiveListeners() {
    if (activeListenersInstalled) return;
    activeListenersInstalled = true;
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
    refreshObserver = new MutationObserver(() => {
      if (!activeKind || refreshQueued) return;
      refreshQueued = true;
      refreshFrame = requestAnimationFrame(refreshTargetAfterPageUpdate);
    });
    refreshObserver.observe(html, { childList: true, subtree: true });
  }

  function detachActiveListeners() {
    if (!activeListenersInstalled) return;
    activeListenersInstalled = false;
    window.removeEventListener("pointermove", handlePointerMove, true);
    window.removeEventListener("pointerdown", handlePointerDown, true);
    window.removeEventListener("pointerup", handlePointerUp, true);
    window.removeEventListener("pointercancel", handlePointerCancel, true);
    window.removeEventListener("pointerleave", handlePointerLeave, true);
    window.removeEventListener("mouseup", handleMouseUpFallback, true);
    window.removeEventListener("blur", handleWindowBlur, true);
    window.removeEventListener("resize", handleViewportResize, true);
    html.removeEventListener("lostpointercapture", handlePointerCancel, true);
    document.removeEventListener("fullscreenchange", handleFullscreenChange, true);
    document.removeEventListener("webkitfullscreenchange", handleFullscreenChange, true);
    refreshObserver?.disconnect();
    refreshObserver = null;
    if (refreshFrame) cancelAnimationFrame(refreshFrame);
    refreshFrame = 0;
    refreshQueued = false;
  }

  function clearLayout(updateStatus = true, notifyResize = true) {
    const layoutNeedsResize = activeKind === "youtube";
    detachActiveListeners();
    cancelResizeInteraction();
    cleanLegacyLayout();
    document.getElementById(STYLE_ID)?.remove();
    document.querySelectorAll(`[${NETFLIX_ATTR}]`).forEach((element) => {
      element.removeAttribute(NETFLIX_ATTR);
    });
    document.querySelectorAll(`[${YOUTUBE_ATTR}]`).forEach((element) => {
      element.removeAttribute(YOUTUBE_ATTR);
    });
    document.querySelectorAll(`[${DISNEY_ATTR}]`).forEach((element) => {
      element.removeAttribute(DISNEY_ATTR);
    });
    document.querySelectorAll(`[${GENERIC_ATTR}]`).forEach((element) => {
      element.removeAttribute(GENERIC_ATTR);
    });
    document.querySelectorAll(`[${GENERIC_BOX_ATTR}]`).forEach((element) => {
      element.removeAttribute(GENERIC_BOX_ATTR);
    });
    html.removeAttribute(ACTIVE_ATTR);
    html.removeAttribute(RESIZE_CURSOR_ATTR);
    activeTarget = null;
    activeKind = null;
    reservedWidth = 0;
    autoReserve = false;
    sizingRules = [];
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
    const target = findTarget(kind);
    if (!target) {
      // For a known site this means the site changed its markup. For the
      // generic path it means the fullscreen element holds no <video> — a
      // photo viewer, a game, a slide deck. Either way Theater declines
      // rather than reshaping something that is not a player.
      setStatus(kind === "generic" ? "SOFA_ERR|no-video-in-fullscreen" : `SOFA_ERR|no-${kind}-player`);
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
      sizingRules = findSizingRules();
    }

    html.setAttribute(ACTIVE_ATTR, kind);
    // Do not mutate a natively-filling player's protected subtree when there's
    // no call to make room for; Widevine stays entirely under the site's
    // control. Only YouTube (fixed-fill) needs a synthetic resize.
    if (!fillsNatively(kind) || hasReservation()) {
      target.setAttribute(markerFor(kind), "1");
      markGenericBox(target);
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

    // YouTube and Netflix mutate their DOM continuously. Pointer listeners and
    // the subtree observer are useful only during Theater; keeping them detached
    // the rest of the time makes the extension effectively idle.
    attachActiveListeners();
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
    refreshFrame = 0;
    if (!activeKind) return;
    const target = findTarget(activeKind);
    if (!target) return;
    if (target !== activeTarget) {
      cancelResizeInteraction();
      activeTarget?.removeAttribute(markerFor(activeKind));
      activeTarget?.parentElement?.removeAttribute(GENERIC_BOX_ATTR);
      activeTarget = target;
      if (!fillsNatively(activeKind) || hasReservation()) {
        target.setAttribute(markerFor(activeKind), "1");
        markGenericBox(target);
        if (activeKind === "youtube") {
          try { window.dispatchEvent(new Event("resize")); } catch (_) {}
        }
      }
    }
  }

  document.addEventListener(EVENT_NAME, handleCommand, false);

  const helperAPI = {
    version: VERSION,
    destroy() {
      clearLayout(false);
      document.removeEventListener(EVENT_NAME, handleCommand, false);
      if (html.getAttribute(READY_ATTR) === VERSION) html.removeAttribute(READY_ATTR);
      if (globalThis.__sofaTheaterHelper === helperAPI) {
        try { delete globalThis.__sofaTheaterHelper; } catch (_) {}
      }
    },
  };
  globalThis.__sofaTheaterHelper = helperAPI;

  html.setAttribute(READY_ATTR, VERSION);
  setStatus(`SOFA_OK|ready|${VERSION}`);

  // A command may have been written just before the document-start content
  // script finished installing. Process it once rather than losing the click.
  if (html.hasAttribute(COMMAND_ATTR)) handleCommand();
})();
