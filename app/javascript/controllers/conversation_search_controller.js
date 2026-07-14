import { Controller } from "@hotwired/stimulus"

// Server-side title search; scope/kind frame swaps rerun the active query.
export default class extends Controller {
  static targets = ["input", "panel", "frame", "loading", "error", "sentinel"]
  static values = {
    url: String,
    delay: { type: Number, default: 250 },
    minLength: Number
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
    if (this.normalizedQuery.length >= this.minLengthValue) {
      this.debounce = setTimeout(() => this.performSearch(), this.delayValue)
    } else {
      this.exitSearch()
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

  // Keep a slow response from replacing results for the newest query.
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
      const stale = !this.hasSentinelTarget || this.sentinelTarget.dataset.url !== url
      if (stale) return
      if (!response.ok) {
        this.fail()
        return
      }
      Turbo.renderStreamMessage(await response.text())
    } catch {
      if (this.hasSentinelTarget && this.sentinelTarget.dataset.url === url) this.fail()
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

  // The loading/error notes share the results-summary row; .is-loading
  // hides the stale summary inside the frame so only one row shows.
  showStatus(state) {
    if (this.hasLoadingTarget) this.loadingTarget.hidden = state !== "loading"
    if (this.hasErrorTarget) this.errorTarget.hidden = state !== "error"
    if (this.hasPanelTarget) this.panelTarget.classList.toggle("is-loading", state === "loading")
  }
}
