import {Progress} from "./progress"
// Top-down bed view plus a Z gauge. Draws only positions the server reports
// ("pos" events), interpolating between samples so the marker moves
// smoothly at frame rate. Colour means state only: yellow moving, red alarm.
const TRAIL_MAX = 2000
const TRAIL_BATCHES = 20
const GRID_MM = 100
const PAD = 40
const GAUGE = 72 // px reserved on the right for the Z gauge
const METERS = 72 // px reserved on the left for the X/Y and Z speed meters
const METERS_COMPACT = 56
// The mono face from the design tokens (--font-mono), read once.
const FONT =
  getComputedStyle(document.documentElement).getPropertyValue("--font-mono").trim() ||
  "ui-monospace, monospace"

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
    // Speed meters: target values from the server, shown values eased toward
    // them each frame so 20 Hz reports don't make the bars jitter.
    this.speed = null
    this.speedShown = {xy: 0, z: 0}
    this.lastFrame = 0

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
      path: css("--path"),
    }

    // Loaded G-code toolpath (work coordinates), drawn into an offscreen
    // canvas and only redrawn when the file, the work zero or the view
    // changes: a file can have hundreds of thousands of segments.
    this.program = null
    this.pathCache = document.createElement("canvas")
    this.pathKey = null
    // A running job: what's been cut is drawn faint over the path, into its
    // own cache, a few new segments at a time
    this.progress = new Progress()
    this.doneCache = document.createElement("canvas")
    this.doneKey = null
    this.doneDrawn = 0
    this.handleEvent("program", ({path}) => {
      this.program = path ? decodePath(path) : null
      this.pathKey = null
      this.progress.reset()
      this.doneKey = null
      this.fit()
    })
    // "bed": the whole bed. "file": the loaded file's area, following the
    // work zero but not the tool (which may be off view).
    this.zoomMode = this.el.dataset.zoom || "bed"
    this.handleEvent("zoom", ({mode}) => {
      this.zoomMode = mode
      this.fit()
    })

    this.handleEvent("pos", (p) => this.sample(p))
    this.handleEvent("travel", ({travel}) => {
      this.travel = travel
      this.fit()
    })
    this.el.addEventListener("bed:clear-trail", () => (this.trailLen = 0))

    this.resize = new ResizeObserver(() => this.fit())
    this.resize.observe(this.el)
    this.fit()

    // Built anew when the view switches back: ask for the file and position
    if (!this.mini) this.pushEvent("viewport_ready", {})

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

  sample({x, y, z, state, jog, wco, speed, job}) {
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
    const wcoChanged = JSON.stringify(wco) !== JSON.stringify(this.wco)
    this.wco = wco
    if (wcoChanged && this.view && this.view.zoomed) this.fit()
    if (speed) this.speed = speed
    this.pushTrail(x, y)
    if (this.program) this.progress.update(this.program.data, job, {x, y, z}, wco)
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
    const meters = this.mini ? 0 : this.compact ? METERS_COMPACT : METERS
    const room = width - meters - (this.mini ? 0 : this.compact ? 48 : GAUGE)
    const file = !this.mini && this.zoomMode === "file" && this.fileWindow()
    const w = file || {x0, x1, y0, y1}
    const scale = Math.min((room - pad * 2) / (w.x1 - w.x0), (height - pad * 2) / (w.y1 - w.y0))
    const winW = (w.x1 - w.x0) * scale
    const winH = (w.y1 - w.y0) * scale
    // The instruments (speed meters, Z gauge) keep the whole bed's height
    // whatever the zoom, so zooming never moves them
    const bedH = (y1 - y0) * Math.min((room - pad * 2) / (x1 - x0), (height - pad * 2) / (y1 - y0))
    this.view = {
      width, height, scale, x0, x1, y0, y1, z0, z1,
      // The window drawn: the bed, or the file's area when zoomed
      wx0: w.x0, wy0: w.y0, wx1: w.x1, wy1: w.y1,
      zoomed: !!file,
      left: meters + (room - winW) / 2,
      bottom: (height + winH) / 2,
      top: (height - winH) / 2,
      itop: (height - bedH) / 2,
      ibottom: (height + bedH) / 2,
      gaugeX: meters + room + 8,
      meters,
      mapRight: meters + room,
    }
    this.pathKey = null
  },

  // Machine mm → canvas px, Y up, origin front-left, within the view window.
  px(x, y) {
    const v = this.view
    return [v.left + (x - v.wx0) * v.scale, v.bottom - (y - v.wy0) * v.scale]
  },

  // The loaded file's X/Y area in machine coordinates (at the current work
  // zero), padded. Null if there's nothing to zoom to.
  fileWindow() {
    if (!this.program || !this.program.box) return null
    const [ox, oy] = this.wco || [0, 0, 0]
    const b = this.program.box
    let x0 = b.x0 + ox, x1 = b.x1 + ox, y0 = b.y0 + oy, y1 = b.y1 + oy
    const pad = Math.max(0.08 * Math.max(x1 - x0, y1 - y0), 5)
    x0 -= pad; x1 += pad; y0 -= pad; y1 += pad
    // At least 20 mm across, so a tiny file isn't blown up absurdly
    const grow = (a, b) => { const m = Math.max(0, 20 - (b - a)) / 2; return [a - m, b + m] }
    ;[x0, x1] = grow(x0, x1)
    ;[y0, y1] = grow(y0, y1)
    return {x0, x1, y0, y1}
  },

  // Z mm → canvas y on the gauge (top of travel at the top).
  zy(z) {
    const v = this.view
    return v.ibottom - ((z - v.z0) / (v.z1 - v.z0)) * (v.ibottom - v.itop)
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
    // Zoomed, the bed and everything on it is clipped to the map area so it
    // doesn't run under the speed meters or the Z gauge.
    ctx.save()
    ctx.beginPath()
    ctx.rect(v.meters, 0, v.mapRight - v.meters, v.height)
    ctx.clip()
    this.drawBed()
    this.drawProgram()
    this.drawWorkOrigin()
    this.drawTrail()
    this.drawTool(this.shown)
    ctx.restore()
    if (!this.mini) {
      this.drawGauge(this.shown.z)
      this.drawSpeed(now)
    }
  },

  drawProgram() {
    if (!this.program) return
    const {view: v} = this
    const wco = this.wco || [0, 0, 0]
    const dpr = window.devicePixelRatio || 1
    const key = [v.width, v.height, v.scale, v.left, v.bottom, v.wx0, v.wy0, dpr, ...wco].join(",")

    if (key !== this.pathKey) {
      this.pathKey = key
      const cache = this.pathCache
      cache.width = Math.round(v.width * dpr)
      cache.height = Math.round(v.height * dpr)
      const ctx = cache.getContext("2d")
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      this.renderProgram(ctx, wco)
    }
    this.ctx.drawImage(this.pathCache, 0, 0, v.width, v.height)
    this.drawDone(key, dpr, wco)
  },

  // Cut so far: each finished segment painted over in the bed's colour and
  // redrawn faint, so what's left stands out. Only new segments are drawn;
  // the cache is rebuilt when the view or the job starts over.
  drawDone(key, dpr, [ox, oy]) {
    const done = this.progress.done
    if (done <= 0) return
    const {view: v, colors: c} = this
    const cache = this.doneCache
    if (key !== this.doneKey || done < this.doneDrawn) {
      this.doneKey = key
      this.doneDrawn = 0
      cache.width = Math.round(v.width * dpr)
      cache.height = Math.round(v.height * dpr)
    }
    if (done > this.doneDrawn) {
      const ctx = cache.getContext("2d")
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      const d = this.program.data
      const erase = new Path2D(), faint = new Path2D()
      for (let i = Math.max(1, this.doneDrawn + 1); i <= done; i++) {
        if (d[i * 4] < 0) continue
        const [ax, ay] = this.px(d[(i - 1) * 4 + 1] + ox, d[(i - 1) * 4 + 2] + oy)
        const [bx, by] = this.px(d[i * 4 + 1] + ox, d[i * 4 + 2] + oy)
        for (const p of [erase, faint]) {
          p.moveTo(ax, ay)
          p.lineTo(bx, by)
        }
      }
      ctx.lineCap = "round"
      ctx.strokeStyle = c.bed
      ctx.lineWidth = 3
      ctx.stroke(erase)
      ctx.strokeStyle = c.dim
      ctx.globalAlpha = 0.45
      ctx.lineWidth = 1
      ctx.stroke(faint)
      ctx.globalAlpha = 1
      this.doneDrawn = done
    }
    this.ctx.drawImage(cache, 0, 0, v.width, v.height)
  },

  // Rapids dashed and quiet; cuts in the path colour, in depth bands that
  // get more opaque the deeper they go (the deepest is solid).
  renderProgram(ctx, [ox, oy]) {
    const {colors: c} = this
    const {data, zMin, zMax} = this.program
    const BANDS = 5
    const rapids = new Path2D()
    const bands = Array.from({length: BANDS}, () => new Path2D())
    const span = zMax - zMin

    let [px, py] = this.px(data[1] + ox, data[2] + oy)
    for (let i = 4; i < data.length; i += 4) {
      const [qx, qy] = this.px(data[i + 1] + ox, data[i + 2] + oy)
      if (data[i] === 0) {
        rapids.moveTo(px, py)
        rapids.lineTo(qx, qy)
      } else {
        const depth = span > 0 ? (zMax - data[i + 3]) / span : 1
        const band = bands[Math.min(BANDS - 1, Math.floor(depth * BANDS))]
        band.moveTo(px, py)
        band.lineTo(qx, qy)
      }
      px = qx
      py = qy
    }

    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    ctx.setLineDash([4, 4])
    ctx.strokeStyle = c.dim
    ctx.globalAlpha = 0.6
    ctx.lineWidth = 1
    ctx.stroke(rapids)
    ctx.setLineDash([])
    ctx.strokeStyle = c.path
    ctx.lineWidth = 1.5
    bands.forEach((band, k) => {
      ctx.globalAlpha = 0.35 + (0.65 * (k + 1)) / BANDS
      ctx.stroke(band)
    })
    ctx.globalAlpha = 1
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

    // Grid: 100 mm on the whole bed; zoomed, the finest step that keeps
    // lines at least ~24 px apart, with every 5th line stronger.
    const grid = v.zoomed
      ? [1, 2, 5, 10, 20, 50, 100, 250].find((s) => s * v.scale >= 24) || 500
      : GRID_MM
    const major = v.zoomed ? grid * 5 : 500
    ctx.lineWidth = 1
    for (let mm = Math.ceil(Math.max(v.x0, v.wx0) / grid) * grid; mm <= Math.min(v.x1, v.wx1); mm += grid) {
      const [x] = this.px(mm, 0)
      ctx.strokeStyle = mm % major === 0 ? c.gridMajor : c.grid
      line(ctx, x, t, x, b)
    }
    for (let mm = Math.ceil(Math.max(v.y0, v.wy0) / grid) * grid; mm <= Math.min(v.y1, v.wy1); mm += grid) {
      const [, y] = this.px(0, mm)
      ctx.strokeStyle = mm % major === 0 ? c.gridMajor : c.grid
      line(ctx, l, y, r, y)
    }
    this.gridStep = grid

    // Travel limits
    ctx.strokeStyle = c.edge
    ctx.lineWidth = 1.5
    ctx.strokeRect(l, t, r - l, b - t)

    if (this.mini) return

    // Scale: every 250 mm on the whole bed (ends only when compact); zoomed,
    // at the major grid lines along the window's bottom and left edges.
    ctx.fillStyle = c.dim
    ctx.font = `11px ${FONT}`
    ctx.textAlign = "center"
    ctx.textBaseline = "top"
    if (v.zoomed) {
      const [, wb] = this.px(0, v.wy0)
      const [wl] = this.px(v.wx0, 0)
      const lx = this.compact ? major * 2 : major
      for (let mm = Math.ceil(v.wx0 / lx) * lx; mm <= v.wx1; mm += lx) ctx.fillText(mm, this.px(mm, 0)[0], wb + 4)
      ctx.textAlign = "left"
      ctx.textBaseline = "middle"
      for (let mm = Math.ceil(v.wy0 / lx) * lx; mm <= v.wy1; mm += lx) ctx.fillText(mm, wl + 4, this.px(0, mm)[1])
    } else {
      const step = this.compact ? v.x1 - v.x0 : 250
      for (let mm = v.x0; mm <= v.x1; mm += step) ctx.fillText(mm, this.px(mm, 0)[0], b + 4)
      ctx.textAlign = "right"
      ctx.textBaseline = "middle"
      const ystep = this.compact ? v.y1 - v.y0 : 250
      for (let mm = v.y0; mm <= v.y1; mm += ystep) ctx.fillText(mm, l - 4, this.px(0, mm)[1])
    }

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

    // Commanded X/Y jog (asked for, not where it is): direction, and length
    // for how far the stick is pushed, like the Z line on the gauge. It
    // always clears the marker; a faint circle marks full deflection.
    const [jx, jy] = this.jog || [0, 0, 0]
    if (jx || jy) {
      const n = Math.hypot(jx, jy)
      const ring = this.mini ? 4 : 7
      const full = this.mini ? 14 : 34
      const len = ring + 3 + (full - ring - 3) * Math.min(n, 1)
      if (!this.mini) {
        ctx.strokeStyle = c.gridMajor
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.arc(px, py, full, 0, Math.PI * 2)
        ctx.stroke()
      }
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

  // X/Y and Z speed as two bullet graphs (Stephen Few): the scale runs from
  // 0 to the machine's max rate, quiet ticks mark each tier's full-stick
  // speed, the selected tier's tick is emphasised (where a full push lands),
  // and the bar is the current speed in the same state colour as the tool.
  drawSpeed(now) {
    const {ctx, view: v, colors: c} = this
    const sp = this.speed
    if (!sp) return

    // Ease toward the reported speeds (time constant ~80 ms)
    const dt = Math.min(now - (this.lastFrame || now), 100)
    this.lastFrame = now
    const k = 1 - Math.exp(-dt / 80)
    this.speedShown.xy += (sp.xy - this.speedShown.xy) * k
    this.speedShown.z += (sp.z - this.speedShown.z) * k

    const w = this.compact ? 8 : 10
    const step = v.meters / 2
    const meters = [
      {label: "XY", color: c.dim, value: this.speedShown.xy, target: sp.xy, max: sp.max[0], key: "xy"},
      {label: "Z", color: c.z, value: this.speedShown.z, target: sp.z, max: sp.max[1], key: "z"},
    ]
    const top = v.itop, bottom = v.ibottom, h = bottom - top
    const vy = (mm, max) => bottom - (Math.min(Math.max(mm, 0), max) / max) * h

    meters.forEach((m, i) => {
      const x = step * i + (step - w) / 2 + 4

      ctx.fillStyle = c.bed
      ctx.fillRect(x, top, w, h)

      // Tier ticks; the selected tier's is the comparative marker
      for (const t of sp.tiers) {
        const ty = vy(t[m.key], m.max)
        const selected = t.name === sp.tier
        ctx.strokeStyle = selected ? c.text : c.dim
        ctx.lineWidth = selected ? 2 : 1
        line(ctx, x, ty, x + w, ty)
        if (selected) {
          ctx.fillStyle = c.text
          ctx.beginPath()
          ctx.moveTo(x - 2, ty)
          ctx.lineTo(x - 7, ty - 4)
          ctx.lineTo(x - 7, ty + 4)
          ctx.closePath()
          ctx.fill()
        }
      }

      // Current speed
      if (m.value > 0.5) {
        const y = vy(m.value, m.max)
        ctx.fillStyle = this.markerColor()
        ctx.fillRect(x + 2, y, w - 4, bottom - y)
      }

      ctx.strokeStyle = c.edge
      ctx.lineWidth = 1.5
      ctx.strokeRect(x, top, w, h)

      // Label above, value (mm/min) below
      ctx.textAlign = "center"
      ctx.textBaseline = "bottom"
      ctx.font = `700 11px ${FONT}`
      ctx.fillStyle = m.color
      ctx.fillText(m.label, x + w / 2, top - 6)
      ctx.textBaseline = "top"
      ctx.font = `${this.compact ? 10 : 11}px ${FONT}`
      ctx.fillStyle = m.target > 0.5 ? c.text : c.dim
      ctx.fillText(String(Math.round(m.target)), x + w / 2, bottom + 6)
    })

    if (!this.compact) {
      ctx.fillStyle = c.dim
      ctx.font = `10px ${FONT}`
      ctx.textAlign = "center"
      ctx.textBaseline = "top"
      ctx.fillText("mm/min", v.meters / 2 + 4, bottom + 20)
    }
  },

  drawGauge(z) {
    const {ctx, view: v, colors: c} = this
    const x = v.gaugeX + 22, w = 14
    const top = v.itop, bottom = v.ibottom

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

// Base64 float32 [kind, x, y, z] vertices (kind -1 for the start point, 0
// rapid, 1 feed) -> the array and the depth range of the cutting moves.
function decodePath(b64) {
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  const data = new Float32Array(bytes.buffer)
  let zMin = Infinity, zMax = -Infinity
  for (let i = 4; i < data.length; i += 4) {
    if (data[i] === 1) {
      zMin = Math.min(zMin, data[i + 3])
      zMax = Math.max(zMax, data[i + 3])
    }
  }
  if (zMin === Infinity) zMin = zMax = 0
  // X/Y extent of all moves (work coordinates), for zooming to the file
  let box = null
  for (let i = 0; i < data.length; i += 4) {
    const x = data[i + 1], y = data[i + 2]
    if (!box) box = {x0: x, x1: x, y0: y, y1: y}
    else {
      if (x < box.x0) box.x0 = x
      if (x > box.x1) box.x1 = x
      if (y < box.y0) box.y0 = y
      if (y > box.y1) box.y1 = y
    }
  }
  return {data, zMin, zMax, box}
}

function line(ctx, x1, y1, x2, y2) {
  ctx.beginPath()
  ctx.moveTo(x1, y1)
  ctx.lineTo(x2, y2)
  ctx.stroke()
}
