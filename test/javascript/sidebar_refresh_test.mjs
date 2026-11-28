import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../app/javascript/controllers/sidebar_refresh_controller.js", import.meta.url), "utf8")
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  .replace("export default class", "globalThis.SidebarRefresh = class")

function setup() {
  let observer
  const listeners = new Map()
  const document = {
    hidden: false,
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name) => listeners.delete(name)
  }
  const context = {
    URL, document, window: { location: { origin: "https://metis.test" } },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; observer = this }
      observe() {}
      disconnect() { this.disconnected = true }
    },
    setTimeout, clearTimeout
  }
  vm.runInNewContext(source, context)
  const controller = new context.SidebarRefresh()
  const controls = { dataset: { filter: "team", kind: "routines" } }
  const frame = { src: "", busy: false, hasAttribute(name) { return name === "busy" && this.busy },
                  querySelector: () => controls, reload() { this.reloaded = true } }
  controller.element = { querySelector: () => frame }
  controller.signalTarget = {}
  controller.urlValue = "/conversations"
  controller.connect()
  return { controller, frame, controls, observer, document, listeners }
}

test("refresh preserves the selected filters and reloads the frame", () => {
  const { controller, frame } = setup()
  controller.refresh()
  assert.equal(frame.src, "https://metis.test/conversations?filter=team&kind=routines")
  controller.refresh()
  assert.equal(frame.reloaded, true)
  controller.disconnect()
})

test("broadcasts are debounced and cleanup cancels pending work", async () => {
  const { controller, frame, observer, listeners } = setup()
  observer.callback()
  observer.callback()
  await new Promise(resolve => setTimeout(resolve, 350))
  assert.match(frame.src, /filter=team/)
  observer.callback()
  controller.disconnect()
  await new Promise(resolve => setTimeout(resolve, 350))
  assert.equal(frame.reloaded, undefined)
  assert.equal(observer.disconnected, true)
  assert.equal(listeners.size, 0)
})

test("returning to a tab refreshes missed updates", async () => {
  const { controller, frame, document, listeners } = setup()
  document.hidden = true
  listeners.get("visibilitychange")()
  await new Promise(resolve => setTimeout(resolve, 350))
  assert.equal(frame.src, "")
  document.hidden = false
  listeners.get("visibilitychange")()
  await new Promise(resolve => setTimeout(resolve, 350))
  assert.match(frame.src, /kind=routines/)
  controller.disconnect()
})

test("a filter change still loading isn't overridden by a refresh", async () => {
  const { controller, frame, controls } = setup()
  frame.busy = true
  controller.refresh()
  assert.equal(frame.src, "")
  controls.dataset.filter = "starred"
  frame.busy = false
  await new Promise(resolve => setTimeout(resolve, 350))
  assert.match(frame.src, /filter=starred/)
  controller.disconnect()
})
