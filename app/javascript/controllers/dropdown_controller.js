import { Controller } from "@hotwired/stimulus"

// A small popup: toggle a panel open, close on outside click or Escape.
// The open state is the "open" class on the controller element, so CSS
// drives the panel's visibility.
export default class extends Controller {
  connect() {
    this.onDocClick = (event) => {
      if (!this.element.contains(event.target)) this.close()
    }
    this.onKey = (event) => { if (event.key === "Escape") this.close() }
  }

  disconnect() {
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    this.element.classList.contains("open") ? this.close() : this.open()
  }

  open() {
    this.element.classList.add("open")
    this.syncExpanded(true)
    // Defer so the click that opened it doesn't immediately close it.
    setTimeout(() => {
      document.addEventListener("click", this.onDocClick)
      document.addEventListener("keydown", this.onKey)
    }, 0)
  }

  close() {
    this.element.classList.remove("open")
    this.syncExpanded(false)
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
  }

  // Reflect open state on a trigger that opts in with aria-expanded.
  syncExpanded(open) {
    this.element.querySelector("[aria-expanded]")?.setAttribute("aria-expanded", open)
  }
}
