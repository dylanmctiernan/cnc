// Terminal-style command input: Enter sends (via the form's phx-submit),
// the field clears, and ↑/↓ walk back through what you've sent.
export default {
  mounted() {
    this.input = this.el.querySelector("input")
    this.history = []
    this.cursor = 0

    this.el.addEventListener("submit", () => {
      const line = this.input.value.trim()
      if (line && line !== this.history[this.history.length - 1]) this.history.push(line)
      this.cursor = this.history.length
      // After LiveView has read the form.
      setTimeout(() => (this.input.value = ""))
    })

    this.input.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return
      e.preventDefault()
      const step = e.key === "ArrowUp" ? -1 : 1
      this.cursor = Math.min(Math.max(this.cursor + step, 0), this.history.length)
      this.input.value = this.history[this.cursor] ?? ""
    })
  },
}
