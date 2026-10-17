import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool deleteConfirmOpen: false
  property string deleteTarget: ""
  property bool addFormOpen: false
  property string addNotice: ""
  property bool replaceConfirmOpen: false
  property string replaceTarget: ""
  // Non-empty while the add form is doubling as the F2 rename form.
  property string renameSource: ""
  property var entries: []

  // Shares the [menu] surface tokens — themes that style the menu also
  // style this selector, same as the clipboard plugin.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(500), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.spacing.rowPaddingX * 2)

  function open() {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    listProc.running = true
    root.rebuildDisplay(true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.cancelDelete()
    root.cancelReplace()
    root.closeAddForm()
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // secret-tool search output: blocks starting with "[/path]", then
  // "field = value" lines. Only names are kept; "secret =" lines are
  // deliberately never stored anywhere.
  function loadEntries(raw) {
    var lines = raw.split("\n")
    var parsed = []
    var current = null

    function push() {
      if (!current) return
      var name = current.name || current.label
      if (name) parsed.push({ name: name })
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.length > 0 && line.charAt(0) === "[") {
        push()
        current = { name: "", label: "" }
        continue
      }
      if (!current) continue
      if (line.indexOf("label = ") === 0) current.label = line.substring(8)
      else if (line.indexOf("attribute.name = ") === 0) current.name = line.substring(17)
    }
    push()

    parsed.sort(function(a, b) { return a.name.localeCompare(b.name) })
    root.entries = parsed
    // A first open lands before secret-tool has answered, so the cursor starts
    // on the add row for want of anything else; move it to the first real key
    // once one exists, but never yank it out from under an active filter.
    if (root.opened) root.rebuildDisplay(root.selectedIndex === 0 && !root.filterText)
  }

  // Returns the stored spelling of a name, matched case-insensitively, or ""
  // if there is no such key. Mirrors the CLI's resolve_name.
  function existingName(name) {
    var needle = name.toLowerCase()
    for (var i = 0; i < root.entries.length; i++) {
      if (root.entries[i].name.toLowerCase() === needle) return root.entries[i].name
    }
    return ""
  }

  // The add row rests selected when the list is untouched. Once a filter
  // narrows things down the cursor moves to the first match instead, so
  // type-then-Enter copies a key rather than opening the add form.
  function defaultIndex() {
    if (!root.filterText) return 0
    return displayModel.count > 1 ? 1 : 0
  }

  function rebuildDisplay(resetCursor) {
    var filter = root.filterText.toLowerCase()

    displayModel.clear()
    displayModel.append({ kind: "add", name: "Add Key" })
    for (var i = 0; i < root.entries.length; i++) {
      var entry = root.entries[i]
      if (filter && entry.name.toLowerCase().indexOf(filter) === -1) continue
      displayModel.append({ kind: "key", name: entry.name })
    }

    if (resetCursor) selectedIndex = root.defaultIndex()
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay(true)
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  // The secret only ever flows secret-tool → wl-copy inside the spawned
  // shell; it never enters this process or any argv. --sensitive keeps it
  // out of the clipboard-history capture; --trim-newline guards against a
  // stray trailing newline breaking a pasted key.
  // Enter / click on a row. The add row is pinned at index 0, so every
  // activation has to ask what it landed on before assuming a key.
  function activate(index, paste) {
    if (index < 0 || index >= displayModel.count) return
    if (displayModel.get(index).kind === "add") root.openAddForm()
    else if (paste) root.pasteIndex(index)
    else root.copyIndex(index)
  }

  function openAddForm(name) {
    root.addNotice = ""
    root.renameSource = ""
    addName.text = name !== undefined ? name : root.filterText
    addValue.text = ""
    root.addFormOpen = true
    root.disarmPointer()
    Qt.callLater(function() {
      addName.forceActiveFocus()
      addName.selectAll()
    })
  }

  function closeAddForm() {
    // Drop the plaintext from the field's buffer as soon as the form goes
    // away, rather than leaving it live in a plugin marked keepLoaded.
    addName.text = ""
    addValue.text = ""
    root.addNotice = ""
    root.renameSource = ""
    root.addFormOpen = false
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openRenameForm(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind !== "key") return
    root.addNotice = ""
    root.renameSource = row.name
    addName.text = row.name
    addValue.text = ""
    root.addFormOpen = true
    root.disarmPointer()
    Qt.callLater(function() {
      addName.forceActiveFocus()
      addName.selectAll()
    })
  }

  function submitAdd() {
    var name = addName.text.trim()
    if (!name) {
      root.addNotice = "Name is required."
      addName.forceActiveFocus()
      return
    }
    if (root.renameSource) {
      root.submitRename(name)
      return
    }
    if (!addValue.text) {
      root.addNotice = "Value is required."
      addValue.forceActiveFocus()
      return
    }

    // Keyring attributes match literally, so storing "openai" beside an
    // existing "OPENAI" would leave two entries the CLI then refuses to
    // resolve. Reuse the stored spelling, and make the overwrite deliberate —
    // re-adding a rotated key is normal, doing it by accident isn't.
    var existing = root.existingName(name)
    storeProc.pendingName = existing || name
    storeProc.pendingValue = addValue.text
    root.closeAddForm()
    if (existing) root.requestReplace(existing)
    else storeProc.running = true
  }

  // Mirrors the CLI's mv: a match that's just the key being renamed (a pure
  // case change) isn't a collision; any other match asks before overwriting.
  function submitRename(name) {
    var source = root.renameSource
    if (name === source) {
      root.closeAddForm()
      return
    }
    var existing = root.existingName(name)
    var collides = existing && existing !== source
    renameProc.pendingOld = source
    renameProc.pendingNew = collides ? existing : name
    root.closeAddForm()
    if (collides) root.requestReplace(existing)
    else renameProc.running = true
  }

  function requestReplace(name) {
    root.replaceTarget = name
    replaceConfirm.selectedIndex = 1
    root.replaceConfirmOpen = true
  }

  function cancelReplace() {
    storeProc.pendingName = ""
    storeProc.pendingValue = ""
    renameProc.pendingOld = ""
    renameProc.pendingNew = ""
    root.replaceConfirmOpen = false
    root.replaceTarget = ""
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmReplace() {
    if (renameProc.pendingOld) renameProc.running = true
    else storeProc.running = true
    root.replaceConfirmOpen = false
    root.replaceTarget = ""
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function copyIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind !== "key") return
    root.opened = false
    Quickshell.execDetached(["bash", "-c",
      'secret-tool lookup service api-keys name "$1" | wl-copy --trim-newline --sensitive',
      "omakeys-copy", row.name])
  }

  function pasteIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind !== "key") return
    root.opened = false
    Quickshell.execDetached(["bash", "-c",
      'secret-tool lookup service api-keys name "$1" | wl-copy --trim-newline --sensitive && sleep 0.15 && wtype -M shift -k Insert -m shift',
      "omakeys-paste", row.name])
  }

  function requestDelete(index) {
    if (index < 0 || index >= displayModel.count) return
    if (displayModel.get(index).kind !== "key") return
    root.deleteTarget = displayModel.get(index).name
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = ""
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmDelete() {
    deleteProc.pendingName = root.deleteTarget
    deleteProc.running = true
    root.deleteConfirmOpen = false
    root.deleteTarget = ""
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The shell's ConfirmDialog with the button labels one step up
  // (bodySmall rather than caption); the kit exposes no knob for it.
  component KeyConfirmDialog: Item {
    id: dialog

    property bool opened: false
    property string message: ""
    property string cancelText: "Cancel"
    property string confirmText: "Confirm"
    property int selectedIndex: 1
    property color background: Color.background
    property color foreground: Color.foreground
    property color scrim: Util.alpha(Color.background, 0.7)
    property color selectedBackground: Util.alpha(Color.foreground, 0.08)
    property color selectedText: Color.accent
    property string fontFamily: Style.font.family
    property int cornerRadius: Style.cornerRadius

    signal canceled()
    signal confirmed()

    function handleKey(event) {
      if (!dialog.opened) return false

      if (event.key === Qt.Key_Escape) {
        dialog.canceled()
        return true
      } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        dialog.selectedIndex = dialog.selectedIndex === 0 ? 1 : 0
        return true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (dialog.selectedIndex === 0) dialog.canceled()
        else dialog.confirmed()
        return true
      }

      return false
    }

    visible: opened

    Rectangle {
      anchors.fill: parent
      color: dialog.scrim

      MouseArea { anchors.fill: parent; onClicked: dialog.canceled() }

      BorderSurface {
        id: card
        width: Math.min(parent.width - Style.space(32), Style.space(370))
        // Grows with the wrapped message so narrow hosts (like the menu card)
        // don't squeeze the text into the buttons.
        height: card.contentTopInset + card.contentBottomInset + messageText.implicitHeight + Style.space(20) + Style.space(34)
        anchors.centerIn: parent
        color: dialog.background
        borderSpec: Border.flat(dialog.selectedText, Style.normalBorderWidth)
        padding: Style.space(18)
        radius: dialog.cornerRadius

        MouseArea { anchors.fill: parent; onClicked: {} }

        Item {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset

          Text {
            id: messageText
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            text: dialog.message
            color: dialog.foreground
            font.family: dialog.fontFamily
            font.pixelSize: Style.font.title
            wrapMode: Text.WordWrap
          }

          Row {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Style.space(10)

            Repeater {
              model: [dialog.cancelText, dialog.confirmText]

              BorderSurface {
                required property int index
                required property string modelData

                readonly property bool selected: dialog.selectedIndex === index
                readonly property bool destructive: index === 1

                width: Style.space(88)
                height: Style.space(34)
                color: selected
                  ? (destructive ? Util.alpha(Color.urgent, 0.22) : dialog.selectedBackground)
                  : "transparent"
                borderSpec: Border.flat(destructive
                  ? (selected ? Color.urgent : Util.alpha(Color.urgent, 0.56))
                  : (selected ? dialog.selectedText : Util.alpha(dialog.foreground, 0.38)), Style.normalBorderWidth)
                radius: 0

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: modelData
                  color: destructive ? (selected ? Color.urgent : dialog.foreground) : (selected ? dialog.selectedText : dialog.foreground)
                  font.family: dialog.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: dialog.selectedIndex = index
                  onClicked: {
                    if (index === 0) dialog.canceled()
                    else dialog.confirmed()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: listProc
    // secret-tool search prints matched items on stderr, hence the redirect
    command: ["bash", "-c", "secret-tool search --all --unlock service api-keys 2>&1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadEntries(text)
    }
  }

  Process {
    id: deleteProc
    property string pendingName: ""
    command: ["secret-tool", "clear", "service", "api-keys", "name", pendingName]
    onExited: listProc.running = true
  }

  // secret-tool has no rename primitive, so the value is read under the old
  // name and stored under the new one, all inside the spawned shell — like
  // copy, it never enters this process. printf is a builtin, so the value
  // stays out of argv; the old entry is only cleared once the store succeeds.
  Process {
    id: renameProc
    property string pendingOld: ""
    property string pendingNew: ""
    command: ["bash", "-c",
      'value=$(secret-tool lookup service api-keys name "$1") || exit 1; printf %s "$value" | secret-tool store --label="$2" service api-keys name "$2" && secret-tool clear service api-keys name "$1"',
      "omakeys-rename", pendingOld, pendingNew]
    onExited: {
      pendingOld = ""
      pendingNew = ""
      listProc.running = true
    }
  }

  // The one place a secret value flows inward. It goes over stdin rather than
  // argv, which any process on the machine can read out of /proc. secret-tool
  // reads until stdin closes and stores what it got verbatim — no trailing
  // newline is written, and stdin is closed immediately to mark the end.
  Process {
    id: storeProc
    property string pendingName: ""
    property string pendingValue: ""
    stdinEnabled: true
    command: ["secret-tool", "store", "--label=" + pendingName, "service", "api-keys", "name", pendingName]
    onStarted: {
      write(pendingValue)
      pendingValue = ""
      stdinEnabled = false
    }
    onExited: {
      stdinEnabled = true
      listProc.running = true
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omakeys"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: (root.deleteConfirmOpen || root.replaceConfirmOpen || root.addFormOpen) ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // The form's TextFields own input while it's open — Tab, Escape and
          // every printable key belong to them, not to the filter.
          if (root.addFormOpen) return

          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (root.replaceConfirmOpen) {
            if (replaceConfirm.handleKey(event)) event.accepted = true
            return
          }

          if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
            root.openAddForm()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            root.requestDelete(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_F2) {
            root.openRenameForm(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(displayModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.selectedIndex, (event.modifiers & Qt.ShiftModifier) !== 0)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        // Add form. Tab and Shift+Tab cycle the two fields explicitly rather
        // than leaning on the window-wide focus chain, which would wander off
        // into the list behind it. Enter submits from either field.
        Item {
          id: addForm

          anchors.fill: parent
          visible: root.addFormOpen
          z: 10

          Rectangle {
            anchors.fill: parent
            color: root.scrim

            MouseArea { anchors.fill: parent; onClicked: root.closeAddForm() }

            BorderSurface {
              id: addCard
              width: Math.min(parent.width - Style.space(32), Style.space(370))
              height: addCard.contentTopInset + addCard.contentBottomInset + addColumn.implicitHeight
              anchors.centerIn: parent
              color: root.background
              borderSpec: Border.flat(root.selectedText, Style.normalBorderWidth)
              padding: Style.space(18)
              radius: root.cornerRadius

              MouseArea { anchors.fill: parent; onClicked: {} }

              Column {
                id: addColumn
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: addCard.contentTopInset
                anchors.leftMargin: addCard.contentLeftInset
                anchors.rightMargin: addCard.contentRightInset
                spacing: Style.space(10)

                Text {
                  text: root.renameSource ? "Rename API key" : "Add API key"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }

                TextField {
                  id: addName
                  width: parent.width
                  placeholderText: "Name  (e.g. OPENAI)"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  KeyNavigation.tab: root.renameSource ? null : addValue
                  KeyNavigation.backtab: root.renameSource ? null : addValue
                  // Handled here rather than via onAccepted: TextInput emits
                  // accepted but lets the Return propagate, so it would reach
                  // keyCatcher after the form closed and activate the selected
                  // row — or confirm the replace dialog it had just opened.
                  Keys.onReturnPressed: function(event) { root.submitAdd(); event.accepted = true }
                  Keys.onEnterPressed: function(event) { root.submitAdd(); event.accepted = true }
                  Keys.onEscapePressed: root.closeAddForm()
                }

                TextField {
                  id: addValue
                  width: parent.width
                  visible: !root.renameSource
                  password: true
                  placeholderText: "API key"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  KeyNavigation.tab: addName
                  KeyNavigation.backtab: addName
                  Keys.onReturnPressed: function(event) { root.submitAdd(); event.accepted = true }
                  Keys.onEnterPressed: function(event) { root.submitAdd(); event.accepted = true }
                  Keys.onEscapePressed: root.closeAddForm()
                }

                Text {
                  width: parent.width
                  visible: root.addNotice !== ""
                  text: root.addNotice
                  color: root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Item {
                  width: parent.width
                  height: Style.space(34)

                  Row {
                    anchors.right: parent.right
                    spacing: Style.space(10)

                    Repeater {
                      model: ["Cancel", root.renameSource ? "Rename" : "Save"]

                      BorderSurface {
                        required property int index
                        required property string modelData

                        readonly property bool isSave: index === 1

                        width: Style.space(88)
                        height: Style.space(34)
                        color: isSave ? root.selectedBackground : "transparent"
                        borderSpec: Border.flat(isSave ? root.selectedText : Util.alpha(root.foreground, 0.38), Style.normalBorderWidth)
                        radius: 0

                        Text {
                          anchors.centerIn: parent
                          text: modelData
                          color: isSave ? root.selectedText : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }

                        MouseArea {
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            if (isSave) root.submitAdd()
                            else root.closeAddForm()
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        KeyConfirmDialog {
          id: deleteConfirm

          anchors.fill: parent
          opened: root.deleteConfirmOpen
          z: 10
          message: "Delete key “" + root.deleteTarget + "”?"
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }

        KeyConfirmDialog {
          id: replaceConfirm

          anchors.fill: parent
          opened: root.replaceConfirmOpen
          z: 10
          message: "Replace key “" + root.replaceTarget + "”?"
          confirmText: "Replace"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelReplace()
          onConfirmed: root.confirmReplace()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search API keys…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: row
              required property int index
              required property string name
              required property string kind

              readonly property bool isAdd: kind === "add"
              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(10)

                Text {
                  text: row.isAdd ? "󰐕" : "󰌆"
                  height: parent.height
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  verticalAlignment: Text.AlignVCenter
                }

                Text {
                  width: parent.width - Style.space(30)
                  height: parent.height
                  text: row.name
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: row.isAdd && !row.hasCursor ? 0.75 : 1
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  elide: Text.ElideRight
                  wrapMode: Text.NoWrap
                  verticalAlignment: Text.AlignVCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) {
                  root.selectFromPointer(row.index, row, mouse)
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.activate(row.index, false)
                }
              }
            }
          }

          // The add row is always in the model, so "nothing here" means the
          // list is down to that one row.
          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count <= 1

            Text {
              text: "󰌆"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.entries.length === 0 ? "No API keys yet — pick “Add Key” above" : "No matches for “" + root.filterText + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
