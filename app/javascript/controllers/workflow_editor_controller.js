import { Controller } from "@hotwired/stimulus"

// Add / remove / reorder step rows in the workflow editor. Each row carries
// indexed field names (workflow[steps][<i>][...]); the server reads them in
// DOM order, so indices only need to be unique — we count up from the rows
// already present, and reordering rows in the DOM is enough to reorder steps.
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

  // Drag-reorder. The whole row is draggable, but a drag that begins on an
  // interactive element is cancelled so typing, text selection, and the
  // toggle/delete keep working — you grab the card anywhere else.
  dragStart(event) {
    if (event.target.closest("input, textarea, select, button")) {
      event.preventDefault()
      return
    }
    this.dragging = event.currentTarget
    this.dragging.classList.add("is-dragging")
    event.dataTransfer.effectAllowed = "move"
  }

  dragOver(event) {
    if (!this.dragging) return
    event.preventDefault()
    const over = event.target.closest("[data-workflow-editor-target='row']")
    if (!over || over === this.dragging) return
    const rect = over.getBoundingClientRect()
    const after = (event.clientY - rect.top) / rect.height > 0.5
    this.listTarget.insertBefore(this.dragging, after ? over.nextElementSibling : over)
  }

  dragEnd() {
    if (this.dragging) this.dragging.classList.remove("is-dragging")
    this.dragging = null
  }
}
