// The 3D viewport (CNCWeb.UI.viewport): the machine in three.js, Z up, in
// machine coordinates (mm). The bed and its grid, the travel envelope, the
// work zero (X/Y/Z axes), the loaded toolpath (cuts solid, rapids faint) and
// the tool. Orbit, pan and zoom; Iso/Top/Front frame the part (if any),
// Machine the whole travel. It renders only when
// something changed, so an idle view costs nothing.
//
// The standard machine-view events (the 2D bed view listens to the same):
//   "pos"     {x, y, z, wco}  machine position, work offset (or null)
//   "program" {path}          base64 float32 [kind, x, y, z] in work
//                             coordinates (kind -1 start, 0 rapid, 1 cut)
//   "travel"  {travel}        [[x0, x1], [y0, y1], [z0, z1]]
// On mount it pushes "viewport_ready" so the page sends what it has now.
import * as THREE from "three"
import {OrbitControls} from "three/examples/jsm/controls/OrbitControls.js"
import {Progress, onSegment} from "./progress"

// The tool drawn to scale (mm): a 1/4" bit, its stick-out, the collet nut
const BIT_D = 6.35
const BIT_OUT = 25
const NUT_D = 20
const NUT_H = 12

// Points kept in the jog trail
const TRAIL_MAX = 1500

const token = (name, fallback) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback

