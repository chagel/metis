import { Controller } from "@hotwired/stimulus"

// Slash-command palette over the composer. Type `/` to list commands:
//   • skills    — inserts `/<slug> ` into the message (a discovery
//                 affordance; the message is sent verbatim and AGENTS.md
//                 interprets a leading `/<slug>` as a skill trigger)
//   • workflows — (new chat only) launches a gated run; dispatches
//                 skill-palette:launch, which the form's workflow-launch
//                 controller handles (chip + flips the submit target)
//
// Open: type `/` at the start of an empty composer. Filter as you type.
// Pick: ↑ ↓ navigate, Enter/Tab/click. Dismiss: Esc or click outside.
export default class extends Controller {
  static values = { skills: { type: Array, default: [] }, workflows: { type: Array, default: [] } }
  static targets = ["popup"]

  get textarea() {
    return this.element.querySelector("textarea")
  }

  connect() {
    this._open = false
    this._activeIndex = 0
    this._filtered = []
    this._commands = [
      ...this.workflowsValue.map((w) => ({
        kind: "workflow", key: String(w.name).toLowerCase(),
        name: w.name, id: w.id, meta: `${w.steps} steps · ${w.gates} gates`,
        description: w.description || "", intro: w.intro || ""
      })),
      ...this.skillsValue.map((s) => ({
        kind: "skill", key: String(s.slug).toLowerCase(),
        slug: s.slug, description: s.description || "",
        meta: s.source === "builtin" ? "built-in" : "team"
      }))
    ]
    this._docClick = (e) => { if (!this.element.contains(e.target)) this._close() }
    document.addEventListener("click", this._docClick)
  }

  disconnect() {
    document.removeEventListener("click", this._docClick)
  }

  onInput() {
    const value = this.textarea.value
    if (value.startsWith("/")) {
      // Close once a space is typed — the command has been chosen, the rest is the ask.
      if (/\s/.test(value)) { this._close(); return }
      this._filter(value.slice(1).toLowerCase())
      this._open ? this._render() : this._show()
    } else {
      this._close()
    }
  }

  onKeydown(event) {
    if (!this._open) return
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault(); this._move(1); this._render(); return
      case "ArrowUp":
        event.preventDefault(); this._move(-1); this._render(); return
      case "Enter":
      case "Tab":
        if (this._filtered.length === 0) return
        // stopImmediatePropagation, not stopPropagation: composer#submitOnEnter
        // is a sibling keydown listener on the same textarea — Enter must pick
        // here, not send the message.
        event.preventDefault(); event.stopImmediatePropagation()
        this._pick(this._filtered[this._activeIndex]); return
      case "Escape":
        event.preventDefault(); this._close()
    }
  }

  pickFromClick(event) {
    const entry = this._filtered[Number(event.currentTarget.dataset.index)]
    if (entry) this._pick(entry)
  }

  // ── private ──────────────────────────────────────────────────────────────

  _filter(query) {
    this._filtered = query
      ? this._commands.filter((c) => c.key.includes(query))
      : this._commands.slice()
    this._activeIndex = 0
  }

  _show() {
    if (!this.popupTarget) return
    this._open = true
    this.popupTarget.hidden = false
    this._render()
  }

  _close() {
    if (!this._open) return
    this._open = false
    if (this.popupTarget) this.popupTarget.hidden = true
  }

  _move(delta) {
    const n = this._filtered.length
    if (n === 0) return
    this._activeIndex = (this._activeIndex + delta + n) % n
  }

  _render() {
    if (this._filtered.length === 0) { this._close(); return }
    let lastKind = null
    this.popupTarget.innerHTML = this._filtered.map((c, i) => {
      let header = ""
      if (c.kind !== lastKind) {
        header = `<div class="skill-palette-group">${c.kind === "workflow" ? "Workflows" : "Skills"}</div>`
        lastKind = c.kind
      }
      const active = i === this._activeIndex ? "is-active" : ""
      const name = c.kind === "workflow"
        ? `${this._escape(c.name)}<span class="skill-palette-source">${c.meta}</span>`
        : `/${this._escape(c.slug)}<span class="skill-palette-source">${c.meta}</span>`
      const desc = c.kind === "workflow" ? (c.description || c.intro || c.meta) : c.description
      return `${header}
        <button type="button" class="skill-palette-row ${active}" data-index="${i}"
                data-action="mousedown->skill-palette#pickFromClick">
          <div class="skill-palette-name">${name}</div>
          <div class="skill-palette-desc">${this._escape(desc)}</div>
        </button>`
    }).join("")
  }

  _pick(entry) {
    if (entry.kind === "workflow") {
      this.dispatch("launch", { detail: { id: entry.id, name: entry.name, description: entry.description, intro: entry.intro } })
      // Drop the `/token` — it was the trigger, not part of the run's input.
      this.textarea.value = this.textarea.value.replace(/^\/[^\s]*\s?/, "")
      this._close()
      this.textarea.focus()
      this.textarea.dispatchEvent(new Event("input", { bubbles: true }))
      return
    }
    const inserted = `/${entry.slug} `
    this.textarea.value = this.textarea.value.replace(/^\/[^\s]*/, inserted)
    this._close()
    this.textarea.focus()
    this.textarea.setSelectionRange(inserted.length, inserted.length)
    this.textarea.dispatchEvent(new Event("input", { bubbles: true }))
  }

  _escape(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"
    }[c]))
  }
}
