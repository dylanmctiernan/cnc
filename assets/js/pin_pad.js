// PIN page: mirror the numeric input into four cells and submit as soon as
// four digits are in. Tapping the cells focuses the input (it lies over
// them), which brings up the phone's own number pad.
export function mountPinPad() {
  const form = document.getElementById("pin-form")
  if (!form) return

  const input = form.querySelector("#pin")
  const cells = form.querySelectorAll(".cnc-pin-cell")
  let submitted = false

  const render = () => {
    const n = input.value.length
    cells.forEach((cell, i) => {
      cell.classList.toggle("is-filled", i < n)
      cell.classList.toggle("is-active", i === n)
    })
    if (n === 4 && !submitted) {
      submitted = true
      form.submit()
    }
  }

  const set = (value) => {
    input.value = value.replace(/\D/g, "").slice(0, 4)
    form.classList.remove("is-error")
    render()
  }

  input.addEventListener("input", () => set(input.value))
  // The page is only this field: be ready to type. autofocus covers a
  // fresh load; a page restored with Back (bfcache) needs telling. (Phones
  // won't open the keyboard without a tap; the cells are that tap target.)
  const ready = () => input.focus({preventScroll: true})
  window.addEventListener("pageshow", ready)
  // Safari can leave focus in its address bar after loading: take it when
  // the window does get focus
  window.addEventListener("focus", ready)
  ready()
  requestAnimationFrame(ready)

  // Whatever has focus, digits typed on the page go into the PIN (and
  // Backspace takes one off): "just start typing" works everywhere.
  document.addEventListener("keydown", (e) => {
    if (e.target === input || e.metaKey || e.ctrlKey || e.altKey) return
    if (/^[0-9]$/.test(e.key)) {
      e.preventDefault()
      ready()
      set(input.value + e.key)
    } else if (e.key === "Backspace") {
      e.preventDefault()
      ready()
      set(input.value.slice(0, -1))
    }
  })

  render()
}
