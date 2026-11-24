// On-screen joystick: a spring-back X/Y stick and a Z slider. Deflection is
// analog (speed proportional, with a dead zone and a curve for fine control
// near the centre); full deflection is the selected jog speed. Same safety
// path as the keyboard: heartbeat while held, stop on release or anything
// that might lose the release (pointer cancel, blur, hidden tab, socket loss).
const DEAD = 0.12
const STEP = 0.02 // resolution sent to the server
const SEND_MS = 40 // at most one jog update per this
const HEARTBEAT_MS = 50

const shape = (m) => (m <= DEAD ? 0 : ((m - DEAD) / (1 - DEAD)) ** 2)
const quantize = (v) => Math.round(v / STEP) * STEP

export default {
  mounted() {
    this.stick = {x: 0, y: 0}
    this.z = 0
    this.sent = null
    this.beat = null
    this.lastSend = 0
    this.trailing = null

    const pad = this.el.querySelector(".cnc-joy-pad")
    const padKnob = pad.querySelector(".cnc-joy-knob")
    const zbar = this.el.querySelector(".cnc-joy-z")
    const zKnob = zbar.querySelector(".cnc-joy-knob")

    this.releases = [
      this.bind(
        pad,
        (e, rect) => {
          const r = rect.width / 2
          let dx = (e.clientX - (rect.left + r)) / r
          let dy = (rect.top + r - e.clientY) / r // Y up
          const m = Math.hypot(dx, dy)
          if (m > 1) (dx /= m), (dy /= m)
          padKnob.style.transform = `translate(${dx * r * 0.78}px, ${-dy * r * 0.78}px)`
          const mm = Math.min(m, 1)
          const k = mm > 0 ? shape(mm) / mm : 0
          this.stick = {x: dx * k, y: dy * k}
        },
        () => {
          padKnob.style.transform = ""
          this.stick = {x: 0, y: 0}
        }
      ),
      this.bind(
        zbar,
        (e, rect) => {
          const h = rect.height / 2
          const dz = Math.max(-1, Math.min(1, (rect.top + h - e.clientY) / h))
          zKnob.style.transform = `translateY(${-dz * h * 0.78}px)`
          this.z = Math.sign(dz) * shape(Math.abs(dz))
        },
        () => {
          zKnob.style.transform = ""
          this.z = 0
        }
      ),
    ]

    this.onLeave = () => this.releaseAll(true)
    this.onVisibility = () => document.hidden && this.releaseAll(true)
    window.addEventListener("blur", this.onLeave)
    window.addEventListener("pagehide", this.onLeave)
    document.addEventListener("visibilitychange", this.onVisibility)
  },

  destroyed() {
    window.removeEventListener("blur", this.onLeave)
    window.removeEventListener("pagehide", this.onLeave)
    document.removeEventListener("visibilitychange", this.onVisibility)
    this.releaseAll(true)
  },

  // Socket lost: the server's dead-man stops the machine; stop locally too.
  disconnected() {
    this.releaseAll(false)
  },

  // Pointer handling for one control. Returns its release function.
  bind(el, move, reset) {
    let pointer = null

    const release = () => {
      if (pointer === null) return
      pointer = null
      el.classList.remove("is-active")
      reset()
    }

    el.addEventListener("pointerdown", (e) => {
      if (pointer !== null || this.el.classList.contains("is-off")) return
      e.preventDefault()
      pointer = e.pointerId
      el.setPointerCapture(pointer)
      el.classList.add("is-active")
      move(e, el.getBoundingClientRect())
      this.update()
    })
    el.addEventListener("pointermove", (e) => {
      if (e.pointerId !== pointer) return
      move(e, el.getBoundingClientRect())
      this.update()
    })
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) {
      el.addEventListener(type, (e) => {
        if (e.pointerId !== pointer) return
        release()
        this.update()
      })
    }

    return release
  },

  releaseAll(notify) {
    this.releases.forEach((release) => release())
    this.stick = {x: 0, y: 0}
    this.z = 0
    if (notify) this.update()
    else this.halt(false)
  },

  update() {
    const v = [quantize(this.stick.x), quantize(this.stick.y), quantize(this.z)]
    if (v.every((c) => c === 0)) return this.halt(true)

    if (!this.beat) {
      this.beat = setInterval(() => this.pushEvent("jog_heartbeat", {}), HEARTBEAT_MS)
    }

    const wait = this.lastSend + SEND_MS - performance.now()
    if (wait > 0) {
      // Rate-limit: send the latest value once the window passes.
      this.trailing ??= setTimeout(() => {
        this.trailing = null
        this.update()
      }, wait)
      return
    }

    // The tier lives on the keyboard hook's element, which LiveView keeps current.
    const tier = document.getElementById("jog-keys")?.dataset.tier || "normal"
    const key = `${v.join(",")},${tier}`
    if (key !== this.sent) {
      const [x, y, z] = v
      this.pushEvent("jog", {x, y, z, tier})
      this.sent = key
      this.lastSend = performance.now()
    }
  },

  halt(notify) {
    clearInterval(this.beat)
    clearTimeout(this.trailing)
    this.beat = null
    this.trailing = null
    if (this.sent && notify) this.pushEvent("jog_stop", {})
    this.sent = null
  },
}
