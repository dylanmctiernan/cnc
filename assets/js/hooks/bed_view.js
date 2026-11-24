// Top-down bed view plus a Z gauge. Draws only positions the server reports
// ("pos" events), interpolating between samples so the marker moves
// smoothly at frame rate. Colour means state only: yellow moving, red alarm.
const TRAIL_MAX = 2000
const TRAIL_BATCHES = 20
const GRID_MM = 100
const PAD = 40
const GAUGE = 72 // px reserved on the right for the Z gauge
const FONT = '"JetBrains Mono", ui-monospace, monospace'

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()

export default {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    this.ctx = this.canvas.getContext("2d")
    this.travel = JSON.parse(this.el.dataset.travel)
    // Mini-map: no labels, no Z gauge, small marker
    this.mini = this.el.dataset.mini === "true"

    const start = {
      x: parseFloat(this.el.dataset.x) || 0,
      y: parseFloat(this.el.dataset.y) || 0,
      z: parseFloat(this.el.dataset.z) || 0,
    }
    this.from = {...start}
    this.to = {...start}
    this.shown = {...start}
    this.t0 = 0
    this.dur = 1
    this.lastSample = performance.now()
    this.state = this.el.dataset.state
    this.jog = [0, 0, 0]
    this.wco = null

    this.trail = new Float32Array(TRAIL_MAX * 2)
    this.trailHead = 0
    this.trailLen = 0

    this.colors = {
      bed: css("--bed"),
      grid: css("--grid"),
      gridMajor: css("--grid-major"),
      edge: css("--edge"),
      dim: css("--text-dim"),
      text: css("--text"),
      bg: css("--bg"),
      yellow: css("--yellow"),
      red: css("--red"),
      ok: css("--ok"),
      move: css("--move"),
      warn: css("--warn"),
      x: css("--x"),
      y: css("--y"),
      z: css("--z"),
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

  sample({x, y, z, state, jog, wco}) {
    const now = performance.now()
    // Glide from where the marker is drawn now to the new report, over
    // roughly the interval between reports.
    this.from = {...this.shown}
    this.to = {x, y, z}
    this.t0 = now
    this.dur = Math.min(Math.max(now - this.lastSample, 16), 250)
    this.lastSample = now
    this.state = state
    this.jog = jog
    this.wco = wco
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

    const [[x0, x1], [y0, y1], [z0, z1] = [-100, 0]] = this.travel
    // Drawn small (phone landscape, Split View): tighter margins, end labels only
    this.compact = !this.mini && (height < 300 || width < 380)
    const pad = this.mini ? 3 : this.compact ? 22 : PAD
    const room = width - (this.mini ? 0 : this.compact ? 48 : GAUGE)
    const scale = Math.min((room - pad * 2) / (x1 - x0), (height - pad * 2) / (y1 - y0))
    const bedH = (y1 - y0) * scale
    this.view = {
      width, height, scale, x0, x1, y0, y1, z0, z1,
      left: (room - (x1 - x0) * scale) / 2,
      bottom: (height + bedH) / 2,
      top: (height - bedH) / 2,
      gaugeX: room + 8,
    }
  },

  // Machine mm → canvas px, Y up, origin front-left.
  px(x, y) {
    const v = this.view
    return [v.left + (x - v.x0) * v.scale, v.bottom - (y - v.y0) * v.scale]
  },

  // Z mm → canvas y on the gauge (top of travel at the top).
  zy(z) {
    const v = this.view
    return v.bottom - ((z - v.z0) / (v.z1 - v.z0)) * (v.bottom - v.top)
  },

  draw(now) {
    const k = Math.min((now - this.t0) / this.dur, 1)
    const lerp = (a, b) => a + (b - a) * k
    this.shown = {
      x: lerp(this.from.x, this.to.x),
      y: lerp(this.from.y, this.to.y),
      z: lerp(this.from.z, this.to.z),
    }

    const {ctx, view: v} = this
    ctx.clearRect(0, 0, v.width, v.height)
    this.drawBed()
    this.drawWorkOrigin()
    this.drawTrail()
    this.drawTool(this.shown)
    if (!this.mini) this.drawGauge(this.shown.z)
  },

  markerColor() {
    const c = this.colors
    return {idle: c.ok, jogging: c.move, homing: c.warn, busy: c.warn, alarm: c.red}[this.state] || c.text
  },

  drawBed() {
    const {ctx, view: v, colors: c} = this
    const [l, b] = this.px(v.x0, v.y0)
    const [r, t] = this.px(v.x1, v.y1)

    ctx.fillStyle = c.bed
    ctx.fillRect(l, t, r - l, b - t)

    ctx.lineWidth = 1
    for (let mm = Math.ceil(v.x0 / GRID_MM) * GRID_MM; mm <= v.x1; mm += GRID_MM) {
      const [x] = this.px(mm, 0)
      ctx.strokeStyle = mm % 500 === 0 ? c.gridMajor : c.grid
      line(ctx, x, t, x, b)
    }
    for (let mm = Math.ceil(v.y0 / GRID_MM) * GRID_MM; mm <= v.y1; mm += GRID_MM) {
      const [, y] = this.px(0, mm)
      ctx.strokeStyle = mm % 500 === 0 ? c.gridMajor : c.grid
      line(ctx, l, y, r, y)
    }

    // Travel limits
    ctx.strokeStyle = c.edge
    ctx.lineWidth = 1.5
    ctx.strokeRect(l, t, r - l, b - t)

    if (this.mini) return

    // Scale every 250 mm, outside the bed
    ctx.fillStyle = c.dim
    ctx.font = `11px ${FONT}`
    ctx.textAlign = "center"
    ctx.textBaseline = "top"
    const step = this.compact ? v.x1 - v.x0 : 250
    for (let mm = v.x0; mm <= v.x1; mm += step) ctx.fillText(mm, this.px(mm, 0)[0], b + 4)
    ctx.textAlign = "right"
    ctx.textBaseline = "middle"
    const ystep = this.compact ? v.y1 - v.y0 : 250
    for (let mm = v.y0; mm <= v.y1; mm += ystep) ctx.fillText(mm, l - 4, this.px(0, mm)[1])

    // Origin axes, front-left, in axis colours
    const [ox, oy] = this.px(0, 0)
    ctx.lineWidth = 2
    ctx.strokeStyle = c.x
    line(ctx, ox, oy, ox + 28, oy)
    ctx.strokeStyle = c.y
    line(ctx, ox, oy, ox, oy - 28)
    ctx.font = `700 11px ${FONT}`
    ctx.textAlign = "left"
    ctx.textBaseline = "bottom"
    ctx.fillStyle = c.x
    ctx.fillText("X", ox + 31, oy - 1)
    ctx.fillStyle = c.y
    ctx.fillText("Y", ox + 4, oy - 30)
  },

  // Work origin (G54): small axes and a label, in neutral text colour.
  drawWorkOrigin() {
    if (!this.wco) return
    const [wx, wy] = this.wco
    const {ctx, colors: c, view: v} = this
    if (wx === v.x0 && wy === v.y0) return // same as the machine origin
    const [ox, oy] = this.px(wx, wy)
    ctx.strokeStyle = c.text
    ctx.lineWidth = 1.5
    const arm = this.mini ? 6 : 18
    line(ctx, ox, oy, ox + arm, oy)
    line(ctx, ox, oy, ox, oy - arm)
    ctx.beginPath()
    ctx.arc(ox, oy, 3, 0, Math.PI * 2)
    ctx.fillStyle = c.text
    ctx.fill()
    if (this.mini) return
    ctx.font = `500 11px ${FONT}`
    ctx.textAlign = "left"
    ctx.textBaseline = "top"
    ctx.fillText("work 0", ox + 5, oy + 4)
  },

  drawTrail() {
    const {ctx, trail, trailLen} = this
    if (trailLen < 2) return

    const start = (this.trailHead - trailLen + TRAIL_MAX) % TRAIL_MAX
    const per = Math.ceil(trailLen / TRAIL_BATCHES)
    ctx.strokeStyle = this.colors.dim
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
    const dim = ["disconnected", "connecting"].includes(this.state)
    ctx.globalAlpha = dim ? 0.4 : 1

    // Commanded X/Y jog direction (asked for, not where it is)
    const [jx, jy] = this.jog || [0, 0, 0]
    if (jx || jy) {
      const n = Math.hypot(jx, jy)
      const len = this.mini ? 14 : 34
      const ex = px + (jx / n) * len, ey = py - (jy / n) * len
      ctx.strokeStyle = c.bg
      ctx.lineWidth = 5
      line(ctx, px, py, ex, ey)
      ctx.strokeStyle = c.move
      ctx.lineWidth = 2.5
      line(ctx, px, py, ex, ey)
    }

    // Crosshair + ring at the reported position
    ctx.strokeStyle = c.text
    ctx.lineWidth = 1
    if (!this.mini) {
      line(ctx, px - 18, py, px - 10, py)
      line(ctx, px + 10, py, px + 18, py)
      line(ctx, px, py - 18, px, py - 10)
      line(ctx, px, py + 10, px, py + 18)
    }
    ctx.beginPath()
    ctx.arc(px, py, this.mini ? 4 : 7, 0, Math.PI * 2)
    ctx.fillStyle = this.markerColor()
    ctx.fill()
    ctx.strokeStyle = c.bg
    ctx.lineWidth = 2
    ctx.stroke()

    ctx.globalAlpha = 1
  },

  drawGauge(z) {
    const {ctx, view: v, colors: c} = this
    const x = v.gaugeX + 22, w = 14
    const top = v.top, bottom = v.bottom

    ctx.fillStyle = c.bed
    ctx.fillRect(x, top, w, bottom - top)
    ctx.strokeStyle = c.edge
    ctx.lineWidth = 1.5
    ctx.strokeRect(x, top, w, bottom - top)

    // Ticks every 25 mm, labels at the ends and middle
    ctx.fillStyle = c.dim
    ctx.strokeStyle = c.grid
    ctx.lineWidth = 1
    ctx.font = `11px ${FONT}`
    ctx.textAlign = "right"
    ctx.textBaseline = "middle"
    const span = v.z1 - v.z0
    for (let mm = v.z1; mm >= v.z0 - 1e-6; mm -= 25) {
      const y = this.zy(mm)
      line(ctx, x, y, x + w, y)
      if (mm === v.z1 || mm === v.z0 || Math.abs(mm - (v.z0 + span / 2)) < 1e-6) ctx.fillText(Math.round(mm), x - 4, y)
    }
    ctx.textAlign = "center"
    ctx.textBaseline = "bottom"
    ctx.font = `700 11px ${FONT}`
    ctx.fillStyle = c.z
    ctx.fillText("Z", x + w / 2, top - 6)

    // Work Z0
    if (this.wco) {
      const wz = this.wco[2]
      if (wz >= v.z0 && wz <= v.z1 && wz !== v.z1) {
        const wy = this.zy(wz)
        ctx.strokeStyle = c.text
        ctx.lineWidth = 1.5
        line(ctx, x - 6, wy, x + w + 2, wy)
        ctx.fillStyle = c.text
        ctx.font = `11px ${FONT}`
        ctx.textAlign = "right"
        ctx.textBaseline = "middle"
        ctx.fillText("W0", x - 8, wy)
      }
    }

    // Tool height: a bar across the gauge with a pointer
    const dim = ["disconnected", "connecting"].includes(this.state)
    ctx.globalAlpha = dim ? 0.4 : 1
    const y = this.zy(Math.min(Math.max(z, v.z0), v.z1))
    ctx.fillStyle = this.markerColor()
    ctx.fillRect(x - 3, y - 2, w + 6, 4)
    ctx.beginPath()
    ctx.moveTo(x + w + 4, y)
    ctx.lineTo(x + w + 12, y - 6)
    ctx.lineTo(x + w + 12, y + 6)
    ctx.closePath()
    ctx.fill()

    // Commanded Z direction
    const jz = (this.jog || [0, 0, 0])[2]
    if (jz) {
      ctx.strokeStyle = c.move
      ctx.lineWidth = 2.5
      line(ctx, x + w / 2, y, x + w / 2, y - jz * 26)
    }
    ctx.globalAlpha = 1
  },
}

function line(ctx, x1, y1, x2, y2) {
  ctx.beginPath()
  ctx.moveTo(x1, y1)
  ctx.lineTo(x2, y2)
  ctx.stroke()
}
