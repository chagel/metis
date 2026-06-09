import { Controller } from "@hotwired/stimulus"

// New-chat composer launcher. Picking a workflow points the form at
// workflow_runs#create (with a hidden workflow_id) so the typed text
// becomes the run's input; clearing it reverts to a normal chat. The
// controller is on the <form>, so this.element is the form.
export default class extends Controller {
  static targets = ["menu", "chip", "chipName", "field"]
  static values = { runsPath: String, chatPath: String }

  connect() {
    this._outside = (event) => { if (!this.element.contains(event.target)) this.hideMenu() }
    document.addEventListener("click", this._outside)
  }

  disconnect() {
    document.removeEventListener("click", this._outside)
  }

  toggle(event) {
    event.preventDefault()
    this.menuTarget.hidden = !this.menuTarget.hidden
  }

  hideMenu() {
    if (this.hasMenuTarget) this.menuTarget.hidden = true
  }

  select(event) {
    event.preventDefault()
    const { id, name } = event.currentTarget.dataset
    this.fieldTarget.value = id
    this.chipNameTarget.textContent = name
    this.chipTarget.hidden = false
    this.hideMenu()
    this.element.action = this.runsPathValue
    this.setSendTitle("Start run")
  }

  clear(event) {
    event.preventDefault()
    this.fieldTarget.value = ""
    this.chipTarget.hidden = true
    this.element.action = this.chatPathValue
    this.setSendTitle("Start")
  }

  setSendTitle(text) {
    const send = this.element.querySelector(".send")
    if (!send) return
    send.title = text
    send.setAttribute("aria-label", text)
  }
}
