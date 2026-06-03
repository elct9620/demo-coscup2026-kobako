import { Controller } from "@hotwired/stimulus"

// Reconciles the generation status frame against the server until the run
// reaches a terminal state.
//
// The status panel flips to its terminal (succeeded / failed) form via a live
// Turbo Stream broadcast. That broadcast can be missed when the run finishes in
// the window between this page rendering and the Action Cable subscription being
// established — e.g. an instant LLM failure ("model not loaded") that completes
// in tens of milliseconds, before the browser has subscribed. Action Cable does
// not replay missed messages, so the panel would otherwise stay stuck on
// "Generating…" forever.
//
// This closes the race deterministically. On connect it reconciles once
// immediately (covering a run that finished before the JS even booted — the
// common case for an instant failure), then, while still pending, reloads the
// status frame from the server on an interval so the terminal state is picked up
// within one tick regardless of broadcast timing. It stops as soon as the
// terminal panel (data-generation-finished) is present; the live broadcast still
// provides the instant update on the happy path.
export default class extends Controller {
  static values = {
    url: String,
    finished: Boolean,
    interval: { type: Number, default: 1500 }
  }

  connect() {
    if (this.finishedValue || this.isFinished()) return

    // Immediate reconcile: the run may already be terminal by the time the JS
    // boots, which is exactly the instant-failure case this guards against.
    this.frame()?.setAttribute("src", this.urlValue)

    this.timer = setInterval(() => this.tick(), this.intervalValue)
  }

  disconnect() {
    this.stop()
  }

  tick() {
    if (this.isFinished()) {
      this.stop()
      return
    }
    this.frame()?.reload()
  }

  isFinished() {
    return this.element.querySelector("[data-generation-finished]") !== null
  }

  frame() {
    return this.element.querySelector("turbo-frame")
  }

  stop() {
    if (!this.timer) return
    clearInterval(this.timer)
    this.timer = null
  }
}
