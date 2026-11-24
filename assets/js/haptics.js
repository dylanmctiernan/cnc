// Haptic feedback where the platform allows it.
//   Android etc.: the Vibration API.
//   iOS Safari: no Vibration API, but toggling a native switch control
//   (<input type="checkbox" switch>, iOS 17.4/18+) gives a haptic tick, so
//   we click a hidden one. Not an Apple API: if a release removes it, this
//   quietly does nothing. Must run inside a user gesture (pointerdown/up).
let switchLabel = null

function iosTick() {
  if (!switchLabel) {
    const input = document.createElement("input")
    input.type = "checkbox"
    input.setAttribute("switch", "")
    input.id = "cnc-haptic-switch"
    input.setAttribute("aria-hidden", "true")
    input.tabIndex = -1
    switchLabel = document.createElement("label")
    switchLabel.htmlFor = input.id
    switchLabel.setAttribute("aria-hidden", "true")
    for (const el of [input, switchLabel]) {
      Object.assign(el.style, {position: "fixed", left: "-100px", top: "0", opacity: "0", pointerEvents: "none"})
      document.body.appendChild(el)
    }
  }
  switchLabel.click()
}

export function haptic(kind = "light") {
  if (typeof navigator.vibrate === "function") {
    navigator.vibrate(kind === "strong" ? [30, 50, 30] : 12)
  } else {
    iosTick()
    if (kind === "strong") setTimeout(iosTick, 90)
  }
}

// Any element with data-haptic="light|strong" ticks when pressed.
export function mountHaptics() {
  document.addEventListener(
    "pointerdown",
    (e) => {
      const el = e.target.closest?.("[data-haptic]")
      if (el && !el.disabled) haptic(el.dataset.haptic)
    },
    {capture: true}
  )
}