export default {
  mounted() {
    this.travel = JSON.parse(this.el.dataset.travel || "[[0,1250],[0,1250],[-100,0]]")
    this.wco = [0, 0, 0]
    this.pathData = null

    const canvas = this.el.querySelector("canvas")
    this.renderer = new THREE.WebGLRenderer({canvas, antialias: true, alpha: true})
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))

    this.scene = new THREE.Scene()
    // Perspective for Iso and Machine; orthographic for Top and Front (true
    // views: things line up and can be judged by eye, as in CAD)
    this.persp = new THREE.PerspectiveCamera(40, 1, 1, 20000)
    this.ortho = new THREE.OrthographicCamera(-1, 1, 1, -1, -20000, 20000)
    for (const c of [this.persp, this.ortho]) c.up.set(0, 0, 1)
    this.camera = this.persp
    this.orthoHalf = 100

    this.controls = new OrbitControls(this.camera, canvas)
    this.controls.enableDamping = false
    this.controls.screenSpacePanning = true
    this.controls.addEventListener("change", () => this.render())
    // Orbiting, panning or zooming by hand: keep that camera
    this.controls.addEventListener("start", () => (this.userMoved = true))

    this.colors = {
      bed: new THREE.Color(token("--bed", "#2a2f33")),
      grid: new THREE.Color(token("--grid", "#343a3f")),
      gridMajor: new THREE.Color(token("--grid-major", "#424a51")),
      edge: new THREE.Color(token("--edge", "#7a848c")),
      x: new THREE.Color(token("--x", "#ff6b6b")),
      y: new THREE.Color(token("--y", "#51cf66")),
      z: new THREE.Color(token("--z", "#4dabf7")),
      path: new THREE.Color(token("--path", "#c792ea")),
      rapid: new THREE.Color(token("--text-faint", "#5a636b")),
      // The trace (cut so far), green as in 2D; the plan dims to a ghost under it
      done: new THREE.Color(token("--path-done", "#6cc58a")),
      tool: new THREE.Color(token("--text", "#e4e7e9")),
      move: new THREE.Color(token("--move", "#4dabf7")),
    }

    this.scene.add(new THREE.AmbientLight(0xffffff, 0.9))
    const sun = new THREE.DirectionalLight(0xffffff, 0.6)
    sun.position.set(1, -1, 2)
    this.scene.add(sun)

    this.machine = new THREE.Group()
    this.work = new THREE.Group()
    this.scene.add(this.machine, this.work)
    this.buildMachine()
    this.buildTool()

    this.resizer = new ResizeObserver(() => this.resize())
    this.resizer.observe(this.el)
    this.resize()
    this.view("iso")

    this.progress = new Progress()
    this.handleEvent("pos", ({x, y, z, wco, job}) => {
      this.running = !!job
      this.glideTo(x, y, z)
      // The jog trail (the Jog trail setting): only while jogging by hand
      if (this.el.dataset.trail === "true" && !job) this.pushTrail(x, y, z)
      else if (this.trail.length) this.clearTrail()
      if (this.pathData) {
        const before = this.progress.done
        if (this.progress.update(this.pathData, job, {x, y, z}, wco || this.wco) !== before) this.paintDone()
      }
      if (wco && (wco[0] !== this.wco[0] || wco[1] !== this.wco[1] || wco[2] !== this.wco[2])) {
        this.setWork(wco)
        return this.reframe()
      }
      this.render()
    })
    this.handleEvent("program", ({path}) => {
      this.pathData = path ? decode(path) : null
      this.buildPath()
      // Coming back mid-job: show what's been cut so far
      this.paintDone()
      this.reframe()
    })
    // The bit in the spindle: draw the tool as it is (null: a 1/4" end mill)
    this.handleEvent("bit", ({bit}) => {
      this.bit = bit
      this.buildTool()
      this.render()
    })
    // The stock: a box in work coordinates (its top at Z 0), or null
    this.handleEvent("stock", ({box}) => {
      this.buildStock(box)
      this.render()
    })
    this.handleEvent("travel", ({travel}) => {
      this.travel = travel
      this.buildMachine()
      this.reframe()
    })

    this.trail = []
    this.el.addEventListener("viewport:clear-trail", () => this.clearTrail())

    // Iso / Top / Front buttons (JS.dispatch from the component)
    this.onView = (e) => this.view(e.detail.view)
    this.el.addEventListener("viewport:view", this.onView)

    this.pushEvent("viewport_ready", {})
  },

  destroyed() {
    this.resizer.disconnect()
    this.el.removeEventListener("viewport:view", this.onView)
    this.controls.dispose()
    this.renderer.dispose()
  },

  // Status reports come 5 times a second during a job (20 while jogging):
  // glide from where the tool is drawn to each new report over about the
  // time between them, at frame rate, rather than jumping (as the 2D view).
  glideTo(x, y, z) {
    const now = performance.now()
    const p = this.tool.position
    this.glide = {
      from: {x: p.x, y: p.y, z: p.z},
      to: {x, y, z},
      t0: now,
      dur: this.lastSample ? Math.min(Math.max(now - this.lastSample, 16), 250) : 0,
    }
    this.lastSample = now
    this.animate()
  },

  animate() {
    if (this.gliding) return
    this.gliding = true
    const step = (now) => {
      const g = this.glide
      const k = g.dur > 0 ? Math.min((now - g.t0) / g.dur, 1) : 1
      const lerp = (a, b) => a + (b - a) * k
      this.tool.position.set(lerp(g.from.x, g.to.x), lerp(g.from.y, g.to.y), lerp(g.from.z, g.to.z))
      this.traceLive()
      this.renderer.render(this.scene, this.camera)
      if (k < 1) requestAnimationFrame(step)
      else this.gliding = false
    }
    requestAnimationFrame(step)
  },

  // The segment being cut, traced from its start to the tool as drawn, so
  // the trace grows right behind the bit (paintDone colours whole segments).
  traceLive() {
    const d = this.pathData
    const i = this.progress.done
    const p = this.tool.position
    const w = this.work.position
    const live =
      this.running && d && i >= 0 && (i + 1) * 4 < d.length && d[(i + 1) * 4] === 1 &&
      onSegment(d, i, [p.x - w.x, p.y - w.y, p.z - w.z])
    if (!live) {
      if (this.live) this.live.visible = false
      return
    }
    if (!this.live) {
      const geometry = new THREE.BufferGeometry()
      geometry.setAttribute("position", new THREE.Float32BufferAttribute(new Float32Array(6), 3))
      this.live = new THREE.Line(geometry, new THREE.LineBasicMaterial({color: this.colors.done}))
    }
    // In the work group (work coordinates), as the path is
    if (this.live.parent !== this.work) this.work.add(this.live)
    const pos = this.live.geometry.attributes.position
    pos.setXYZ(0, d[i * 4 + 1], d[i * 4 + 2], d[i * 4 + 3])
    pos.setXYZ(1, p.x - w.x, p.y - w.y, p.z - w.z)
    pos.needsUpdate = true
    this.live.geometry.computeBoundingSphere()
    this.live.visible = true
  },

  render() {
    if (!this.frame)
      this.frame = requestAnimationFrame(() => {
        this.frame = null
        this.renderer.render(this.scene, this.camera)
      })
  },

  resize() {
    const {clientWidth: w, clientHeight: h} = this.el
    if (!w || !h) return
    this.renderer.setSize(w, h, false)
    this.aspect = w / h
    this.persp.aspect = this.aspect
    this.persp.updateProjectionMatrix()
    this.setOrthoFrustum()
    this.render()
  },

  useCamera(camera) {
    this.camera = camera
    this.controls.object = camera
  },

  setOrthoFrustum() {
    const h = this.orthoHalf, a = this.aspect || 1
    Object.assign(this.ortho, {left: -h * a, right: h * a, top: h, bottom: -h})
    this.ortho.updateProjectionMatrix()
  },

  // A standard direction (iso, top, front), framing the loaded part with
  // some room around it, or the whole travel when there's no part (or for
  // "machine", which is the iso view of the whole travel).
  view(name) {
    let [[x0, x1], [y0, y1], [z0, z1]] = this.travel
    const part = name !== "machine" && this.pathBox
    if (part) {
      const [wx, wy, wz] = this.wco
      const b = this.pathBox
      ;[[x0, x1], [y0, y1], [z0, z1]] = [
        [b.x0 + wx, b.x1 + wx],
        [b.y0 + wy, b.y1 + wy],
        [b.z0 + wz, b.z1 + wz],
      ]
    }
    const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, cz = (z0 + z1) / 2
    const aspect = this.aspect || 1
    const dirs = {
      iso: [0.75, -1.1, 0.9],
      machine: [0.75, -1.1, 0.9],
      top: [0, -0.0001, 1],
      front: [0, -1, 0],
    }
    const [dx, dy, dz] = dirs[name] || dirs.iso
    const len = Math.hypot(dx, dy, dz)
    const place = (dist) => {
      this.camera.position.set(cx + (dx / len) * dist, cy + (dy / len) * dist, cz + (dz / len) * dist)
      this.camera.lookAt(cx, cy, cz)
      this.camera.updateMatrixWorld()
    }

    if (name === "top" || name === "front") {
      // Orthographic: the frame is exactly the extent (plus padding), fitted
      // to the view's shape. Front sees X across and Z up.
      const pad = part ? 1.3 : 1.08
      const w = Math.max(x1 - x0, 10) / 2
      const h = Math.max(name === "top" ? y1 - y0 : z1 - z0, 10) / 2
      this.orthoHalf = Math.max(h, w / aspect) * pad
      this.ortho.zoom = 1
      this.setOrthoFrustum()
      this.useCamera(this.ortho)
      place(5000)
    } else {
      // Zoom to fit: project the box's corners and move in until the
      // farthest one sits at the edge, less padding (a part gets more room)
      this.useCamera(this.persp)
      const fill = part ? 0.75 : 0.94
      const corners = []
      for (const x of [x0, x1]) for (const y of [y0, y1]) for (const z of [z0, z1])
        corners.push(new THREE.Vector3(x, y, z))
      let d = Math.max(x1 - x0, y1 - y0, z1 - z0, 10) * 2
      for (let i = 0; i < 8; i++) {
        place(d)
        let m = 0
        for (const c of corners) {
          const p = c.clone().project(this.camera)
          m = Math.max(m, Math.abs(p.x), Math.abs(p.y))
        }
        d *= 1 + (m / fill - 1) * 0.9
      }
      place(d)
    }
    this.controls.target.set(cx, cy, cz)
    this.controls.update()
    this.lastView = name
    this.userMoved = false
    this.render()
  },

  // The scene changed under a standard view (the work offset arrived, a
  // file loaded, the travel changed): frame it again, unless the camera was
  // moved by hand
  reframe() {
    if (this.userMoved) this.render()
    else this.view(this.lastView || "iso")
  },

  // The bed (at the bottom of Z travel), its grid, and the travel envelope.
  // The stock as a translucent block in the work group: it moves with the
  // work zero, the path drawn through it
  buildStock(box) {
    if (this.stockMesh) {
      this.work.remove(this.stockMesh)
      this.stockMesh.geometry.dispose()
      this.stockMesh = null
    }
    if (!box) return
    const w = box.x1 - box.x0, d = box.y1 - box.y0, h = box.z1 - box.z0
    const color = new THREE.Color(token("--stock-edge", "#c4a06e"))
    const geometry = new THREE.BoxGeometry(w, d, h)
    const block = new THREE.Mesh(
      geometry,
      new THREE.MeshLambertMaterial({color, transparent: true, opacity: 0.12, depthWrite: false}),
    )
    const edges = new THREE.LineSegments(
      new THREE.EdgesGeometry(geometry),
      new THREE.LineBasicMaterial({color, transparent: true, opacity: 0.6}),
    )
    this.stockMesh = new THREE.Group()
    this.stockMesh.geometry = geometry
    this.stockMesh.add(block, edges)
    this.stockMesh.position.set(box.x0 + w / 2, box.y0 + d / 2, box.z0 + h / 2)
    this.work.add(this.stockMesh)
  },

  buildMachine() {
    this.machine.clear()
    const [[x0, x1], [y0, y1], [z0, z1]] = this.travel
    const w = x1 - x0, d = y1 - y0, h = z1 - z0

    const bed = new THREE.Mesh(
      new THREE.PlaneGeometry(w, d),
      new THREE.MeshLambertMaterial({color: this.colors.bed, side: THREE.DoubleSide})
    )
    bed.position.set(x0 + w / 2, y0 + d / 2, z0 - 0.5)
    this.machine.add(bed)

    const grid = []
    const gridMajor = []
    for (let x = Math.ceil(x0 / 50) * 50; x <= x1; x += 50)
      (x % 250 === 0 ? gridMajor : grid).push(x, y0, z0, x, y1, z0)
    for (let y = Math.ceil(y0 / 50) * 50; y <= y1; y += 50)
      (y % 250 === 0 ? gridMajor : grid).push(x0, y, z0, x1, y, z0)
    this.machine.add(lines(grid, this.colors.grid), lines(gridMajor, this.colors.gridMajor))

    const box = new THREE.LineSegments(
      new THREE.EdgesGeometry(new THREE.BoxGeometry(w, d, h)),
      new THREE.LineBasicMaterial({color: this.colors.edge, transparent: true, opacity: 0.45})
    )
    box.position.set(x0 + w / 2, y0 + d / 2, z0 + h / 2)
    this.machine.add(box)
  },

  // The tool, to scale: the bit in the spindle (a 1/4" end mill if none is
  // set), 25 mm sticking out, its tip at the reported position; above it
  // the collet nut, translucent so it doesn't hide the cut. A ball nose has
  // a rounded tip, a V-bit is a cone at its angle up to its diameter.
  buildTool() {
    const at = this.tool ? this.tool.position.clone() : null
    if (this.tool) this.scene.remove(this.tool)
    this.tool = new THREE.Group()
    const mat = new THREE.MeshLambertMaterial({color: this.colors.tool})
    const b = this.bit || {diameter: BIT_D, kind: "flat"}
    const r = b.diameter / 2
    if (b.kind === "v") {
      // The cone from the tip up to the full diameter, then the shank
      const h = r / Math.tan(((b.angle || 90) / 2) * (Math.PI / 180))
      const cone = new THREE.Mesh(new THREE.ConeGeometry(r, h, 24), mat)
      cone.rotation.x = -Math.PI / 2
      cone.position.z = h / 2
      const shank = new THREE.Mesh(new THREE.CylinderGeometry(r, r, Math.max(BIT_OUT - h, 1), 24), mat)
      shank.rotation.x = Math.PI / 2
      shank.position.z = h + Math.max(BIT_OUT - h, 1) / 2
      this.tool.add(cone, shank)
    } else {
      const tipR = b.kind === "ball" ? r : 0
      const body = new THREE.Mesh(new THREE.CylinderGeometry(r, r, BIT_OUT - tipR, 24), mat)
      body.rotation.x = Math.PI / 2
      body.position.z = tipR + (BIT_OUT - tipR) / 2
      this.tool.add(body)
      if (tipR) {
        const ball = new THREE.Mesh(new THREE.SphereGeometry(r, 24, 12, 0, Math.PI * 2, Math.PI / 2, Math.PI / 2), mat)
        ball.rotation.x = Math.PI / 2
        ball.position.z = r
        this.tool.add(ball)
      }
    }
    const nut = new THREE.Mesh(
      new THREE.CylinderGeometry(NUT_D / 2, NUT_D / 2, NUT_H, 6),
      new THREE.MeshLambertMaterial({color: this.colors.tool, transparent: true, opacity: 0.35}),
    )
    nut.rotation.x = Math.PI / 2
    nut.position.z = BIT_OUT + NUT_H / 2
    this.tool.add(nut)
    if (at) this.tool.position.copy(at)
    this.scene.add(this.tool)
  },

  // Work zero: X/Y/Z axes where the work coordinates start; the toolpath
  // lives in this group too (it's in work coordinates).
  setWork(wco) {
    this.wco = wco
    this.work.position.set(wco[0], wco[1], wco[2])
    if (!this.axes) {
      this.axes = new THREE.Group()
      const axis = (to, color) => lines([0, 0, 0, ...to], color)
      this.axes.add(
        axis([80, 0, 0], this.colors.x),
        axis([0, 80, 0], this.colors.y),
        axis([0, 0, 80], this.colors.z)
      )
      this.work.add(this.axes)
    }
  },


  // The jog trail: the tool's recent path, newest brightest, fading with age
  pushTrail(x, y, z) {
    const last = this.trail[this.trail.length - 1]
    if (last && Math.hypot(last[0] - x, last[1] - y, last[2] - z) < 0.05) return
    this.trail.push([x, y, z])
    if (this.trail.length > TRAIL_MAX) this.trail.shift()
    this.buildTrail()
  },

  clearTrail() {
    this.trail = []
    this.buildTrail()
    this.render()
  },

  buildTrail() {
    if (this.trailLine) {
      this.scene.remove(this.trailLine)
      this.trailLine.geometry.dispose()
      this.trailLine = null
    }
    const n = this.trail.length
    if (n < 2) return
    const bg = new THREE.Color(token("--surface-0", "#1c1f22"))
    const pos = [], col = []
    this.trail.forEach(([x, y, z], i) => {
      pos.push(x, y, z)
      const c = this.colors.move.clone().lerp(bg, 1 - (i + 1) / n)
      col.push(c.r, c.g, c.b)
    })
    const geo = new THREE.BufferGeometry()
    geo.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3))
    geo.setAttribute("color", new THREE.Float32BufferAttribute(col, 3))
    this.trailLine = new THREE.Line(geo, new THREE.LineBasicMaterial({vertexColors: true}))
    this.scene.add(this.trailLine)
  },

  // Fade the segments a running job has finished (only the new ones)
  paintDone() {
    if (!this.pathSegs) return
    const done = this.progress.done
    if (done < 0) return
    // A new job on the same file: start from fresh colours
    if (this.painted > 0 && this.segEnd[this.painted - 1] > done) this.buildPath()
    const colors = this.pathSegs.geometry.attributes.color
    const faint = this.colors.done
    // Tracing: the plan's cuts fade to a ghost, once
    if (!this.ghosted) {
      const ghost = this.colors.path.clone().lerp(new THREE.Color(token("--surface-0", "#1c1f22")), 0.68)
      for (let k = 0; k < this.segCut.length; k++)
        if (this.segCut[k]) {
          colors.setXYZ(k * 2, ghost.r, ghost.g, ghost.b)
          colors.setXYZ(k * 2 + 1, ghost.r, ghost.g, ghost.b)
        }
      this.ghosted = true
      colors.needsUpdate = true
      this.render()
    }
    let k = this.painted
    while (k < this.segEnd.length && this.segEnd[k] <= done) {
      // Only cuts turn green; rapids keep their colour
      if (this.segCut[k]) {
        colors.setXYZ(k * 2, faint.r, faint.g, faint.b)
        colors.setXYZ(k * 2 + 1, faint.r, faint.g, faint.b)
      }
      k++
    }
    if (k !== this.painted) {
      this.painted = k
      colors.needsUpdate = true
      this.render()
    }
  },

  buildPath() {
    if (this.pathLines) this.work.remove(...this.pathLines)
    this.pathLines = []
    this.pathBox = null
    if (!this.pathData) return

    const v = this.pathData
    // The toolpath's extent (work coordinates), for the framed views
    const box = {x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity, z0: Infinity, z1: -Infinity}
    for (let i = 0; i < v.length; i += 4) {
      box.x0 = Math.min(box.x0, v[i + 1]); box.x1 = Math.max(box.x1, v[i + 1])
      box.y0 = Math.min(box.y0, v[i + 2]); box.y1 = Math.max(box.y1, v[i + 2])
      box.z0 = Math.min(box.z0, v[i + 3]); box.z1 = Math.max(box.z1, v[i + 3])
    }
    this.pathBox = v.length ? box : null

    // One set of segments, cuts and rapids, coloured per vertex so a job's
    // progress can fade what's done in place. segEnd[k] is the path vertex
    // that segment k ends at.
    const pos = [], col = [], segEnd = [], segCut = []
    const cut = this.colors.path, rapid = this.colors.rapid
    for (let i = 4; i < v.length; i += 4) {
      const kind = v[i]
      if (kind < 0) continue
      pos.push(v[i - 3], v[i - 2], v[i - 1], v[i + 1], v[i + 2], v[i + 3])
      const c = kind === 1 ? cut : rapid
      col.push(c.r, c.g, c.b, c.r, c.g, c.b)
      segEnd.push(i / 4)
      segCut.push(kind === 1)
    }
    const geo = new THREE.BufferGeometry()
    geo.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3))
    geo.setAttribute("color", new THREE.Float32BufferAttribute(col, 3))
    this.pathSegs = new THREE.LineSegments(geo, new THREE.LineBasicMaterial({vertexColors: true}))
    this.ghosted = false
    this.segEnd = segEnd
    this.segCut = segCut
    this.painted = 0
    this.pathLines = [this.pathSegs]
    this.work.add(...this.pathLines)
    if (!this.axes) this.setWork(this.wco)
  },
}

function lines(positions, color, opacity = 1) {
  const geo = new THREE.BufferGeometry()
  geo.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3))
  return new THREE.LineSegments(
    geo,
    new THREE.LineBasicMaterial({color, transparent: opacity < 1, opacity})
  )
}

// Base64 float32 [kind, x, y, z] vertices.
function decode(b64) {
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return new Float32Array(bytes.buffer)
}
