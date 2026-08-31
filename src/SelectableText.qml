import QtQuick
import qs.Commons

// Text you can select and copy.
//
// A QML Text item cannot be selected at all - no drag, no Ctrl+C, nothing - so
// anything a reader might want to take out of a message has to be a read-only
// TextEdit instead. That is the whole difference; everything else here is the
// defaults that make a TextEdit behave like the Text it replaces.
//
// textFormat is pinned to PlainText here rather than left to AutoText, for the
// same reason every Text item in this plugin pins it: AutoText decides a string
// is markup the moment it finds a `<`, and markup fetches what it is told to
// fetch. Callers that really are rendering markup override it deliberately.
TextEdit {
  id: root

  // One line, cut off rather than wrapped - for headers where a long To list
  // must not push the message down the pane.
  property bool singleLine: false

  readOnly: true
  selectByMouse: true
  // Keep the selection visible after focus moves, so Ctrl+C still copies what
  // was highlighted before the pointer went to the button being reached for.
  persistentSelection: true
  wrapMode: singleLine ? TextEdit.NoWrap : TextEdit.Wrap
  clip: singleLine
  textFormat: TextEdit.PlainText
  color: Color.foreground
  // A TextEdit shows an I-beam and a blinking caret by default; read-only text
  // should look like text, not like a field somebody forgot to disable.
  cursorVisible: false
  activeFocusOnPress: true
}
