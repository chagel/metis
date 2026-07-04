// Light haptic on every tap of a link or button inside the Hotwire
// Native shell, so the web UI feels native (ported from themis, which
// wires a Stimulus controller per element — a delegated listener covers
// everything for the one style we use). The message shape matches the
// bridge protocol the iOS app's NativeBridge registers; in a browser
// the handler doesn't exist and this never fires.
document.addEventListener("click", (event) => {
  const bridge = window.webkit?.messageHandlers?.nativeBridge
  if (!bridge) return
  if (!event.target.closest("a, button, [role='button'], summary, label, select")) return

  try {
    bridge.postMessage({ component: "haptic", event: "trigger", data: { style: "light" } })
  } catch {
    // Native side may not have the component yet — fail silent.
  }
}, { capture: true })
