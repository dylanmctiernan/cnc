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
  input.addEventListener("focus", () => form.classList.add("is-focused"))
  input.addEventListener("blur", () => form.classList.remove("is-focused"))

  render()
}
