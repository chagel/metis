import { Controller } from "@hotwired/stimulus"

// Submits the controller's form on a child input change — for settings
// toggles that persist immediately instead of behind a Save button.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
