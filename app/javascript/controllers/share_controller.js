import { Controller } from "@hotwired/stimulus"

// Toggleable share popover in the chat header. Owns open/close state
// and the copy-to-clipboard interaction. The panel itself is re-rendered
// by the server (Turbo Stream) when the share token is created/revoked.
export default class extends Controller {
  static targets = ["panel", "url", "copyButton"]
  static values = { copied: String }

  connect() {
    this._onDocClick = (event) => {
      if (!this.element.contains(event.target)) this.close()
    }
    document.addEventListener("click", this._onDocClick)
  }

  disconnect() {
    document.removeEventListener("click", this._onDocClick)
  }

  toggle(event) {
    event.stopPropagation()
    this.element.classList.toggle("share-open")
  }

  close() {
    this.element.classList.remove("share-open")
  }

  selectAll(event) {
    event.target.select()
  }

  async copy() {
    if (!this.hasUrlTarget) return
    try {
      await navigator.clipboard.writeText(this.urlTarget.value)
      const original = this.copyButtonTarget.textContent
      this.copyButtonTarget.textContent = this.copiedValue
      setTimeout(() => { this.copyButtonTarget.textContent = original }, 1500)
    } catch {
      this.urlTarget.select()
      document.execCommand("copy")
    }
  }
}
