import { Controller } from "@hotwired/stimulus";

// A hunch card: the finished work previews a few lines and expands in place,
// and dismissing swaps the action row for the reasons, so nothing jumps.
export default class extends Controller {
  static targets = ["work", "toggle"];

  connect() {
    if (!this.hasWorkTarget) return;
    const clipped = this.workTarget.scrollHeight > this.workTarget.clientHeight + 4;
    this.toggleTarget.hidden = !clipped;
    this.workTarget.classList.toggle("is-clipped", clipped);
  }

  toggle() {
    const open = this.element.classList.toggle("is-expanded");
    this.toggleTarget.textContent = open ? this.toggleTarget.dataset.less : this.toggleTarget.dataset.more;
  }

  dismiss() {
    this.element.classList.add("is-dismissing");
  }

  cancel() {
    this.element.classList.remove("is-dismissing");
  }
}
