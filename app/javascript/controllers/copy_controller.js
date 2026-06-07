import { Controller } from "@hotwired/stimulus"

// Copies textValue to the clipboard and flips the button to a check for a
// moment (.is-copied). Falls back silently if the clipboard API is blocked.
export default class extends Controller {
  static values = { text: String }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.textValue)
    } catch {
      return
    }
    this.element.classList.add("is-copied")
    clearTimeout(this._reset)
    this._reset = setTimeout(() => this.element.classList.remove("is-copied"), 1500)
  }
}
