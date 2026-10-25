import AppKit

umask(0o077)
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments.first == "--serve" {
        guard let index = arguments.firstIndex(of: "--config"), index + 1 < arguments.count else { throw PrintError("Missing --config") }
        let registry = try DriverRegistry.load(URL(fileURLWithPath: arguments[index + 1]))
        let drivers = try registry.printers.map { try NativeDriver($0.config, name: $0.name, queue: $0.queue) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        for driver in drivers { try driver.listen() }
        withExtendedLifetime(drivers) { NSApplication.shared.run() }
    } else if arguments.first == "--install" {
        if let name = try installDriver() { print("Installed \(name).") }
    } else if arguments.first == "--uninstall" {
        try uninstallDriver()
        print("Removed HP M452nw driver, queue and saved job files.")
    } else {
        #if TESTING
        try runDiagnostics()
        #else
        if arguments.first == "--help" {
            print("HP M452nw Driver: use the Install or Uninstall macOS package. No developer tools are required.")
        } else if arguments.isEmpty || arguments == ["--configure"] { showSetup() }
        else { throw PrintError("Unknown option. Use --help or open this application to install.") }
        #endif
    }
} catch { fputs("Error: \(error.localizedDescription)\n", stderr); exit(1) }
