// Layout stability check: drives the workstation through its everyday
// interactions and fails if any landmark (Hold, the header's buttons, the
// readout, the map, the panels, the tabs) moves or resizes. Controls must
// never appear, disappear or change size under the operator's hand: things
// that come and go take reserved space, are disabled instead of removed,
// or lie over the content (notes, dialogs).
//
//   mix e2e.layout   (runs this against the dev server)
//
// Needs the dev server running with a controller connected (a sim is fine):
//   BASE_URL (default http://localhost:4000). It drives the page (opens a
//   file, runs a check): point it at a sandbox server, not the one in use,
//   e.g. PORT=4100 CNC_DATA_DIR=/tmp/cnc-sandbox mix phx.server. It refuses
//   to start while a job runs.
import {chromium} from "playwright"
import {fileURLToPath} from "node:url"
import path from "node:path"

const BASE = process.env.BASE_URL || "http://localhost:4000"
const SAMPLE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../test/fixtures/sample.nc")
const SIZES = [[1440, 900], [1024, 768]]
const TOLERANCE = 0.5 // px

const MACHINE = [
  "#machine-state", "#diagnostics-toggle", "#bar-reset", "#bar-resume", "#bar-hold", "#rail-hold",
  ".cnc-view-bar", "#view-top", "#view-3d", ".cnc-view", "#messages",
  ".cnc-dro", ".cnc-dro-tools", ".cnc-ctl", ".cnc-modes", ".cnc-mode-body", ".cnc-side",
]
const CONFIG = ["#rail-hold", ".ui-page-header", "#in-use", "#tabs"]

const problems = []

async function landmarks(page, selectors) {
  return page.evaluate((sels) => {
    const out = {}
    for (const s of sels) {
      const el = document.querySelector(s)
      if (!el) { out[s] = null; continue }
      const r = el.getBoundingClientRect()
      out[s] = [r.x, r.y, r.width, r.height]
    }
    return out
  }, selectors)
}

// Run one interaction and compare every landmark before and after.
async function step(page, where, name, selectors, act) {
  const before = await landmarks(page, selectors)
  await act()
  await page.waitForTimeout(600)
  const after = await landmarks(page, selectors)
  for (const s of selectors) {
    const a = before[s], b = after[s]
    if (!a && !b) continue
    if (!a || !b) { problems.push(`${where} · ${name}: ${s} ${a ? "disappeared" : "appeared"}`); continue }
    const moved = a.some((v, i) => Math.abs(v - b[i]) > TOLERANCE)
    if (moved)
      problems.push(`${where} · ${name}: ${s} moved [x y w h] ${a.map(Math.round)} → ${b.map(Math.round)}`)
  }
}

const click = (page, sel) => page.locator(sel).first().click({timeout: 5000})

const browser = await chromium.launch()
for (const [w, h] of SIZES) {
  const where = `${w}×${h}`
  const page = await (await browser.newContext({viewport: {width: w, height: h}})).newPage()

  await page.goto(BASE + "/")
  await page.waitForSelector(".phx-connected")
  await page.waitForTimeout(800)

  // Never on a machine that's cutting: this drives the page (opens files,
  // runs a check), and every browser drives the same machine. Use a
  // sandbox server (PORT=4100 CNC_DATA_DIR=... mix phx.server; BASE_URL).
  if (await page.locator("#job-panel, #bar-reset:has-text('Abort')").count()) {
    console.error(`A job is running on ${BASE}: not touching it. Run against a sandbox (BASE_URL).`)
    process.exit(2)
  }
  if (await page.locator(".cnc-lock button", {hasText: "Unlock"}).count())
    await page.locator(".cnc-lock button", {hasText: "Unlock"}).click()
  if (await page.locator("#bar-resume:not([disabled])", {hasText: "Resume"}).count())
    await click(page, "#bar-resume")
  await page.waitForTimeout(800)

  const M = MACHINE
  await step(page, where, "load a file", M, async () => {
    await click(page, "#panel-auto")
    await click(page, "#open-file")
    await page.locator("input[type=file]").first().setInputFiles(SAMPLE)
    await page.waitForTimeout(1500)
    await page.keyboard.press("Escape")
    if (await page.locator("#close-file").count()) await click(page, "#close-file")
  })
  await step(page, where, "zoom to the bed", M, () => click(page, "#zoom-bed"))
  await step(page, where, "zoom to the file", M, () => click(page, "#zoom-file"))
  await step(page, where, "3D", M, () => click(page, "#view-3d"))
  await step(page, where, "2D", M, () => click(page, "#view-top"))
  // Jog · Inc · Auto · MDI: one fixed height, so switching moves nothing else
  for (const mode of ["jog", "inc", "auto", "mdi", "jog"])
    await step(page, where, `${mode} mode`, M, () => click(page, `#panel-${mode}`))
  await step(page, where, "machine coordinates", M, () => click(page, ".cnc-dro-head button[phx-value-frame=machine]"))
  await step(page, where, "work coordinates", M, () => click(page, ".cnc-dro-head button[phx-value-frame=work]"))
  await step(page, where, "Hold", M, () => click(page, "#bar-hold"))
  await step(page, where, "Resume", M, () => click(page, "#bar-resume"))
  await step(page, where, "Zero X/Y", M, () => click(page, ".cnc-dro-tools button:has-text('Zero X/Y')"))
  await step(page, where, "Undo the zero", M, () => click(page, "#undo-zero"))
  // Diagnostics docks under the map: the right column doesn't move
  const R = ["#bar-hold", "#rail-hold", ".cnc-dro", ".cnc-ctl", "#messages"]
  await step(page, where, "open Diagnostics", R, () => click(page, "#diagnostics-toggle"))
  await step(page, where, "close Diagnostics", R, () => click(page, "#diagnostics-toggle"))
  // The Start check is a dialog: opening and closing it moves nothing
  await step(page, where, "Start check, then Not yet", M, async () => {
    await click(page, "#bar-resume")
    await click(page, "#cancel-start")
  })

  // Configuration: the tabs change what's below them, never the frame
  await page.goto(BASE + "/configuration")
  await page.waitForSelector(".phx-connected")
  await page.waitForTimeout(800)
  for (const tab of ["build", "wiring", "file", "history", "profiles"])
    await step(page, where, `${tab} tab`, CONFIG, () => click(page, `#tab-${tab}`))

  await page.context().close()
}
await browser.close()

if (problems.length) {
  console.error(`Layout shifts (${problems.length}):\n  ` + problems.join("\n  "))
  process.exit(1)
}
console.log(`No layout shifts (${SIZES.map(([w, h]) => `${w}×${h}`).join(", ")}).`)
