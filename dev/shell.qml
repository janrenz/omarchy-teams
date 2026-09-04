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
        density: dev.density,
        // The calendar is opt-in on a real account, because the scopes are.
        // In the harness it is always on: the fixtures answer it locally, and
        // a view that has to be switched on before it can be looked at is a
        // view nobody looks at.
        calendar: true,
        calendarWrite: true,
        calendarView: dev.calendarView,
        weekStart: "monday",
        // A toast about an invented meeting on a real desktop is exactly what
        // the demo flag exists to prevent, and this is the second switch.
        meetingReminders: false
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
    property string calendarView: "week"

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
    // is honoured only while demo is on, so on a real account - after `dev
    // account` - the same id goes in the way a clicked notification does.
    // Without that second route, `account` then `open` left the fixtures'
    // conversation on screen beside the real sidebar, which reads as the open
    // having been ignored.
    function open(id: string): void {
      dev.openConversation = id
      panel.settings = Object.assign({}, panel.settings, { demoOpen: id })
      if (panel.settings.demo === false)
        panel.open(JSON.stringify({ chat: id }))
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

    // How big the window is, because half of this layout is about what it
    // does when there is not room: the sidebar folds into a drawer, and the
    // calendar's columns fold into an agenda. Neither can be looked at
    // offscreen without being able to say how wide the window is.
    function size(width: int, height: int): string {
      // The implicit size, not the real one: offscreen there is no
      // compositor to ask for a resize, and the toplevel keeps whatever it
      // was given - but what it was given is the implicit size.
      if (panel.floatingWindow) {
        panel.floatingWindow.implicitWidth = width
        panel.floatingWindow.implicitHeight = height
      }
      return JSON.stringify({ width: panel.floatingWindow ? panel.floatingWindow.width : 0,
                              height: panel.floatingWindow ? panel.floatingWindow.height : 0 })
    }

    // The overlays, which have no other way of being reached from a script.
    // Not called show(): `qs ipc show` is a subcommand of its own, and the
    // argument parser takes the call for that one and refuses the argument.
    function pane(what: string): void {
      panel.showHelp = what === "help"
      if (what === "calendar" || what === "chats") panel.showPane(what)
    }

    // The calendar, driven the way the keyboard drives it - offscreen means no
    // keyboard reaches the window, and every one of these is a key.
    function calendar(view: string, anchor: string): string {
      panel.showPane("calendar")
      if (view !== "") {
        dev.calendarView = view
        panel.teamsService.setCalendarMode(view)
      }
      if (anchor !== "") panel.teamsService.calendarAnchor = anchor
      var svc = panel.teamsService
      return JSON.stringify({
        mode: svc.calendarMode,
        anchor: svc.calendarAnchor,
        from: svc.calendarSpan.from,
        days: svc.calendarSpan.days,
        loading: svc.calendarLoading,
        error: svc.calendarError,
        events: svc.calendarEvents.length,
        canWrite: svc.canWriteCalendar,
        onCalendar: panel.onCalendar
      })
    }

    // Opening a meeting, and answering it. The reply goes nowhere: --demo
    // answers as if it had been sent and sends nothing.
    function meeting(id: string): string {
      if (id !== "") panel.teamsService.showEvent(id)
      var svc = panel.teamsService
      return JSON.stringify({
        open: svc.openEventId,
        loading: svc.eventLoading,
        error: svc.eventError,
        subject: svc.openEvent ? svc.openEvent.subject : "",
        attendees: svc.openEvent && svc.openEvent.attendees
                   ? svc.openEvent.attendees.length : 0,
        join: svc.openEvent ? svc.openEvent.joinUrl : ""
      })
    }

    function answer(response: string): string {
      var svc = panel.teamsService
      svc.rsvp(svc.openEventId, response, "", false)
      return JSON.stringify({ error: svc.rsvpError })
    }

    // The booking form, filled in and sent - the two halves of it that a
    // script can reach without a pointer.
    function book(subject: string, date: string, from: string, to: string): string {
      panel.openNewMeeting(date, -1)
      panel.changeMeeting("subject", subject)
      if (from !== "") panel.changeMeeting("from", from)
      if (to !== "") panel.changeMeeting("to", to)
      panel.createMeeting()
      return JSON.stringify({ draft: panel.meetingDraft,
                              error: panel.teamsService.createEventError })
    }
  }
}
