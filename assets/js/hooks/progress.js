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
//
// Only cutting moves are matched. Rapids run at a safe height, where many of
// them cross the same places (to each pass, back home): a tool lifting or
// travelling there, as at the start of a job from wherever it was, would
// match a much later one and jump the trace near the end. They're not traced
// anyway; progress catches up at the next cut.
export function advance(data, done, [tx, ty, tz]) {
  const n = data.length / 4
  let best = -1, bestD = NEAR * NEAR
  const last = Math.min(n - 1, done + AHEAD)
  for (let i = Math.max(1, done); i <= last; i++) {
    if (data[i * 4] !== 1) continue
    const d = segDist2(data, i - 1, i, tx, ty, tz)
    if (d < bestD) {
      bestD = d
      best = i - 1
    }
  }
  return best > done ? best : done
}

// Whether the tool (work coordinates) is on the segment from vertex i to
// i + 1: the live trace draws only then
export function onSegment(data, i, [tx, ty, tz]) {
  if (i < 0 || (i + 1) * 4 >= data.length) return false
  return segDist2(data, i, i + 1, tx, ty, tz) <= NEAR * NEAR
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

// How far the current job has got, shared by the 2D and 3D views and kept
// when a view is switched away and back (it's built anew each time): keyed
// to the job (its start time), reset only when the file itself changes.
const shared = {file: null, job: null, done: -1}

export class Progress {
  // data: the path (a new file resets); job: the running job's key, or null
  // Returns the last vertex passed (-1: no job since the file was loaded).
  update(data, job, pos, wco) {
    const file = data ? `${data.length}:${data[1]},${data[2]},${data[data.length - 1]}` : null
    if (file !== shared.file) {
      shared.file = file
      shared.job = null
      shared.done = -1
    }
    if (job && job !== shared.job) {
      shared.job = job
      shared.done = 0
    }
    if (job && data && pos) {
      const [ox, oy, oz] = wco || [0, 0, 0]
      shared.done = advance(data, shared.done, [pos.x - ox, pos.y - oy, pos.z - oz])
    }
    return shared.done
  }

  get done() {
    return shared.done
  }

  // A new file was loaded
  reset() {}
}
