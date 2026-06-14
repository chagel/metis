import { Controller } from "@hotwired/stimulus"

// Two behaviours on the shell:
//
// 1. Mobile drawer (narrow viewports): toggle/open/close slide the
//    sidebar in over a backdrop. Auto-closes when the #main turbo-frame
//    swaps (tapping a conversation) so the user lands on the picked chat.
//    On wide viewports these are visual no-ops (CSS).
//
// 2. Desktop collapse (wide viewports): the sidebar shrinks to an icon
//    rail. State persists in localStorage and is restored on connect
//    without animating (sidebar-no-anim).
//
// Keyboard shortcuts (⌘ on mac, Ctrl elsewhere): B toggles collapse,
// F focuses search (expanding first if collapsed), N starts a new chat.
const STORE_KEY = "sidebarCollapsed"

export default class extends Controller {
  static targets = ["newChat"]

  connect() {
    this._onFrameLoad = (event) => {
      if (event.target?.id === "main") this.close()
    }
    document.addEventListener("turbo:frame-load", this._onFrameLoad)

    // Collapse is only wired on shells that ship the icon rail (chat),
    // not the settings shell, which shares this controller.
    this.collapsible = !!this.element.querySelector(".sidebar-rail")
    if (!this.collapsible) return

    if (localStorage.getItem(STORE_KEY) === "1") {
      this.element.classList.add("sidebar-no-anim", "sidebar-collapsed")
      this.element.offsetWidth // reflow so the restore doesn't animate
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
    document.body.classList.remove("drawer-open")
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
    const collapsed = this.element.classList.toggle("sidebar-collapsed")
    localStorage.setItem(STORE_KEY, collapsed ? "1" : "0")
  }
  expand() {
    this.element.classList.remove("sidebar-collapsed")
    localStorage.setItem(STORE_KEY, "0")
  }
  expandAndSearch() {
    this.expand()
    this.element.querySelector('[data-conversation-filter-target="query"]')?.focus()
  }
  newChat() {
    this.expand()
    this.newChatTarget?.click()
  }
}
