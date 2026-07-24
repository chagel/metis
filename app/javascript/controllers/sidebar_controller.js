import { Controller } from "@hotwired/stimulus"

// Two behaviours on the shell:
//
// 1. Mobile drawer (narrow viewports): toggle/open/close slide the
//    sidebar in over a backdrop. Auto-closes when the #main turbo-frame
//    swaps (tapping a conversation) so the user lands on the picked chat.
//    On wide viewports these are visual no-ops (CSS).
//
// 2. Desktop collapse (wide viewports): the sidebar shrinks to an icon
//    rail. A manual toggle is remembered per section under
//    `sidebarCollapsed:<section>`, so flipping projects open doesn't also
//    collapse chats. Absent an override the server default stands.
//    Restored on connect without animating (sidebar-no-anim). Rail-only
//    sections (see nav_rail_only?) are pinned collapsed: no expand, no
//    override — only the mobile drawer behaviours apply.
//
// Keyboard shortcuts (⌘ on mac, Ctrl elsewhere): B toggles collapse,
// F focuses search (expanding first if collapsed), N starts a new chat.
const STORE_KEY = "sidebarCollapsed"

export default class extends Controller {
  static targets = ["newChat"]
  static values = { section: String, railOnly: Boolean }

  storeKey() {
    return `${STORE_KEY}:${this.sectionValue || ""}`
  }

  connect() {
    this._onFrameLoad = (event) => {
      if (event.target?.id === "main") this.close()
    }
    document.addEventListener("turbo:frame-load", this._onFrameLoad)
    this._setupSwipe()

    // Collapse is only wired on shells that ship the icon rail (chat),
    // not the settings shell, which shares this controller.
    this.collapsible = !!this.element.querySelector(".sidebar-rail")
    if (!this.collapsible) return

    // Reconcile the server-rendered default with a sticky per-section
    // override, correcting without animating. Rail-only sections ignore
    // overrides — the server-rendered collapsed state is final.
    const override = this.railOnlyValue ? null : localStorage.getItem(this.storeKey())
    if (override !== null) {
      this.element.classList.add("sidebar-no-anim")
      this.element.classList.toggle("sidebar-collapsed", override === "1")
      this.element.offsetWidth // reflow so the correction doesn't animate
      this.element.classList.remove("sidebar-no-anim")
    }

    this._onKeydown = (event) => {
      if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return
      switch (event.key.toLowerCase()) {
        case "b": event.preventDefault(); this.toggleCollapse(); break
        case "f": event.preventDefault(); this.expandAndSearch(); break
        case "n": event.preventDefault(); this.newChat(); break
      }
    }
    window.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("turbo:frame-load", this._onFrameLoad)
    if (this._onKeydown) window.removeEventListener("keydown", this._onKeydown)
    this.element.removeEventListener("touchstart", this._onTouchStart)
    this.element.removeEventListener("touchend", this._onTouchEnd)
    document.body.classList.remove("drawer-open")
  }

  // Swipe navigation on narrow viewports (thresholds from themis): a
  // quick rightward swipe from the left edge opens the drawer, a
  // leftward swipe closes it. Vertical drift bails so scrolling never
  // triggers it.
  _setupSwipe() {
    this._onTouchStart = (event) => {
      const touch = event.touches[0]
      this._swipe = { x: touch.clientX, y: touch.clientY, time: Date.now() }
    }
    this._onTouchEnd = (event) => {
      if (!this._swipe) return
      const start = this._swipe
      this._swipe = null
      if (!window.matchMedia("(max-width: 768px)").matches) return

      const touch = event.changedTouches[0]
      const dx = touch.clientX - start.x
      const dy = Math.abs(touch.clientY - start.y)
      if (dy > 60 || Date.now() - start.time > 600) return

      const open = this.element.classList.contains("sidebar-open")
      if (!open && start.x < 40 && dx > 80) this.open()
      else if (open && dx < -80) this.close()
    }
    this.element.addEventListener("touchstart", this._onTouchStart, { passive: true })
    this.element.addEventListener("touchend", this._onTouchEnd, { passive: true })
  }

  // ── mobile drawer ──
  toggle() {
    this.element.classList.contains("sidebar-open") ? this.close() : this.open()
  }
  open() {
    this.element.classList.add("sidebar-open")
    document.body.classList.add("drawer-open")
  }
  close() {
    this.element.classList.remove("sidebar-open")
    document.body.classList.remove("drawer-open")
  }

  // ── desktop collapse ──
  toggleCollapse() {
    if (this.railOnlyValue) return
    const collapsed = this.element.classList.toggle("sidebar-collapsed")
    localStorage.setItem(this.storeKey(), collapsed ? "1" : "0")
  }
  expand() {
    if (this.railOnlyValue) return
    this.element.classList.remove("sidebar-collapsed")
    localStorage.setItem(this.storeKey(), "0")
  }
  expandAndSearch() {
    this.expand()
    this.element.querySelector('[data-conversation-search-target="input"]')?.focus()
  }
  newChat() {
    this.expand()
    this.newChatTarget?.click()
  }
}
