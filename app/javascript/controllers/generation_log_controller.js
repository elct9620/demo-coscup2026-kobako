import { Controller } from "@hotwired/stimulus"

// Keeps the live Generation Log pinned to its newest entry. The controller
// element is a bounded scroll viewport (see show.html.erb) that fills the
// remaining viewport height; Turbo Streams append messages into the log target
// nested inside it during the generation loop. Without this the active frontier
// scrolls out of view — on a projector nobody reaches for the scrollbar.
//
// A MutationObserver watches the subtree for appended entries and snaps the
// viewport to the bottom. The scroll is instant (not smooth) so it never lags
// behind a fast stream, which also means there is nothing to gate behind
// prefers-reduced-motion.
export default class extends Controller {
  connect() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  scrollToBottom() {
    this.element.scrollTop = this.element.scrollHeight
  }
}
