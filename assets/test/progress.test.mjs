// The path trace's tool matching (assets/js/hooks/progress.js).
// Run: node --test assets/test   (part of mix precommit)
import {test} from "node:test"
import assert from "node:assert/strict"
import {advance} from "../js/hooks/progress.js"

// [kind, x, y, z] per vertex (work mm): -1 start, 0 rapid, 1 cut
const path = (...vs) => new Float32Array(vs.flat())

// Like quick.nc: lift, travel to a box, cut it at Z-1, lift, rapid to a
// circle, cut it, rapid home at safe height (crossing the box's corner)
const job = path(
  [-1, 0, 0, 5],
  [1, 0, 0, -1], //  1 plunge
  [1, 60, 0, -1], // 2 box bottom edge
  [1, 60, 40, -1], // 3
  [1, 0, 40, -1], // 4
  [1, 0, 0, -1], //  5
  [0, 0, 0, 5], //   6 lift
  [0, 100, 20, 5], // 7 rapid to the circle
  [1, 100, 20, -1], // 8 plunge
  [1, 110, 20, -1], // 9 cut
  [0, 110, 20, 5], //  10 lift
  [0, 0, 0, 5], //     11 rapid home: back over the start at safe height
)

test("follows the cut the tool is on", () => {
  assert.equal(advance(job, 0, [30, 0, -1]), 1) // on the box's bottom edge
  assert.equal(advance(job, 1, [60, 20, -1]), 2)
})

test("never matches a rapid: lifting at the start doesn't jump to the trip home", () => {
  // A job started from where another stopped: the tool lifts and travels at
  // Z5 over the start, right on the final rapid home (segment 10 -> 11)
  assert.equal(advance(job, 0, [16, 3, 5]), 0)
  assert.equal(advance(job, 0, [0, 0, 5]), 0)
})

test("never goes backwards, and holds when the tool is off the path", () => {
  assert.equal(advance(job, 4, [30, 0, -1]), 4) // back over an earlier edge
  assert.equal(advance(job, 4, [500, 500, 0]), 4)
})
