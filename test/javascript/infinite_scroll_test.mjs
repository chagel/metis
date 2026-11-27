import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../app/javascript/controllers/infinite_scroll_controller.js", import.meta.url), "utf8")
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  .replace("export default class", "globalThis.InfiniteScroll = class")

function setup() {
  const rendered = []
  let resolveFetch
  const context = {
    AbortController,
    IntersectionObserver: class { observe() {} disconnect() {} },
    Turbo: { renderStreamMessage: (html) => rendered.push(html) },
    fetch: (_url, { signal }) => new Promise((resolve, reject) => {
      resolveFetch = resolve
      signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })))
    })
  }
  vm.runInNewContext(source, context)
  const controller = new context.InfiniteScroll()
  const sentinel = { isConnected: true, dataset: { url: "/conversations?page=2" } }
  controller.hasSentinelTarget = true
  controller.sentinelTarget = sentinel
  controller.sentinelTargetConnected(sentinel)
  const response = { ok: true, text: async () => "<turbo-stream></turbo-stream>" }
  return { controller, sentinel, rendered, respond: () => resolveFetch(response) }
}

test("renders the next page while its sentinel is still in the list", async () => {
  const { controller, rendered, respond } = setup()
  const loading = controller.loadMore()
  respond()
  await loading
  assert.equal(rendered.length, 1)
})

test("drops a page whose list was replaced mid-request", async () => {
  const { controller, sentinel, rendered, respond } = setup()
  const loading = controller.loadMore()
  sentinel.isConnected = false
  respond()
  await loading
  assert.equal(rendered.length, 0)
})

test("aborts the request when the sentinel leaves", async () => {
  const { controller, rendered } = setup()
  const loading = controller.loadMore()
  controller.sentinelTargetDisconnected()
  await loading
  assert.equal(rendered.length, 0)
  assert.equal(controller.loading, false)
})
