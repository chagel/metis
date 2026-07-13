import { Controller } from "@hotwired/stimulus"

// Server-side title search for the sidebar. Debounced input navigates the
// convos-search turbo-frame (page 1); a dedicated sentinel streams later
// pages. While a query is active the browse list hides via .is-searching —
// nothing is filtered client-side. Scope/kind tab swaps re-render the
// convos frame as usual; we watch for that and rerun the query against
// the newly-picked scope.
export default class extends Controller {
  static targets = ["input", "panel", "frame", "hint", "loading", "error", "sentinel"]
  static values = {
    url: String,
    delay: { type: Number, default: 250 },
    minLength: { type: Number, default: 2 }
  }

  connect() {
    this._onFrameLoad = (event) => {
      const id = event.target?.id
      if (id === "convos-search") this.settle(event.target)
      else if (id === "convos" && this.searching) this.performSearch()
    }
    document.addEventListener("turbo:frame-load", this._onFrameLoad)

    this._onFrameError = (event) => {
      if (event.target !== this.frameTarget) return
      event.preventDefault()
      this.fail()
    }
    if (this.hasFrameTarget) {
      this.frameTarget.addEventListener("turbo:fetch-request-error", this._onFrameError)
      this.frameTarget.addEventListener("turbo:frame-missing", this._onFrameError)
    }
  }

  disconnect() {
    clearTimeout(this.debounce)
    document.removeEventListener("turbo:frame-load", this._onFrameLoad)
    if (this.hasFrameTarget) {
      this.frameTarget.removeEventListener("turbo:fetch-request-error", this._onFrameError)
      this.frameTarget.removeEventListener("turbo:frame-missing", this._onFrameError)
    }
    this.sentinelObserver?.disconnect()
  }

  queryChanged() {
    clearTimeout(this.debounce)
    const query = this.normalizedQuery
    if (query.length >= this.minLengthValue) {
      this.showStatus(null)
      this.debounce = setTimeout(() => this.performSearch(), this.delayValue)
    } else {
      this.exitSearch()
      if (query.length > 0) this.showStatus("hint")
    }
  }

  clear() {
    if (!this.hasInputTarget) return
    this.inputTarget.value = ""
    this.exitSearch()
    this.inputTarget.focus()
  }

  retry() {
    this.performSearch()
  }

  performSearch() {
    const query = this.normalizedQuery
    if (query.length < this.minLengthValue) return

    this.searching = true
    this.element.classList.add("is-searching")
    this.panelTarget.hidden = false
    this.showStatus("loading")

    const url = this.searchUrl(query)
    this.latestUrl = url
    // Setting an unchanged src is a no-op; reload() re-fetches (retry).
    if (this.frameTarget.src === url) this.frameTarget.reload()
    else this.frameTarget.src = url
  }

  // A frame response landed: if it isn't the newest query (a slow older
  // request settling late), immediately re-point the frame at the newest —
  // stale results never stand.
  settle(frame) {
    if (this.latestUrl && frame.src !== this.latestUrl) {
      frame.src = this.latestUrl
      return
    }
    this.showStatus(null)
  }

  fail() {
    this.showStatus("error")
  }

  exitSearch() {
    clearTimeout(this.debounce)
    this.searching = false
    this.latestUrl = null
    this.showStatus(null)
    this.element.classList.remove("is-searching")
    if (this.hasPanelTarget) this.panelTarget.hidden = true
    if (this.hasFrameTarget) {
      this.frameTarget.removeAttribute("src")
      this.frameTarget.innerHTML = ""
    }
  }

  // ── search-result pagination (separate from the browse sentinel) ──
  sentinelTargetConnected(element) {
    this.sentinelObserver?.disconnect()
    this.sentinelObserver = new IntersectionObserver(
      ([entry]) => { if (entry.isIntersecting) this.loadMore() },
      { root: this.element.querySelector(".convos"), rootMargin: "200px" }
    )
    this.sentinelObserver.observe(element)
    this.loadingMore = false
  }

  sentinelTargetDisconnected() {
    this.sentinelObserver?.disconnect()
  }

  async loadMore() {
    if (this.loadingMore || !this.hasSentinelTarget) return
    const url = this.sentinelTarget.dataset.url
    if (!url) return

    this.loadingMore = true
    this.frameTarget.setAttribute("aria-busy", "true")
    try {
      const response = await fetch(url, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin"
      })
      // Skip if the search moved on while this page was in flight.
      const stale = !this.hasSentinelTarget || this.sentinelTarget.dataset.url !== url
      if (response.ok && !stale) Turbo.renderStreamMessage(await response.text())
    } finally {
      this.loadingMore = false
      this.frameTarget.removeAttribute("aria-busy")
    }
  }

  get normalizedQuery() {
    return this.hasInputTarget ? this.inputTarget.value.trim() : ""
  }

  searchUrl(query) {
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("q", query)
    const controls = this.element.querySelector(".convo-controls")
    if (controls?.dataset.filter) url.searchParams.set("filter", controls.dataset.filter)
    if (controls?.dataset.kind) url.searchParams.set("kind", controls.dataset.kind)
    return url.toString()
  }

  showStatus(state) {
    if (this.hasHintTarget) this.hintTarget.hidden = state !== "hint"
    if (this.hasLoadingTarget) this.loadingTarget.hidden = state !== "loading"
    if (this.hasErrorTarget) this.errorTarget.hidden = state !== "error"
  }
}
