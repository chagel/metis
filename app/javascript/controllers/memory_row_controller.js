import { Controller } from "@hotwired/stimulus";

// Swaps a memory row between its one-line view and the inline edit form.
// Enter saves, Shift+Enter adds a line, Esc cancels.
export default class extends Controller {
  static targets = ["view", "form", "input"];

  edit() {
    this.viewTarget.hidden = true;
    this.formTarget.hidden = false;
    const input = this.inputTarget;
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  }

  cancel() {
    this.formTarget.reset();
    this.formTarget.hidden = true;
    this.viewTarget.hidden = false;
  }

  key(event) {
    if (event.key === "Escape") {
      event.preventDefault();
      this.cancel();
    } else if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      this.formTarget.requestSubmit();
    }
  }
}
