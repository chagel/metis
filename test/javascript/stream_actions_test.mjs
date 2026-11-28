import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../app/javascript/stream_actions.js", import.meta.url), "utf8")
  .replace('import { Turbo } from "@hotwired/turbo-rails"', "")

function row(id) {
  return { id, remove() { this.removed = true } }
}

function run(existingIds, rows) {
  const Turbo = { StreamActions: {} }
  vm.runInNewContext(source, { Turbo, document: { getElementById: (id) => existingIds.includes(id) ? {} : null } })
  const appended = []
  // Mirrors a real DocumentFragment: rows are reachable via children, while
  // a :scope selector matches nothing (there is no scoping element).
  const fragment = {
    children: rows,
    querySelectorAll: () => [],
    cloneNode: () => rows.filter((r) => !r.removed).map((r) => r.id)
  }
  const target = { append: (nodes) => appended.push(...nodes) }
  Turbo.StreamActions.append_missing.call({ templateContent: fragment, targetElements: [ target ] })
  return appended
}

test("appends rows that aren't on the page yet", () => {
  assert.deepEqual(run([], [ row("message_1"), row("message_2") ]), [ "message_1", "message_2" ])
})

test("leaves a row that's already on the page untouched", () => {
  assert.deepEqual(run([ "message_2" ], [ row("message_1"), row("message_2") ]), [ "message_1" ])
})

test("a second delivery of the same rows is a no-op", () => {
  assert.deepEqual(run([ "message_1", "message_2" ], [ row("message_1"), row("message_2") ]), [])
})
