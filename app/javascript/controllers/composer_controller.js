import { Controller } from "@hotwired/stimulus"

// The message composer textarea:
//
// 1. Submit on Enter — Enter sends, Shift+Enter inserts a newline.
//    Enter is ignored mid-IME-composition (so confirming a
//    Chinese/Japanese candidate doesn't send) and while a turn streams.
//    On touch devices the return key inserts a newline instead (mobile
//    chat convention) — the send button is the only way to submit.
//
// 2. Auto-focus — on initial load, Turbo Drive navigation, and after a
//    streaming turn ends. Skipped on touch-primary devices and when the
//    user is focused on something else (so we don't steal a selection).
//
// 3. Auto-resize — grows with content up to MAX_HEIGHT_PX, then scrolls.
//    Resets to the natural `rows` size on form reset (post-submit).
const MAX_HEIGHT_PX = 200

export default class extends Controller {
  connect() {
    this._focusIfIdle()
    this._streamRenderHandler = this._handleStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this._streamRenderHandler)
    this._resetHandler = () => this._resetSize()
    this.element.form?.addEventListener("reset", this._resetHandler)
    this._observeComposerSize()
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this._streamRenderHandler)
    this.element.form?.removeEventListener("reset", this._resetHandler)
    this._composerObserver?.disconnect()
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
    // Mobile chat convention is the reverse of desktop: the virtual
    // keyboard's return key inserts a newline (it has no Shift+Enter)
    // and the send button submits. True on touch-primary devices and in
    // the native shells; a touchscreen laptop stays desktop because its
    // trackpad still reports hover:hover.
    if (this._touchPrimary()) return

    event.preventDefault()
    const form = this.element.form
    if (this._streaming(form)) return

    form.requestSubmit()
  }

  autoResize() {
    this.element.style.height = "auto"
    this.element.style.height = Math.min(this.element.scrollHeight, MAX_HEIGHT_PX) + "px"
  }

  // ── private ──────────────────────────────────────────────────────────────

  _resetSize() {
    this.element.style.height = ""
  }

  // Expose composer-wrap height as a CSS variable on the chat shell so
  // siblings (the scroll-to-bottom pill) can anchor above the composer.
  // ResizeObserver catches every cause — textarea growth, file
  // previews, viewport resize changing wrap padding.
  _observeComposerSize() {
    const wrap = this.element.closest(".composer-wrap")
    const chat = wrap?.closest(".chat")
    if (!wrap || !chat || typeof ResizeObserver === "undefined") return
    this._composerObserver = new ResizeObserver(() => {
      chat.style.setProperty("--composer-h", wrap.offsetHeight + "px")
    })
    this._composerObserver.observe(wrap)
  }

  _handleStreamRender(event) {
    const stream = event.detail?.newStream || event.target
    if (stream?.getAttribute("target") !== "composer_actions") return

    // Intercept the render to focus *after* the DOM has updated.
    // requestAnimationFrame here would fire too early (before the stream mutates the DOM).
    const fallbackRender = event.detail.render
    event.detail.render = async (streamElement) => {
      await fallbackRender(streamElement)
      this._focusIfIdle()
    }
  }

  _focusIfIdle() {
    if (this._touchPrimary()) return
    if (this._streaming(this.element.form)) return

    // Only treat focus on another *editable* element as a reason to bail —
    // a clicked link/button (e.g. sidebar "New chat") is not the user
    // typing somewhere else, so we should still grab focus.
    const active = document.activeElement
    if (active && active !== this.element && active.matches?.("input, textarea, select, [contenteditable=true]")) return

    // Don't steal focus if the user has highlighted text to copy/read
    if (!window.getSelection()?.isCollapsed) return

    this.element.focus()
  }

  _streaming(form) {
    return form?.querySelector("#composer_actions")?.dataset.composerState === "streaming"
  }

  _touchPrimary() {
    return document.body.classList.contains("hotwire-native") ||
      window.matchMedia("(pointer: coarse) and (hover: none)").matches
  }
}
