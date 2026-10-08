import QtQuick
import Quickshell
import Quickshell.Io

// One request at a time to Hyprland's control socket, the one hyprctl talks
// to, without starting hyprctl. A process is a fork of the whole shell on the
// thread that draws the overview, and the overview asked for one on the frame
// every swipe began.
Socket {
  id: hypr

  signal line(string text)
  signal answered()

  property string pending: ""

  path: {
    const runtime = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    const instance = String(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")
    return runtime && instance ? runtime + "/hypr/" + instance + "/.socket.sock" : ""
  }

  parser: SplitParser {
    onRead: data => hypr.line(data)
  }

  /** Send `request` ("j/clients", "eval …"); false while one is in flight. */
  function ask(request) {
    if (hypr.connected || hypr.path === "") return false
    hypr.pending = request
    hypr.connected = true
    return true
  }

  // Hyprland answers and hangs up.
  onConnectedChanged: {
    if (hypr.connected) {
      hypr.write(hypr.pending)
      hypr.flush()
    } else {
      hypr.answered()
    }
  }
}
