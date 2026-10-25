import AppKit

private let driverBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HP Open Print")
private let driverRoot = driverBase.appendingPathComponent("Driver")
private let driverApp = driverRoot.appendingPathComponent("HP M452nw Driver.app")
private let launchFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/org.hpopenprint.driver.plist")
private let service = "gui/\(getuid())/org.hpopenprint.driver"

@discardableResult func command(_ executable: String, _ arguments: [String], ignoringFailure: Bool = false) throws -> String {
    let child = Process(), pipe = Pipe()
    child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
    child.standardOutput = pipe; child.standardError = pipe
    try child.run()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    child.waitUntilExit()
    if child.terminationStatus != 0 && !ignoringFailure { throw PrintError(output.isEmpty ? "\(executable) failed" : output) }
    return output
}

func requireIdle(_ base: URL) throws {
    let jobs = base.appendingPathComponent("Jobs"), fm = FileManager.default
    guard fm.fileExists(atPath: jobs.path) else { return }
    var failure: Error?
    guard let files = fm.enumerator(at: jobs, includingPropertiesForKeys: nil, errorHandler: { _, error in failure = error; return false }) else { throw PrintError("Cannot inspect saved print jobs.") }
    for case let record as URL in files where record.lastPathComponent == "record.json" {
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any]
        guard let state = data?["state"] as? Int, [7, 8, 9].contains(state) else {
            throw PrintError("Finish or cancel the current print job before changing the driver.")
        }
    }
    if let failure { throw failure }
}

private func checkQueue(_ printer: InstalledPrinter) throws -> Bool {
    guard let destination = try? command("/usr/bin/lpstat", ["-v", printer.queue]) else { return false }
    guard destination.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(": \(printer.localURI)") else { throw PrintError("The queue \(printer.queue) is used by another printer.") }
    if let jobs = try? command("/usr/bin/lpstat", ["-W", "not-completed", "-o", printer.queue]), !jobs.isEmpty {
        throw PrintError("Finish or cancel the current print job before changing the driver.")
    }
    return true
}

private func setupLock<T>(_ body: () throws -> T) throws -> T {
    let file = open(driverRoot.appendingPathComponent(".setup.lock").path, O_CREAT | O_RDWR, 0o600)
    guard file >= 0 else { throw PrintError("Cannot lock printer setup.") }
    defer { close(file) }
    guard flock(file, LOCK_EX | LOCK_NB) == 0 else { throw PrintError("Another printer setup is open. Close it and try again.") }
    return try body()
}

func choosePrinter(_ found: [DiscoveredPrinter], registry: DriverRegistry) -> DiscoveredPrinter? {
    NSApplication.shared.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert(), picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 490, height: 28), pullsDown: false)
    alert.messageText = "Choose your HP M452nw printer"
    alert.informativeText = "Add a printer or update one you already added. Your other printers stay configured. Reopen this installer to add another printer."
    for printer in found {
        let address = printer.hostname.isEmpty ? (URL(string: printer.uri)?.host ?? printer.uri) : printer.hostname
        picker.addItem(withTitle: "\(printer.name) — \(address)\(registry.matching(printer) == nil ? "" : " (added)")")
    }
    picker.setAccessibilityLabel("Printer")
    alert.accessoryView = picker
    alert.addButton(withTitle: "Add or Update Printer"); alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn, found.indices.contains(picker.indexOfSelectedItem) else { return nil }
    return found[picker.indexOfSelectedItem]
}

@discardableResult func installDriver() throws -> String? {
    guard Bundle.main.bundleURL.standardizedFileURL == driverApp.standardizedFileURL else { throw PrintError("Install the driver using its macOS installer package first.") }
    return try setupLock {
        let configFile = driverRoot.appendingPathComponent("config.json"), fm = FileManager.default
        var registry = try DriverRegistry.load(configFile)
        try requireIdle(driverBase)
        for printer in registry.printers { _ = try checkQueue(printer) }
        try command("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", driverApp.path])
        guard let found = choosePrinter(try PrinterDiscovery().discover(), registry: registry) else { return nil }
        let selected = try registry.add(found, base: driverBase, portAvailable: { port in
            let socket = hp_listen(Int32(port)); guard socket >= 0 else { return false }; close(socket); return true
        })
        _ = try checkQueue(selected)
        // A print job may have arrived while the picker was open.
        try requireIdle(driverBase)
        for printer in registry.printers { _ = try checkQueue(printer) }
        let backups = [configFile, launchFile].map { ($0, try? Data(contentsOf: $0)) }
        let agent: [String: Any] = ["Label": "org.hpopenprint.driver", "ProgramArguments": [driverApp.appendingPathComponent("Contents/MacOS/hp-open-print").path, "--serve", "--config", configFile.path], "AssociatedBundleIdentifiers": ["org.hpopenprint.driver"], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10, "Umask": 0o077, "LimitLoadToSessionType": "Aqua", "StandardOutPath": driverRoot.appendingPathComponent("driver.log").path, "StandardErrorPath": driverRoot.appendingPathComponent("driver.log").path]
        try fm.createDirectory(at: launchFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try command("/bin/launchctl", ["bootout", service], ignoringFailure: true)
        do {
            try JSONEncoder().encode(registry).write(to: configFile, options: .atomic)
            try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: launchFile, options: .atomic)
            try command("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchFile.path])
            var ready = false
            for _ in 0..<25 {
                if registry.printers.allSatisfy({ printer in
                    guard let info = try? Printer(uri: printer.localURI).probe() else { return false }
                    return cString(info.model).hasSuffix("Open Print Native")
                }) { ready = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard ready else { throw PrintError("Driver did not start. Inspect \(driverRoot.appendingPathComponent("driver.log").path).") }
            try command("/usr/sbin/lpadmin", ["-p", selected.queue, "-E", "-v", selected.localURI, "-P", driverApp.appendingPathComponent("Contents/Resources/HP-M452nw-Open.ppd").path, "-D", selected.name, "-o", "PageSize=A4", "-o", "Duplex=None", "-o", "printer-is-shared=false", "-o", "printer-error-policy=stop-printer"])
        } catch {
            _ = try? command("/bin/launchctl", ["bootout", service], ignoringFailure: true)
            for (file, data) in backups {
                if let data { try? data.write(to: file, options: .atomic) }
                else { try? fm.removeItem(at: file) }
            }
            if backups[1].1 != nil { _ = try? command("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchFile.path]) }
            throw error
        }
        return selected.name
    }
}

func uninstallDriver() throws {
    try setupLock {
        let registry = try DriverRegistry.load(driverRoot.appendingPathComponent("config.json"))
        try requireIdle(driverBase)
        let queues = try registry.printers.filter { try checkQueue($0) }
        for printer in queues { try command("/usr/sbin/lpadmin", ["-x", printer.queue]) }
        try command("/bin/launchctl", ["bootout", service], ignoringFailure: true)
        let fm = FileManager.default
        for file in [launchFile, driverBase.appendingPathComponent("Jobs"), driverRoot] where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        if (try? fm.contentsOfDirectory(atPath: driverBase.path).isEmpty) == true { try fm.removeItem(at: driverBase) }
    }
}

func showSetup() {
    NSApplication.shared.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    let result = NSAlert()
    do {
        guard let name = try installDriver() else { return }
        result.messageText = "Your printer is ready"
        result.informativeText = "Choose \(name) in File → Print. For two-sided printing, empty front Tray 1 first and reload the printed stack when the printer asks."
    } catch { result.messageText = "Printer setup needs attention"; result.informativeText = error.localizedDescription }
    result.runModal()
}
