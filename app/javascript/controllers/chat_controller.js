import { Controller } from "@hotwired/stimulus"

// Within this many pixels of the bottom we treat the user as "following"
// the stream and auto-scroll on new content. Past it, the user is reading
// — we leave them alone and surface a "jump to bottom" button instead.
const SCROLL_THRESHOLD = 150

// Pins the message stream to the bottom as content streams in, unless the
// user has scrolled up to read. The stream target is the scrollable
// element; mutations across the whole pane (text deltas, appended
// messages, tool-call updates) all flow through the same observer.
export default class extends Controller {
  static targets = ["messages", "scroll", "scrollButton"]
  static values = { anchor: String }

  connect() {
    this.userScrolledUp = false
    if (!this._scrollToAnchor()) this.scrollToBottom()
    this._boundOnScroll = this._onScroll.bind(this)
    this._scrollEl.addEventListener("scroll", this._boundOnScroll, { passive: true })
    this.observer = new MutationObserver(() => this._onMutation())
    this.observer.observe(this.element, {
      childList: true,
      subtree: true,
      characterData: true,
    })
  }

  disconnect() {
    this.observer?.disconnect()
    this._scrollEl?.removeEventListener("scroll", this._boundOnScroll)
  }

  scrollToBottom() {
    const el = this._scrollEl
    el.scrollTop = el.scrollHeight
    this.userScrolledUp = false
    this._hideScrollButton()
  }

  jumpToBottom() {
    this._scrollEl.scrollTo({ top: this._scrollEl.scrollHeight, behavior: "smooth" })
    this.userScrolledUp = false
    this._hideScrollButton()
  }

  // ── private ──────────────────────────────────────────────────────────────

  // Deep link from the workflow timeline ("view turn"): frame navigation
  // drops URL hashes, so the target rides in as a value. Lands the turn
  // mid-viewport wearing the accent ring (kept — it marks the linked
  // turn), and suppresses the default bottom-scroll so it stays there.
  _scrollToAnchor() {
    if (!this.anchorValue) return false
    const el = document.getElementById(this.anchorValue)
    if (!el) return false
    el.scrollIntoView({ block: "center" })
    el.classList.add("anchor-flash")
    this.userScrolledUp = true
    this._showScrollButton()
    return true
  }

  get _scrollEl() {
    return this.hasScrollTarget ? this.scrollTarget : this.element
  }

  _isNearBottom() {
    const el = this._scrollEl
    return el.scrollHeight - el.scrollTop - el.clientHeight <= SCROLL_THRESHOLD
  }

  _onScroll() {
    if (this._isNearBottom()) {
      this.userScrolledUp = false
      this._hideScrollButton()
    } else if (!this.userScrolledUp) {
      // First transition past the threshold: surface the button as a
      // "jump to latest" affordance, no new-content emphasis yet.
      this.userScrolledUp = true
      this._showScrollButton()
    }
  }

  _onMutation() {
    if (this.userScrolledUp) {
      this._showScrollButton()
      this.scrollButtonTarget?.classList.add("has-new")
    } else {
      this.scrollToBottom()
    }
  }

  _showScrollButton() {
    if (this.hasScrollButtonTarget) this.scrollButtonTarget.classList.add("visible")
  }

  _hideScrollButton() {
    if (!this.hasScrollButtonTarget) return
    this.scrollButtonTarget.classList.remove("visible")
    this.scrollButtonTarget.classList.remove("has-new")
  }
}
