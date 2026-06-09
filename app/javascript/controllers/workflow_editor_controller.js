import { Controller } from "@hotwired/stimulus"

// Add / remove step rows in the workflow editor. Each row carries indexed
// field names (workflow[steps][<i>][...]); the server reads them in DOM
// order, so indices only need to be unique — we count up from the rows
// already present.
export default class extends Controller {
  static targets = ["list", "template"]

  connect() {
    this.index = this.listTarget.querySelectorAll("[data-workflow-editor-target='row']").length
  }

  add(event) {
    event.preventDefault()
    const html = this.templateTarget.innerHTML.replace(/NEW_RECORD/g, this.index++)
    this.listTarget.insertAdjacentHTML("beforeend", html)
  }

  remove(event) {
    event.preventDefault()
    event.target.closest("[data-workflow-editor-target='row']").remove()
  }
}
