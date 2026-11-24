import { Controller } from "@hotwired/stimulus";

// Kind tabs + text search over the memory rows, client-side. Counts are
// recomputed from the DOM so Turbo Stream edits, confirms and deletes keep
// them current.
export default class extends Controller {
  static targets = ["tab", "count", "row", "query", "list", "none"];

  connect() {
    this.key = "";
    if (!this.hasListTarget) return;
    this.observer = new MutationObserver(() => this.apply());
    this.observer.observe(this.listTarget, { childList: true });
  }

  disconnect() {
    this.observer?.disconnect();
  }

  select(event) {
    this.key = event.currentTarget.dataset.key;
    this.apply();
  }

  apply() {
    const query = this.hasQueryTarget ? this.queryTarget.value.trim().toLowerCase() : "";
    const counts = { "": 0, review: 0 };
    let shown = 0;

    this.rowTargets.forEach((row) => {
      const { kind, review } = row.dataset;
      counts[""] += 1;
      counts[kind] = (counts[kind] || 0) + 1;
      if (review === "true") counts.review += 1;

      const inTab = this.key === "" || kind === this.key || (this.key === "review" && review === "true");
      const visible = inTab && (!query || row.querySelector(".memory-text").textContent.toLowerCase().includes(query));
      row.hidden = !visible;
      if (visible) shown += 1;
    });

    if (this.key !== "" && !counts[this.key]) return this.reset();

    this.tabTargets.forEach((tab, i) => {
      const count = counts[tab.dataset.key] || 0;
      this.countTargets[i].textContent = count;
      tab.hidden = count === 0;
      tab.classList.toggle("is-on", tab.dataset.key === this.key);
    });
    if (this.hasNoneTarget) this.noneTarget.hidden = shown > 0;
  }

  reset() {
    this.key = "";
    this.apply();
  }
}
