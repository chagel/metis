import { Controller } from "@hotwired/stimulus"

// Keeps the Chats / Hunches / Projects tabs in sync with what's in #main.
// Picking a conversation swaps the frame without re-rendering the sidebar,
// so the server-rendered active tab would stay on another section — re-derive it from
// the URL on every navigation. Each tab owns a path prefix; the longest
// match wins; the root path falls back to the first tab, other pages light none.
export default class extends Controller {
  static targets = ["link"]

  connect() {
    this.update = this.update.bind(this)
    document.addEventListener("turbo:load", this.update)
    document.addEventListener("turbo:frame-load", this.update)
    this.update()
  }

  disconnect() {
    document.removeEventListener("turbo:load", this.update)
    document.removeEventListener("turbo:frame-load", this.update)
  }

  update() {
    const here = location.pathname
    let best = here === "/" ? this.linkTargets[0] : null
    let bestLen = -1
    this.linkTargets.forEach((link) => {
      const path = new URL(link.href, location.origin).pathname
      if ((here === path || here.startsWith(path + "/")) && path.length > bestLen) {
        best = link
        bestLen = path.length
      }
    })
    this.linkTargets.forEach((link) => link.classList.toggle("on", link === best))
  }
}
