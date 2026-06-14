import { Controller } from "@hotwired/stimulus"

// Periodically refetches a Turbo Stream and renders it, to age content that
// has no server-side change event of its own (e.g. the board's coarse
// machine presence going online -> stale). Skips while the tab is hidden or
// the element is "open" (a dropdown mid-interaction), and after a failed
// fetch — never spins a tight retry loop.
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 20000 } }

  connect() {
    this.timer = setInterval(() => this.tick(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async tick() {
    if (document.hidden || this.element.classList.contains("open")) return

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/vnd.turbo-stream.html" }
      })
      if (response.ok) window.Turbo.renderStreamMessage(await response.text())
    } catch {
      // Transient network error — wait for the next tick.
    }
  }
}
