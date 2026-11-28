import { Controller } from "@hotwired/stimulus"

// Generic endless-scroll controller.
//
// Attach to the actual scroll container (the element with
// `overflow:auto`/`scroll`) — not just any wrapping div — so
// IntersectionObserver's `root` clips the sentinel correctly. Mark a
// descendant as `data-infinite-scroll-target="sentinel"` with
// `data-url="…"`. When the sentinel intersects the container's
// viewport (a bit earlier, via rootMargin), we fetch the next page as
// a turbo_stream and let Turbo apply it. The response is expected to
// append new items *before* the sentinel and either replace it (more
// pages) or remove it (last page).
//
// State lives on the controller, not the sentinel — Stimulus's target
// callbacks re-wire the observer whenever the sentinel is swapped in or
// out, so we never re-instantiate the controller and `this.loading`
// naturally resets when a fresh sentinel arrives.
export default class extends Controller {
  static targets = ["sentinel"]

  sentinelTargetConnected(element) {
    this.observer?.disconnect()
    this.observer = new IntersectionObserver(
      ([entry]) => { if (entry.isIntersecting) this.loadMore() },
      { root: this.element, rootMargin: "200px" }
    )
    this.observer.observe(element)
    this.loading = false
  }

  // A frame reload swaps the list mid-request; an old page must not land in
  // the new list, so abort it and drop any response for a gone sentinel.
  sentinelTargetDisconnected() {
    this.observer?.disconnect()
    this.request?.abort()
  }

  async loadMore() {
    if (this.loading || !this.hasSentinelTarget) return
    const url = this.sentinelTarget.dataset.url
    if (!url) return

    const sentinel = this.sentinelTarget
    this.request = new AbortController()
    this.loading = true
    try {
      const response = await fetch(url, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin",
        signal: this.request.signal
      })
      const html = response.ok ? await response.text() : null
      if (html && sentinel.isConnected) Turbo.renderStreamMessage(html)
    } catch (error) {
      if (error.name !== "AbortError") throw error
    } finally {
      this.loading = false
    }
  }
}
