import { Controller } from "@hotwired/stimulus"

// Fills the requirement field with a ready-made example so the operator can
// populate a known-good prompt with one click on stage, then edit or submit.
export default class extends Controller {
  static targets = ["field"]

  fill(event) {
    event.preventDefault()
    this.fieldTarget.value = event.params.text
    this.fieldTarget.focus()
  }
}
