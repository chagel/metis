import { Controller } from "@hotwired/stimulus"

// Fills the project-binding <select> with the team's Linear projects,
// fetched on demand via the operator's connector token, so a project is
// bound by name instead of a pasted UUID. Degrades to the current value
// (and a message) if Linear isn't connected or the fetch fails.
export default class extends Controller {
  static values = { url: String }
  static targets = ["select", "status"]

  async refresh() {
    this.setStatus(this.element.dataset.loadingText || "Loading…")
    this.selectTarget.disabled = true
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      let data = {}
      try { data = await response.json() } catch { /* non-JSON error page */ }
      if (!response.ok) throw new Error(data.error || `Couldn't load projects (HTTP ${response.status}).`)
      this.populate(data.projects || [])
      this.setStatus("")
    } catch (error) {
      console.error("linear-projects refresh failed:", error)
      this.setStatus(error.message)
    } finally {
      this.selectTarget.disabled = false
    }
  }

  populate(projects) {
    const current = this.selectTarget.value
    const options = ['<option value="">—</option>']
    let found = false
    for (const project of projects) {
      if (project.id === current) found = true
      options.push(`<option value="${project.id}">${this.escape(project.name)}</option>`)
    }
    // Keep a current binding selectable even if it's outside this member's
    // visible projects.
    if (current && !found) options.push(`<option value="${current}">${this.escape(current)}</option>`)
    this.selectTarget.innerHTML = options.join("")
    this.selectTarget.value = current
  }

  setStatus(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }

  escape(value) {
    const node = document.createElement("div")
    node.textContent = value ?? ""
    return node.innerHTML
  }
}
