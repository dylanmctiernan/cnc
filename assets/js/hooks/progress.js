// Path over time: how far along the toolpath a running job has got, from
// the tool's reported position. Shared by the 2D bed view and the 3D view.
//
// The path is the same vertex list both views draw: [kind, x, y, z] per
// vertex in work coordinates (kind -1 start, 0 rapid, 1 cut). Starting from
// the last vertex reached, look a little way ahead for the segment nearest
// the tool (in 3D, so passes stacked at different depths aren't confused)
// and move up to it. Never backwards, never far ahead: where a pocket's
// passes run close together, the tool is matched to the one it's on.

const AHEAD = 600 // vertices searched past the last one reached
const NEAR = 3 // mm: the tool must be this close to count as on the path

// Index of the last vertex the tool has passed, or `done` unchanged.
export function advance(data, done, [tx, ty, tz]) {
  const n = data.length / 4
  let best = -1, bestD = NEAR * NEAR
  const last = Math.min(n - 1, done + AHEAD)
  for (let i = Math.max(1, done); i <= last; i++) {
    const d = segDist2(data, i - 1, i, tx, ty, tz)
    if (d < bestD) {
      bestD = d
      best = i - 1
    }
  }
  return best > done ? best : done
}

// Squared distance from a point to the segment between vertices a and b
function segDist2(v, a, b, px, py, pz) {
  const ax = v[a * 4 + 1], ay = v[a * 4 + 2], az = v[a * 4 + 3]
  const bx = v[b * 4 + 1], by = v[b * 4 + 2], bz = v[b * 4 + 3]
  const dx = bx - ax, dy = by - ay, dz = bz - az
  const len2 = dx * dx + dy * dy + dz * dz
  let t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy + (pz - az) * dz) / len2 : 0
  t = Math.max(0, Math.min(1, t))
  const ex = ax + t * dx - px, ey = ay + t * dy - py, ez = az + t * dz - pz
  return ex * ex + ey * ey + ez * ez
}

// Track a job across position reports: starts at 0 when a job starts, keeps
// what was cut when it ends (until the file changes or another job starts).
export class Progress {
  constructor() {
    this.done = -1 // -1: no job since the file was loaded
    this.running = false
  }

  reset() {
    this.done = -1
    this.running = false
  }

  // Returns true if the done part changed.
  update(data, running, pos, wco) {
    let changed = false
    if (running && !this.running) {
      this.done = 0
      changed = true
    }
    this.running = running
    if (running && data && pos) {
      const [ox, oy, oz] = wco || [0, 0, 0]
      const next = advance(data, this.done, [pos.x - ox, pos.y - oy, pos.z - oz])
      if (next !== this.done) {
        this.done = next
        changed = true
      }
    }
    return changed
  }
}
