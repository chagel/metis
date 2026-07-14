// Turbo swaps a frame to "Content missing" when a frame-bound response
// lacks the frame. Redirected/OK responses (e.g. a session-expiry
// redirect to the login page) become a full-page visit; rejected ones
// (WAF block page, 5xx during a deploy) keep the pane in place and
// raise a flash toast instead, so the user doesn't lose the chat.
// Frames with their own turbo:frame-missing handling are left alone.
document.addEventListener("turbo:frame-missing", (event) => {
  if (event.defaultPrevented) return
  event.preventDefault()

  const { response, visit } = event.detail
  if (response.redirected || response.ok) {
    visit(response)
  } else {
    console.warn(`Frame-bound request failed (HTTP ${response.status}) without a usable page; alerting instead.`)
    showAlert()
  }
})

function showAlert() {
  document.querySelector(".flash-toast")?.remove()
  const toast = document.createElement("div")
  toast.className = "flash-toast"
  toast.dataset.controller = "flash"
  toast.innerHTML = '<div class="flash alert" role="alert"></div>'
  toast.firstElementChild.textContent =
    document.querySelector('meta[name="request-failed-alert"]').content
  document.body.append(toast)
}
