// Top-down bed view. Draws only positions the server reports ("pos" events),
// interpolating between samples so the marker moves smoothly at frame rate.
const TRAIL_MAX = 2000
const TRAIL_BATCHES = 20
const GRID_MM = 100
const PAD = 36

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()

export default {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    this.ctx = this.canvas.getContext("2d")
    this.travel = JSON.parse(this.el.dataset.travel)

    const start = {
      x: parseFloat(this.el.dataset.x) || 0,
      y: parseFloat(this.el.dataset.y) || 0,
    }
    this.from = {...start}
    this.to = {...start}
    this.shown = {...start}
    this.t0 = 0
    this.dur = 1
    this.lastSample = performance.now()
    this.state = this.el.dataset.state
    this.jog = [0, 0]

    this.trail = new Float32Array(TRAIL_MAX * 2)
    this.trailHead = 0
    this.trailLen = 0

    this.colors = {
      board: css("--board"),
      boardLine: css("--board-line"),
      boardLineMajor: css("--board-line-major"),
      graphite: css("--graphite"),
      steel: css("--steel"),
      yellow: css("--yellow"),
      red: css("--red"),
      alu: css("--alu"),
    }

    this.handleEvent("pos", (p) => this.sample(p))
    this.handleEvent("travel", ({travel}) => {
      this.travel = travel
      this.fit()
    })
    this.el.addEventListener("bed:clear-trail", () => (this.trailLen = 0))

    this.resize = new ResizeObserver(() => this.fit())
    this.resize.observe(this.el)
    this.fit()

    const frame = (now) => {
      this.draw(now)
      this.raf = requestAnimationFrame(frame)
    }
    this.raf = requestAnimationFrame(frame)
  },

  destroyed() {
    cancelAnimationFrame(this.raf)
    this.resize.disconnect()
  },

  sample({x, y, state, jog}) {
    const now = performance.now()
    // Glide from wherever the marker is drawn now to the new report, over
    // roughly the interval between reports.
    this.from = {...this.shown}
    this.to = {x, y}
    this.t0 = now
    this.dur = Math.min(Math.max(now - this.lastSample, 16), 250)
    this.lastSample = now
    this.state = state
    this.jog = jog
    this.pushTrail(x, y)
  },

  pushTrail(x, y) {
    if (this.trailLen > 0) {
      const last = (this.trailHead - 1 + TRAIL_MAX) % TRAIL_MAX
      const dx = this.trail[last * 2] - x, dy = this.trail[last * 2 + 1] - y
      if (dx * dx + dy * dy < 0.0025) return
    }
    this.trail[this.trailHead * 2] = x
    this.trail[this.trailHead * 2 + 1] = y
    this.trailHead = (this.trailHead + 1) % TRAIL_MAX
    this.trailLen = Math.min(this.trailLen + 1, TRAIL_MAX)
  },

  fit() {
    const dpr = window.devicePixelRatio || 1
    const {width, height} = this.el.getBoundingClientRect()
    this.canvas.width = Math.round(width * dpr)
    this.canvas.height = Math.round(height * dpr)
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    const [[x0, x1], [y0, y1]] = this.travel
    const scale = Math.min((width - PAD * 2) / (x1 - x0), (height - PAD * 2) / (y1 - y0))
    this.view = {
      width, height, scale, x0, x1, y0, y1,
      left: (width - (x1 - x0) * scale) / 2,
      bottom: (height + (y1 - y0) * scale) / 2,
    }
  },

  // Machine mm → canvas px, Y up, origin front-left.
  px(x, y) {
    const v = this.view
    return [v.left + (x - v.x0) * v.scale, v.bottom - (y - v.y0) * v.scale]
  },

  draw(now) {
    const k = Math.min((now - this.t0) / this.dur, 1)
    this.shown = {
      x: this.from.x + (this.to.x - this.from.x) * k,
      y: this.from.y + (this.to.y - this.from.y) * k,
    }

    const {ctx, view: v, colors: c} = this
    ctx.clearRect(0, 0, v.width, v.height)
    this.drawBed()
    this.drawTrail()
    this.drawTool(this.shown)
  },

  drawBed() {
    const {ctx, view: v, colors: c} = this
    const [l, b] = this.px(v.x0, v.y0)
    const [r, t] = this.px(v.x1, v.y1)

    ctx.fillStyle = c.board
    ctx.fillRect(l, t, r - l, b - t)

    ctx.lineWidth = 1
    for (let mm = Math.ceil(v.x0 / GRID_MM) * GRID_MM; mm <= v.x1; mm += GRID_MM) {
      const [x] = this.px(mm, 0)
      ctx.strokeStyle = mm % 500 === 0 ? c.boardLineMajor : c.boardLine
      line(ctx, x, t, x, b)
    }
    for (let mm = Math.ceil(v.y0 / GRID_MM) * GRID_MM; mm <= v.y1; mm += GRID_MM) {
      const [, y] = this.px(0, mm)
      ctx.strokeStyle = mm % 500 === 0 ? c.boardLineMajor : c.boardLine
      line(ctx, l, y, r, y)
    }

    // Travel limits
    ctx.strokeStyle = c.graphite
    ctx.lineWidth = 2
    ctx.strokeRect(l, t, r - l, b - t)

    // Scale labels every 250 mm, outside the board
    ctx.fillStyle = c.steel
    ctx.font = '500 11px "Barlow Semi Condensed", system-ui, sans-serif'
    ctx.textAlign = "center"
    ctx.textBaseline = "top"
    for (let mm = v.x0; mm <= v.x1; mm += 250) ctx.fillText(mm, this.px(mm, 0)[0], b + 6)
    ctx.textAlign = "right"
    ctx.textBaseline = "middle"
    for (let mm = v.y0; mm <= v.y1; mm += 250) ctx.fillText(mm, l - 6, this.px(0, mm)[1])

    // Origin: short X and Y axes from front-left
    const [ox, oy] = this.px(0, 0)
    ctx.strokeStyle = c.graphite
    ctx.lineWidth = 2
    line(ctx, ox, oy, ox + 22, oy)
    line(ctx, ox, oy, ox, oy - 22)
    ctx.fillStyle = c.graphite
    ctx.font = '600 11px Barlow, system-ui, sans-serif'
    ctx.textAlign = "left"
    ctx.textBaseline = "bottom"
    ctx.fillText("X", ox + 25, oy - 2)
    ctx.fillText("Y", ox + 4, oy - 24)
  },

  drawTrail() {
    const {ctx, trail, trailLen} = this
    if (trailLen < 2) return

    const start = (this.trailHead - trailLen + TRAIL_MAX) % TRAIL_MAX
    const per = Math.ceil(trailLen / TRAIL_BATCHES)
    ctx.strokeStyle = this.colors.graphite
    ctx.lineWidth = 1.5
    ctx.lineJoin = "round"

    // Older batches fade out.
    for (let b = 0; b * per < trailLen - 1; b++) {
      ctx.globalAlpha = 0.1 + 0.6 * ((b + 1) * per) / trailLen
      ctx.beginPath()
      for (let i = b * per; i <= Math.min((b + 1) * per, trailLen - 1); i++) {
        const j = (start + i) % TRAIL_MAX
        const [x, y] = this.px(trail[j * 2], trail[j * 2 + 1])
        i === b * per ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
      }
      ctx.stroke()
    }
    ctx.globalAlpha = 1
  },

  drawTool({x, y}) {
    const {ctx, colors: c} = this
    const [px, py] = this.px(x, y)
    const fill = {jogging: c.yellow, alarm: c.red}[this.state] || c.alu
    const dim = ["disconnected", "connecting"].includes(this.state)

    ctx.globalAlpha = dim ? 0.4 : 1

    // Commanded jog direction (what we asked for, not where it is)
    const [jx, jy] = this.jog || [0, 0]
    if (jx || jy) {
      const n = Math.hypot(jx, jy)
      const ex = px + (jx / n) * 34, ey = py - (jy / n) * 34
      ctx.strokeStyle = c.graphite
      ctx.lineWidth = 5
      line(ctx, px, py, ex, ey)
      ctx.strokeStyle = c.yellow
      ctx.lineWidth = 2.5
      line(ctx, px, py, ex, ey)
    }

    // Crosshair + ring at the reported position
    ctx.strokeStyle = c.graphite
    ctx.lineWidth = 1.5
    line(ctx, px - 16, py, px + 16, py)
    line(ctx, px, py - 16, px, py + 16)
    ctx.beginPath()
    ctx.arc(px, py, 8, 0, Math.PI * 2)
    ctx.fillStyle = fill
    ctx.fill()
    ctx.lineWidth = 2
    ctx.stroke()

    ctx.globalAlpha = 1
  },
}

function line(ctx, x1, y1, x2, y2) {
  ctx.beginPath()
  ctx.moveTo(x1, y1)
  ctx.lineTo(x2, y2)
  ctx.stroke()
}
