// The 3D viewport (CNCWeb.UI.viewport): the machine in three.js, Z up, in
// machine coordinates (mm). The bed and its grid, the travel envelope, the
// work zero (X/Y/Z axes), the loaded toolpath (cuts solid, rapids faint) and
// the tool. Orbit, pan and zoom; Iso/Top/Front views. It renders only when
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
    this.camera = new THREE.PerspectiveCamera(40, 1, 1, 20000)
    this.camera.up.set(0, 0, 1)

    this.controls = new OrbitControls(this.camera, canvas)
    this.controls.enableDamping = false
    this.controls.screenSpacePanning = true
    this.controls.addEventListener("change", () => this.render())

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
      tool: new THREE.Color(token("--text", "#e4e7e9")),
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

    this.handleEvent("pos", ({x, y, z, wco}) => {
      this.tool.position.set(x, y, z)
      if (wco) this.setWork(wco)
      this.render()
    })
    this.handleEvent("program", ({path}) => {
      this.pathData = path ? decode(path) : null
      this.buildPath()
      this.render()
    })
    this.handleEvent("travel", ({travel}) => {
      this.travel = travel
      this.buildMachine()
      this.render()
    })

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
    this.camera.aspect = w / h
    this.camera.updateProjectionMatrix()
    this.render()
  },

  // Look at the whole travel (or, for "file", the loaded toolpath) from a
  // standard direction.
  view(name) {
    let [[x0, x1], [y0, y1], [z0, z1]] = this.travel
    if (name === "file" && this.pathBox) {
      const [wx, wy, wz] = this.wco
      const b = this.pathBox
      ;[[x0, x1], [y0, y1], [z0, z1]] = [
        [b.x0 + wx, b.x1 + wx],
        [b.y0 + wy, b.y1 + wy],
        [b.z0 + wz, b.z1 + wz],
      ]
    }
    const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, cz = (z0 + z1) / 2
    // Far enough that the whole travel fits, whatever the view's shape
    const half = Math.max(x1 - x0, y1 - y0, 10) / 2
    const fit = half / Math.tan((this.camera.fov * Math.PI) / 360)
    const d = (fit * (name === "top" ? 1.12 : 2.1)) / Math.min(1, this.camera.aspect)
    const dirs = {
      iso: [0.75, -1.1, 0.9],
      file: [0.75, -1.1, 0.9],
      top: [0, -0.0001, 1],
      front: [0, -1, 0.12],
    }
    const [dx, dy, dz] = dirs[name] || dirs.iso
    const len = Math.hypot(dx, dy, dz)
    this.controls.target.set(cx, cy, cz)
    this.camera.position.set(cx + (dx / len) * d, cy + (dy / len) * d, cz + (dz / len) * d)
    this.controls.update()
    this.render()
  },

  // The bed (at the bottom of Z travel), its grid, and the travel envelope.
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

  // The tool: a cone pointing down at its tip, and the spindle above it.
  buildTool() {
    this.tool = new THREE.Group()
    const mat = new THREE.MeshLambertMaterial({color: this.colors.tool})
    const tip = new THREE.Mesh(new THREE.ConeGeometry(6, 20, 24), mat)
    tip.rotation.x = -Math.PI / 2
    tip.position.z = 10
    const body = new THREE.Mesh(new THREE.CylinderGeometry(6, 6, 40, 24), mat)
    body.rotation.x = Math.PI / 2
    body.position.z = 40
    this.tool.add(tip, body)
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

  buildPath() {
    if (this.pathLines) this.work.remove(...this.pathLines)
    this.pathLines = []
    this.pathBox = null
    if (!this.pathData) return

    const cut = [], rapid = []
    const v = this.pathData
    // The toolpath's extent (work coordinates), for the File view
    const box = {x0: Infinity, x1: -Infinity, y0: Infinity, y1: -Infinity, z0: Infinity, z1: -Infinity}
    for (let i = 0; i < v.length; i += 4) {
      box.x0 = Math.min(box.x0, v[i + 1]); box.x1 = Math.max(box.x1, v[i + 1])
      box.y0 = Math.min(box.y0, v[i + 2]); box.y1 = Math.max(box.y1, v[i + 2])
      box.z0 = Math.min(box.z0, v[i + 3]); box.z1 = Math.max(box.z1, v[i + 3])
    }
    this.pathBox = v.length ? box : null
    for (let i = 4; i < v.length; i += 4) {
      const kind = v[i]
      if (kind < 0) continue
      ;(kind === 1 ? cut : rapid).push(v[i - 3], v[i - 2], v[i - 1], v[i + 1], v[i + 2], v[i + 3])
    }
    const rapidLines = lines(rapid, this.colors.rapid, 0.5)
    this.pathLines = [lines(cut, this.colors.path), rapidLines]
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
