import { Controller } from "@hotwired/stimulus"

// Shows a live elapsed counter ("Working for 24s") while an agent turn
// streams. Reads started_at as a Unix-ms timestamp from a data attribute
// and ticks every second. Stimulus disconnects it automatically when the
// indicator element is removed from the DOM (ChatBroadcaster#finish).
//
// When a `phase` value is present (set by ChatBroadcaster while the runtime
// provisions its sandbox/container, before pi's first event), the label shows
// the phase instead — "Resuming sandbox… 4s" — and reverts to "Working for Ns"
// once the broadcaster re-renders this element with no phase.
export default class extends Controller {
  static values = { startedAt: Number, phase: String, workingFor: String }
  static targets = ["label"]

  connect() {
    this._tick()
    this._interval = setInterval(() => this._tick(), 1000)
  }

  disconnect() {
    clearInterval(this._interval)
  }

  // ── private ──────────────────────────────────────────────────────────────

  _tick() {
    const elapsed = Math.floor((Date.now() - this.startedAtValue) / 1000)
    if (this.hasLabelTarget) this.labelTarget.textContent = this._format(elapsed)
  }

  _format(seconds) {
    const t = seconds < 60
      ? `${seconds}s`
      : `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, "0")}s`
    return this.phaseValue ? `${this.phaseValue}… ${t}` : this.workingForValue.replace("%{time}", t)
  }
}
