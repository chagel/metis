import { Controller } from "@hotwired/stimulus"

// Holds the "a workflow is selected" state on the new-chat composer form.
// The slash-command palette (skill-palette) is the entry point: choosing a
// workflow there fires skill-palette:launch, which lands here. Selecting
// points the form at workflow_runs#create (via a hidden workflow_id) so the
// typed text becomes the run's input; clearing reverts to a normal chat.
// The controller is on the <form>, so this.element is the form.
export default class extends Controller {
  static targets = ["chip", "chipName", "field", "project", "projectBlank"]
  static values = { runsPath: String, chatPath: String }

  // Handles skill-palette:launch — event.detail is { id, name }.
  selectFromPalette(event) {
    const { id, name, description, intro, default_project } = event.detail
    this.fieldTarget.value = id
    this.chipNameTarget.textContent = name
    this.chipTarget.hidden = false
    this.element.action = this.runsPathValue
    this.setSendTitle("Start run")
    // Every run needs a project (daemons claim local steps per project),
    // so blank either resolves to the workflow's default or forces a pick.
    if (this.hasProjectBlankTarget) {
      this.projectBlankTarget.textContent = default_project
        ? `Default — ${default_project}`
        : "Pick a project…"
      this.projectTarget.required = !default_project
    }
    // Lead with what step 1 actually does (your input is folded into it),
    // then the workflow's description, then a generic fallback.
    const hint = (intro || "").trim() || (description || "").trim()
    this.setPlaceholder(hint || `What should the ${name} run work on?`)
  }

  clear(event) {
    event.preventDefault()
    this.fieldTarget.value = ""
    this.chipTarget.hidden = true
    if (this.hasProjectTarget) this.projectTarget.required = false
    this.element.action = this.chatPathValue
    this.setSendTitle("Start")
    this.restorePlaceholder()
  }

  get textarea() {
    return this.element.querySelector("textarea")
  }

  setSendTitle(text) {
    const send = this.element.querySelector(".send")
    if (!send) return
    send.title = text
    send.setAttribute("aria-label", text)
  }

  setPlaceholder(text) {
    const ta = this.textarea
    if (!ta) return
    if (this._originalPlaceholder == null) this._originalPlaceholder = ta.placeholder
    ta.placeholder = text
  }

  restorePlaceholder() {
    if (this.textarea && this._originalPlaceholder != null) {
      this.textarea.placeholder = this._originalPlaceholder
    }
  }
}
