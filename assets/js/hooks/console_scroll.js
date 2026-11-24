// Keep the console pinned to the newest line, unless the user has scrolled
// up to read something.
export default {
  mounted() {
    this.pinned = true
    this.el.addEventListener("scroll", () => {
      const {scrollHeight, scrollTop, clientHeight} = this.el
      this.pinned = scrollHeight - scrollTop - clientHeight < 24
    })
    this.observer = new MutationObserver(() => {
      if (this.pinned) this.el.scrollTop = this.el.scrollHeight
    })
    this.observer.observe(this.el, {childList: true})
    this.el.scrollTop = this.el.scrollHeight
  },
  destroyed() {
    this.observer.disconnect()
  },
}
