import { Turbo } from "@hotwired/turbo-rails"

// append, but rows already on the page are left alone. A new turn's rows
// reach the sender by both the HTTP response and the broadcast, in either
// order; a plain append would replace a row that's already streaming.
Turbo.StreamActions.append_missing = function () {
  const fragment = this.templateContent
  fragment.querySelectorAll(":scope > [id]").forEach((row) => {
    if (document.getElementById(row.id)) row.remove()
  })
  this.targetElements.forEach((target) => target.append(fragment.cloneNode(true)))
}
