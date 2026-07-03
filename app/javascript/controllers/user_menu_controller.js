import DropdownController from "controllers/dropdown_controller"

// Bottom-of-sidebar user popup. Inherits open/close/click-away/Escape
// from `dropdown`; adds the theme cycle (system → light → dark → system)
// persisted via PATCH /profile/theme so it follows the user across
// devices. The no-flash head script reads the same localStorage +
// server value on next load.
export default class extends DropdownController {
  static targets = ["panel"]
  static values  = { themeUrl: String, themePref: String }

  // Cycle order matches the icon order in the partial: monitor → sun → moon.
  CYCLE = ["system", "light", "dark"]

  cycleTheme(event) {
    event.preventDefault()
    event.stopPropagation()
    const current = this.themePrefValue || "system"
    const next = this.CYCLE[(this.CYCLE.indexOf(current) + 1) % this.CYCLE.length]
    this.themePrefValue = next
    // Mirror to the data attribute so the CSS-driven icon swap picks it up.
    this.element.dataset.themePref = next
    this.#applyTheme(next)
    this.#persist(next)
  }

  // "system" means honour OS preference — clear the localStorage
  // override and resolve via matchMedia for the immediate flip.
  #applyTheme(theme) {
    const root = document.documentElement
    if (theme === "system") {
      localStorage.removeItem("metisTheme")
      const dark = matchMedia("(prefers-color-scheme: dark)").matches
      root.dataset.theme = dark ? "dark" : "light"
    } else {
      localStorage.setItem("metisTheme", theme)
      root.dataset.theme = theme
    }
    const meta = document.querySelector('meta[name="theme-color"]')
    if (meta) meta.content = getComputedStyle(root).getPropertyValue("--bg").trim()
  }

  #persist(theme) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.themeUrlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token || "",
        "Accept": "application/json"
      },
      body: JSON.stringify({ theme }),
      credentials: "same-origin"
    })
  }
}
