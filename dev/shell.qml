import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Development harness: the real window, on fixture data, rendered offscreen.
//
//   dev/run.sh                      # start it
//   dev/shot.sh out.png             # photograph what it is drawing
//   dev/shot.sh out.png demo-chat-0 # opening that conversation first
//
// This loads TeamsWindow.qml itself rather than a copy of its parts, so what is
// being looked at is the window the shell would host - the same layout, the
// same key handling, the same service underneath. Only two things differ: the
// settings come from here instead of from shell.json, and `demo` is on, which
// makes teams.py answer every read out of its own fixtures and refuse every
// write. Nothing here can reach Graph, and nothing here touches your
// shell.json - which is what showcase.sh has to do, and why that one is not
// safe to run while you are using Teams.
ShellRoot {
  TeamsWindow {
    id: panel

    Component.onCompleted: panel.open("{}")

    // The window reads its settings out of the bar layout, which in a harness
    // is the wrong answer twice over: with no Teams widget in the bar it shows
    // "No Teams widget in the bar", and *with* one it shows your real account.
    // So the fixtures are applied after that read has landed, keyed on
    // settingsLoaded rather than on a delay - a timer racing an asynchronous
    // read is how a harness ends up pointed at a real mailbox some of the time
    // and at fixtures the rest of it.
    function fixtures() {
      panel.settingsError = ""
      panel.settings = {
        account: "demo",
        // Configured-looking and not yours. None of it reaches Graph: demo
        // answers locally, and the client id is all zeroes.
        clientId: "00000000-0000-0000-0000-000000000000",
        demo: true,
        demoOpen: dev.openConversation,
        channels: true,
        chats: 25,
        density: dev.density
      }
    }

    // Deferred, and that is the whole trick: the window sets settingsLoaded
    // *before* it assigns the settings it just read, so a handler that applies
    // fixtures inline is overwritten by the real bar entry one line later. Ask
    // again after that function has finished and the fixtures are what stand.
    // Getting this wrong is not a blank window - it is a harness quietly
    // showing your real account, which is worse.
    onSettingsLoadedChanged: if (panel.settingsLoaded) Qt.callLater(panel.fixtures)

    // If that read never returns - no config.py, no python - the fixtures still
    // have to arrive, or the harness shows an empty window and says nothing.
    Timer {
      running: true
      interval: 1500
      onTriggered: if (!panel.settingsLoaded) panel.fixtures()
    }
  }

  // The grabbed item is the window's FocusScope, which is transparent: the
  // colour behind it belongs to the window, and the window is not what gets
  // photographed. So a rectangle in the theme's background colour is put behind
  // it once, or every screenshot is dark text on nothing.
  //
  // Out here rather than on the IpcHandler: everything declared on one of those
  // has to be a type that can cross IPC, and an Item is not.
  QtObject {
    id: backdrop

    property var rect: null

    function paint(item) {
      if (backdrop.rect) return
      backdrop.rect = Qt.createQmlObject(
        'import QtQuick; Rectangle { z: -1000; anchors.fill: parent }', item, "backdrop")
      backdrop.rect.color = Color.background
    }
  }

  IpcHandler {
    id: dev
    target: "dev"

    property string density: "cosy"
    property string openConversation: "demo-chat-0"

    // The harness draws its own screenshots rather than being photographed off
    // the screen: offscreen means there is no screen, and a compositor grab of
    // a window that is not mapped anywhere gets whatever is in front of it.
    function shot(path: string): void {
      // The window's own content item is created by Quickshell rather than by
      // the QML engine, and grabToImage refuses it ("item has no QML engine").
      // Its first child is the FocusScope the window declares, which fills it
      // and is an ordinary QML item - so that is what gets photographed.
      var content = panel.floatingWindow ? panel.floatingWindow.contentItem : null
      var item = content && content.children.length > 0 ? content.children[0] : content
      if (!item) { console.log("shot", path, "no window yet"); return }
      backdrop.paint(item)
      var started = item.grabToImage(function(result) {
        console.log("shot", path, result ? result.saveToFile(path) : "no result")
      })
      if (!started) console.log("shot", path, "grab refused - is the window mapped?")
    }

    // Which conversation the demo opens by itself, and how much room to give
    // things: the two knobs worth turning while looking at a layout. demoOpen
    // is honoured only while demo is on.
    function open(id: string): void {
      dev.openConversation = id
      panel.settings = Object.assign({}, panel.settings, { demoOpen: id })
    }

    function spacing(name: string): void {
      dev.density = name
      panel.settings = Object.assign({}, panel.settings, { density: name })
    }

    // Point the harness at a real account instead of the fixtures - for looking
    // at what a sign-in that went wrong actually says. It reads whatever token
    // is already stored for that alias; it never writes one, and it needs the
    // client id that alias was signed in with.
    function account(name: string, clientId: string): void {
      panel.settings = { account: name, clientId: clientId, demo: false,
                         channels: true, chats: 25, density: dev.density }
    }

    // The status menu, opened without a keyboard - offscreen means p never
    // reaches the window. Returns the rows it is offering, so a script can
    // check the picker agrees with what the helper says Graph will take.
    function presence(): string {
      panel.togglePresencePicker()
      return JSON.stringify({
        open: panel.pickingPresence,
        canSet: panel.teamsService.canSetPresence,
        mine: panel.teamsService.myPresence,
        rows: panel.teamsService.presenceChoices.map(function(row) { return row.state })
      })
    }

    // Picking one, the way a number key or a click does.
    function pick(index: int): string {
      panel.presenceAt(index)
      return JSON.stringify({ error: panel.teamsService.presenceError })
    }

    // The two routes into uploadFile() without a mouse: the file chooser and a
    // drop both end at sendFile(), so this is what a drag onto the window does.
    function attach(path: string): string {
      panel.sendFile("file://" + path)
      return "ok"
    }

    // What the service thinks is going on, for when the window comes up empty
    // and the log says nothing. Returned rather than logged, so it lands in the
    // terminal that asked.
    function state(): string {
      var svc = panel.teamsService
      if (!svc) return "no service"
      return JSON.stringify({
        configured: svc.configured,
        loading: svc.loading,
        signedIn: svc.signedIn,
        needsSignIn: svc.needsSignIn,
        error: svc.errorCode + (svc.errorMessage ? ": " + svc.errorMessage : ""),
        settingsError: panel.settingsError,
        pollReason: svc.pollReason,
        uploading: svc.uploading,
        uploadError: svc.uploadError,
        uploadNotice: svc.uploadNotice,
        chats: (svc.view && svc.view.chats ? svc.view.chats.length : -1),
        teams: (svc.view && svc.view.teams ? svc.view.teams.length : -1),
        pluginDir: panel.pluginDir
      })
    }

    // Send what is in the box. --demo makes teams.py answer as if it had posted
    // and post nothing, so this exercises the real send path - including the
    // message going over stdin rather than in argv - without a workspace.
    function send(text: string): string {
      panel.teamsService.draft = text
      panel.teamsService.send()
      return "sending"
    }

    // The coding-agent handover, without an agent starting: the argv the window
    // would run, so a script can check what it points at and that the setting
    // actually turns it off.
    function handover(): string {
      return JSON.stringify(panel.agentArgv())
    }

    // The other direction - a draft coming back from an agent, as the shell
    // would deliver it. Returns what the window made of it.
    function draft(json: string): string {
      return String(panel.agentDraft(json))
    }

    function handovers(on: bool): void {
      panel.settings = Object.assign({}, panel.settings, { agentHandover: on })
    }

    // Every piece of text on screen that mentions something, with whether it is
    // actually visible - for checking that a row exists in a pane too long to
    // photograph in one screenful.
    function texts(needle: string): string {
      var out = []
      function walk(item, depth) {
        if (!item || depth > 20) return
        for (var i = 0; i < item.children.length; i++) {
          var child = item.children[i]
          if (child.text !== undefined && String(child.text).indexOf(needle) >= 0)
            out.push((child.visible ? "visible: " : "hidden:  ") + String(child.text).substring(0, 80))
          walk(child, depth + 1)
        }
      }
      var content = panel.floatingWindow ? panel.floatingWindow.contentItem : null
      walk(content && content.children.length ? content.children[0] : content, 0)
      return out.join("\n")
    }

    // The overlays, which have no other way of being reached from a script.
    // Not called show(): `qs ipc show` is a subcommand of its own, and the
    // argument parser takes the call for that one and refuses the argument.
    function pane(what: string): void {
      panel.showHelp = what === "help"
    }
  }
}
