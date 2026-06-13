import { Controller } from "@hotwired/stimulus"

// View-only tabs: toggles which panel is visible. Independent of any
// setting it sits next to — e.g. the bridge setup lets a user read either
// the auto or manual instructions regardless of their active claim mode.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { active: String }

  connect() {
    this.show(this.activeValue || this.tabTargets[0]?.dataset.tab)
  }

  select(event) {
    event.preventDefault()
    this.show(event.currentTarget.dataset.tab)
  }

  show(name) {
    this.tabTargets.forEach((tab) => {
      const on = tab.dataset.tab === name
      tab.classList.toggle("is-active", on)
      tab.setAttribute("aria-selected", on)
    })
    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.tab !== name
    })
  }
}
