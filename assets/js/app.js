// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/ask_drive"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
})

// The server is about to restart into an update (spec F-1505): cover the page with
// "updating" until the socket is back, then reload on the new version (new assets too).
let askdriveUpdating = false
window.addEventListener("phx:askdrive:updating", ({detail}) => {
  askdriveUpdating = true
  if (document.getElementById("askdrive-updating")) return
  const overlay = document.createElement("div")
  overlay.id = "askdrive-updating"
  overlay.setAttribute("role", "alert")
  overlay.className =
    "fixed inset-0 z-[100] flex items-center justify-center bg-white/80 dark:bg-zinc-950/80 backdrop-blur-sm transition-opacity"
  const card = document.createElement("div")
  card.className =
    "mx-4 max-w-sm w-full p-6 rounded-2xl bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 shadow-xl text-center space-y-3"
  const spinner = document.createElement("div")
  spinner.className =
    "mx-auto w-10 h-10 rounded-full border-4 border-indigo-200 border-t-indigo-600 animate-spin"
  const title = document.createElement("p")
  title.className = "font-semibold text-zinc-900 dark:text-zinc-100"
  title.textContent = detail.title
  const message = document.createElement("p")
  message.className = "text-xs text-zinc-500 leading-relaxed"
  message.textContent = detail.message
  card.append(spinner, title, message)
  overlay.append(card)
  document.body.append(overlay)
})
liveSocket.getSocket().onOpen(() => {
  if (askdriveUpdating) window.location.reload()
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
// Sign-in e-mail: "name" becomes "name@<the organization's domain>" when the field is left
// (spec F-1312). Anything with an "@" — another domain of the same Workspace — stays as typed.
const completeDomain = input => {
  const domain = input.dataset.defaultDomain
  const value = input.value.trim()
  if (domain && value !== "" && !value.includes("@")) input.value = `${value}@${domain}`
}
document.addEventListener("focusout", e => {
  if (e.target.matches && e.target.matches("input[data-default-domain]")) completeDomain(e.target)
})
document.addEventListener("submit", e => {
  e.target.querySelectorAll && e.target.querySelectorAll("input[data-default-domain]").forEach(completeDomain)
}, true)

window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

