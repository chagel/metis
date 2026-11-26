import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["signal"]
  static values = { url: String }

  connect() {
    this.observer = new MutationObserver(() => this.scheduleRefresh())
    this.observer.observe(this.signalTarget, { childList: true })
    this.onVisibilityChange = () => {
      if (!document.hidden) this.scheduleRefresh()
    }
    document.addEventListener("visibilitychange", this.onVisibilityChange)
  }

  disconnect() {
    this.observer.disconnect()
    document.removeEventListener("visibilitychange", this.onVisibilityChange)
    clearTimeout(this.refreshTimer)
  }

  scheduleRefresh() {
    clearTimeout(this.refreshTimer)
    this.refreshTimer = setTimeout(() => this.refresh(), 300)
  }

  refresh() {
    const frame = this.element.querySelector("#convos")
    const controls = frame?.querySelector(".convo-controls")
    if (!frame || !controls) return

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("filter", controls.dataset.filter)
    url.searchParams.set("kind", controls.dataset.kind)
    if (frame.src === url.toString()) frame.reload()
    else frame.src = url.toString()
  }
}
