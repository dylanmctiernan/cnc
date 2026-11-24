// Keyboard jogging. Held arrow / Page keys become an {x, y, z} vector sent to the
// server; while it's non-zero a heartbeat keeps the server-side dead-man
// happy. Anything that might leave a key "stuck" stops the jog instead.
const ARROWS = {
  ArrowLeft: [-1, 0, 0],
  ArrowRight: [1, 0, 0],
  ArrowUp: [0, 1, 0],
  ArrowDown: [0, -1, 0],
  PageUp: [0, 0, 1],
  PageDown: [0, 0, -1],
}
const HEARTBEAT_MS = 50

const typingIn = (el) =>
  el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))

export default {
  mounted() {
    this.held = new Set()
    this.sent = null
    this.beat = null

    this.onKeyDown = (e) => {
      // Esc always stops, even while typing in the console.
      if (e.key === "Escape") {
        this.releaseAll()
        return this.pushEvent("stop", {})
      }
      if (typingIn(e.target)) return
      // macOS drops keyup for other keys while ⌘ is down: never jog with it.
      if (e.metaKey || e.ctrlKey) return this.releaseAll()

      if (e.key in ARROWS) {
        e.preventDefault()
        if (!e.repeat) this.held.add(e.key)
        return this.update(e)
      }
      if (e.key === "Shift" || e.key === "Alt") this.update(e)
    }

    this.onKeyUp = (e) => {
      if (e.key in ARROWS) this.held.delete(e.key)
      this.update(e)
    }

    this.onLeave = () => this.releaseAll()
    this.onVisibility = () => document.hidden && this.releaseAll()

    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("keyup", this.onKeyUp)
    window.addEventListener("blur", this.onLeave)
    window.addEventListener("pagehide", this.onLeave)
    document.addEventListener("visibilitychange", this.onVisibility)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("keyup", this.onKeyUp)
    window.removeEventListener("blur", this.onLeave)
    window.removeEventListener("pagehide", this.onLeave)
    document.removeEventListener("visibilitychange", this.onVisibility)
    this.releaseAll()
  },

  // Socket lost: the server's dead-man stops the machine; stop locally too.
  disconnected() {
    this.held.clear()
    this.halt(false)
  },

  update(e) {
    let x = 0, y = 0, z = 0
    for (const key of this.held) {
      x += ARROWS[key][0]
      y += ARROWS[key][1]
      z += ARROWS[key][2]
    }
    x = Math.sign(x)
    y = Math.sign(y)
    z = Math.sign(z)

    if (x === 0 && y === 0 && z === 0) return this.halt(true)

    const tier = e.shiftKey ? "fast" : e.altKey ? "fine" : this.el.dataset.tier
    const key = `${x},${y},${z},${tier}`
    if (key !== this.sent) {
      this.pushEvent("jog", {x, y, z, tier})
      this.sent = key
    }
    if (!this.beat) {
      this.beat = setInterval(() => this.pushEvent("jog_heartbeat", {}), HEARTBEAT_MS)
    }
  },

  releaseAll() {
    this.held.clear()
    this.halt(true)
  },

  halt(notify) {
    clearInterval(this.beat)
    this.beat = null
    if (this.sent && notify) this.pushEvent("jog_stop", {})
    this.sent = null
  },
}
