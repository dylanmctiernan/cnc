// PIN page: mirror the numeric input into four cells, drive it from the
// on-screen keypad, and submit as soon as four digits are in.
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

  form.querySelectorAll("[data-digit]").forEach((key) =>
    key.addEventListener("click", () => {
      set(input.value + key.dataset.digit)
      input.focus({preventScroll: true})
    })
  )
  form.querySelector("[data-back]").addEventListener("click", () => {
    set(input.value.slice(0, -1))
    input.focus({preventScroll: true})
  })

  render()
}
