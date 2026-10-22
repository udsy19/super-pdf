// Finds and presses controls of one running Super PDF process for scripts/e2e.sh, through the Accessibility API, and only
// that process (every command names it by its unix id). System Events can't read the labels SwiftUI controls give
// VoiceOver (it asks for the attribute list, which leaves them out), so this reads what a screen reader reads.
//   e2e-ax <pid> wait <name> <seconds>      an element labelled <name> appears (in any window or sheet of the process)
//   e2e-ax <pid> press <name> [prefix]      presses the button (or other control) labelled <name>; with "prefix", one whose
//                                           label starts with it; failing both, one whose label contains it
//   e2e-ax <pid> focus <name>               gives the keyboard to the text field showing or labelled <name>
//   e2e-ax <pid> dump                       one line per control of every window: role, labels (what to look at when a step fails)
//   e2e-ax <pid> click-in <name> <fx> <fy>  clicks inside the element labelled <name>, at fractions of its size
//   e2e-ax <pid> click-page <fx> <fy>       clicks the page in the document view at fractions of its size
// A label is the title, description (what VoiceOver reads) or value of the element. Nothing is pressed or clicked unless
// the process is in front once it has been asked to come forward.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: e2e-ax <pid> wait|press|focus|dump|click-in|click-page …\n".utf8))
    exit(2)
}
let command = arguments[2]
let rest = Array(arguments.dropFirst(3))
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ element: AXUIElement, _ name: String) -> String {
    if let value = attribute(element, name) as? String { return value }
    if let value = attribute(element, name) as? NSAttributedString { return value.string }
    return ""
}

func role(_ element: AXUIElement) -> String { text(element, kAXRoleAttribute) }

/// What a screen reader says for the element: the title, else the description, else the text it shows.
func labels(_ element: AXUIElement) -> [String] {
    ["AXTitle", "AXDescription", "AXAttributedDescription", "AXValue"].map { text(element, $0) }.filter { !$0.isEmpty }
}

func children(_ element: AXUIElement) -> [AXUIElement] { (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

/// Every element of the process in order: the windows, with their sheets, panels and everything inside (a page's own
/// accessibility children are left out, they are the text of the document).
func elements() -> [AXUIElement] {
    var found: [AXUIElement] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        found.append(element)
        guard depth < 60, role(element) != "AXPage" else { return }
        for child in children(element) { walk(child, depth + 1) }
    }
    var windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if windows.isEmpty {
        // A process that isn't in front lists no windows: ask it to come forward and look again.
        activate()
        Thread.sleep(forTimeInterval: 0.3)
        windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }
    if let focused = attribute(app, kAXFocusedWindowAttribute), let index = windows.firstIndex(where: { CFEqual($0, focused) }) {
        windows.insert(windows.remove(at: index), at: 0)
    }
    for window in windows { walk(window, 0) }
    return found
}

func find(_ name: String, roles: Set<String>? = nil, prefix: Bool = false, contains: Bool = false, placeholder: Bool = false) -> AXUIElement? {
    for element in elements() {
        if let roles, !roles.contains(role(element)) { continue }
        var candidates = labels(element)
        if placeholder { candidates.append(text(element, "AXPlaceholderValue")) }
        if candidates.contains(name) { return element }
        if prefix, candidates.contains(where: { $0.hasPrefix(name) }) { return element }
        if contains, candidates.contains(where: { $0.contains(name) }) { return element }
    }
    return nil
}

func frame(_ element: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let position = attribute(element, kAXPositionAttribute), let extent = attribute(element, kAXSizeAttribute),
          AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

/// Asks the process to come forward (System Events can, where a command line tool's own request isn't honoured).
func activate() {
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    script.arguments = ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(pid)) to true"]
    script.standardOutput = FileHandle.nullDevice
    script.standardError = FileHandle.nullDevice
    try? script.run()
    script.waitUntilExit()
}

func bringToFront() {
    for _ in 0..<50 {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
        activate()
        Thread.sleep(forTimeInterval: 0.1)
    }
    fail("Super PDF isn't in front; nothing was pressed or clicked")
}

func click(at point: CGPoint) {
    bringToFront()
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
}

func click(_ element: AXUIElement, _ fx: CGFloat, _ fy: CGFloat) {
    guard let box = frame(element) else { fail("the element has no frame") }
    click(at: CGPoint(x: box.minX + box.width * fx, y: box.minY + box.height * fy))
}

func number(_ index: Int) -> CGFloat {
    guard rest.count > index, let value = Double(rest[index]) else { fail("missing number argument") }
    return CGFloat(value)
}

switch command {
case "wait":
    guard rest.count == 2, let seconds = Double(rest[1]) else { fail("usage: wait <name> <seconds>") }
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if find(rest[0]) != nil { exit(0) }
        Thread.sleep(forTimeInterval: 0.5)
    } while Date() < deadline
    fail("No \(rest[0]) after \(Int(seconds)) s")
case "press":
    guard let name = rest.first else { fail("usage: press <name> [prefix]") }
    let controls: Set<String> = ["AXButton", "AXRadioButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXCell", "AXLink"]
    guard let element = find(name, roles: controls, prefix: rest.count > 1) ?? find(name, roles: controls, contains: true) else {
        fail("No control named \(name)")
    }
    bringToFront()
    if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success { click(element, 0.5, 0.5) }
case "focus":
    guard let name = rest.first else { fail("usage: focus <name>") }
    let fields: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    guard let element = find(name, roles: fields, placeholder: true) else { fail("No text field showing \(name)") }
    bringToFront()
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
case "dump":
    let plain: Set<String> = ["AXGroup", "AXImage", "AXScrollArea", "AXSplitGroup", "AXPage", "AXSplitter", "AXScrollBar", "AXValueIndicator"]
    for element in elements() where !plain.contains(role(element)) {
        print(role(element), labels(element).joined(separator: " | "), text(element, "AXPlaceholderValue"))
    }
case "click-in":
    guard let name = rest.first, let element = find(name) else { fail("No element \(rest.first ?? "")") }
    click(element, number(1), number(2))
case "click-page":
    let areas = elements().filter { role($0) == "AXScrollArea" }
    guard let page = areas.max(by: { (frame($0)?.size.width ?? 0) * (frame($0)?.size.height ?? 0)
                                     < (frame($1)?.size.width ?? 0) * (frame($1)?.size.height ?? 0) }) else { fail("No document view") }
    click(page, number(0), number(1))
default:
    fail("Unknown command \(command)")
}
