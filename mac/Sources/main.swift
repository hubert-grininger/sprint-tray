// SprintTray for macOS - shows the current Jira sprint in the menu bar.
// Sprint data comes from acli-pii (must be installed and logged in).

import AppKit
import ServiceManagement

let bundleID = "com.dynatrace.sprinttray"

struct Sprint: Decodable {
    let name: String
    let state: String
    let startDate: String
    let endDate: String
}

enum SprintError: LocalizedError {
    case acliNotFound
    case acliFailed(String)
    case noSprint(String)

    var errorDescription: String? {
        switch self {
        case .acliNotFound: return "acli-pii not found - see Help"
        case .acliFailed(let msg): return "acli-pii failed: \(msg)"
        case .noSprint(let project): return "No active sprint in \(project)"
        }
    }
}

let setupHelp = """
SprintTray needs the Atlassian CLI with PII redaction (acli-pii):

1. Install acli-pii (default location: ~/.local/bin/acli-pii).
2. Log in once in Terminal:
     acli-pii jira auth login
3. Check it works:
     acli-pii jira sprint list --project \(Settings.project) --state active

Then choose Refresh in the SprintTray menu.

Change the project:
     defaults write \(bundleID) project XYZ
"""

enum Settings {
    // Configure with: defaults write com.dynatrace.sprinttray project XYZ
    static var project: String { UserDefaults.standard.string(forKey: "project") ?? "APPOBS" }
    static var refreshMinutes: Double {
        let v = UserDefaults.standard.double(forKey: "refreshMinutes")
        return v > 0 ? v : 60
    }
}

// GUI apps don't get the shell PATH, so look in the usual install locations too
func findAcli() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        dirs += path.split(separator: ":").map(String.init)
    }
    return dirs.map { "\($0)/acli-pii" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func fetchActiveSprint() throws -> Sprint {
    guard let acli = findAcli() else { throw SprintError.acliNotFound }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: acli)
    p.arguments = ["jira", "sprint", "list", "--project", Settings.project, "--state", "active", "--json"]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()

    if p.terminationStatus != 0 {
        var msg = String(decoding: errData, as: UTF8.self)
            .unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        if msg.range(of: "auth|login|401|unauthori|credential|token", options: [.regularExpression, .caseInsensitive]) != nil {
            msg = "Not logged in to Jira (\(msg))"
        }
        throw SprintError.acliFailed(msg)
    }

    let sprints = try JSONDecoder().decode([Sprint].self, from: outData)
    // Prefer real sprints ("... Sprint 351") over long-running planning buckets
    var candidates = sprints.filter { $0.name.range(of: #"Sprint\s*\d+"#, options: .regularExpression) != nil }
    if candidates.isEmpty { candidates = sprints }
    guard let sprint = candidates.max(by: {
        (parseDate($0.startDate) ?? .distantPast) < (parseDate($1.startDate) ?? .distantPast)
    }) else { throw SprintError.noSprint(Settings.project) }
    return sprint
}

// Dark blue in light mode, light blue in dark mode (dark blue is unreadable on a dark menu bar)
let textColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1)
        : NSColor(red: 0, green: 40 / 255, blue: 120 / 255, alpha: 1)
}

func makeIcon(text: String, color: NSColor, progress: Double?) -> NSImage {
    let height: CGFloat = 22, barH: CGFloat = 4, gap: CGFloat = 1.5
    let font = NSFont.systemFont(ofSize: progress == nil ? 15 : 13, weight: .bold)
    let textSize = (text as NSString).size(withAttributes: [.font: font])
    let width = ceil(max(textSize.width, 18))

    return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        // Drawing happens at render time, so the dynamic color follows light/dark mode
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let blockH = textSize.height + (progress == nil ? 0 : gap + barH)
        let bottom = (height - blockH) / 2
        let textY = bottom + (progress == nil ? 0 : gap + barH)
        (text as NSString).draw(at: NSPoint(x: (width - textSize.width) / 2, y: textY), withAttributes: attrs)

        if let progress = progress {
            // Green = remaining (highlighted), red = elapsed part of the sprint
            NSColor(red: 30 / 255, green: 160 / 255, blue: 60 / 255, alpha: 1).setFill()
            NSRect(x: 0, y: bottom, width: width, height: barH).fill()
            NSColor(red: 200 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1).setFill()
            NSRect(x: 0, y: bottom, width: (width * CGFloat(min(1, max(0, progress)))).rounded(), height: barH).fill()
        }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let infoItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    var sprintName = ""
    var lastError = ""
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: quit if SprintTray is already running
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { NSApp.terminate(nil); return }

        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "Copy Sprint Name", action: #selector(copyName), keyEquivalent: "c")
        menu.addItem(withTitle: "Help / Status", action: #selector(showHelp), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SprintTray", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
        updateLoginItem()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.refreshMinutes * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try fetchActiveSprint() }
            DispatchQueue.main.async { self.apply(result) }
        }
    }

    func apply(_ result: Result<Sprint, Error>) {
        switch result {
        case .success(let s):
            sprintName = s.name
            lastError = ""
            let num = s.name.range(of: #"\d+(?=\D*$)"#, options: .regularExpression).map { String(s.name[$0]) } ?? "S"
            let start = parseDate(s.startDate) ?? Date(), end = parseDate(s.endDate) ?? Date()
            let total = end.timeIntervalSince(start)
            let progress = total > 0 ? min(1, max(0, Date().timeIntervalSince(start) / total)) : 0
            let days = Int(ceil(end.timeIntervalSinceNow / 86400))
            let df = DateFormatter()
            df.dateFormat = "EEE dd.MM."
            let tip = "\(s.name) - ends \(df.string(from: end)) (\(days) d left, \(Int(progress * 100))%)"
            statusItem.button?.image = makeIcon(text: num, color: textColor, progress: progress)
            statusItem.button?.toolTip = tip
            infoItem.title = tip
        case .failure(let error):
            let text = error.localizedDescription
            statusItem.button?.image = makeIcon(text: "?", color: .systemRed, progress: nil)
            statusItem.button?.toolTip = "Sprint: \(text)"
            infoItem.title = "⚠︎ \(text)"
            // Show the help once per distinct problem
            if text != lastError {
                lastError = text
                showHelp()
            }
        }
    }

    @objc func copyName() {
        guard !sprintName.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sprintName, forType: .string)
    }

    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = lastError.isEmpty ? "SprintTray: OK" : "SprintTray: cannot read sprint"
        alert.informativeText = (lastError.isEmpty ? "Current sprint: \(sprintName)" : "Problem: \(lastError)")
            + "\n\n" + setupHelp
        alert.alertStyle = lastError.isEmpty ? .informational : .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
        updateLoginItem()
    }

    func updateLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
