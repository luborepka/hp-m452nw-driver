import Foundation

struct InstalledPrinter: Codable {
    var id: String
    var name: String
    var queue: String
    var config: DriverConfig
    var localURI: String { "ipp://localhost:\(config.port)/ipp/print" }
}

struct DriverRegistry: Codable {
    var printers: [InstalledPrinter] = []

    static func load(_ file: URL) throws -> DriverRegistry {
        guard FileManager.default.fileExists(atPath: file.path) else { return DriverRegistry() }
        let data = try Data(contentsOf: file), decoder = JSONDecoder()
        let registry: DriverRegistry
        if let current = try? decoder.decode(DriverRegistry.self, from: data) { registry = current }
        else {
            // Preserve the first release's queue, port and recovery files.
            let old = try decoder.decode(DriverConfig.self, from: data)
            let identity = DiscoveredPrinter(name: "HP M452nw", uri: old.uri, hostname: "", uuid: old.uuid).identity
            registry = DriverRegistry(printers: [InstalledPrinter(id: identity, name: "HP M452nw (Open Print)", queue: "HP_M452nw_Open", config: old)])
        }
        try registry.validate()
        return registry
    }

    func validate() throws {
        guard Set(printers.map { $0.id }).count == printers.count,
              Set(printers.map { $0.queue.lowercased() }).count == printers.count,
              Set(printers.map { $0.config.port }).count == printers.count,
              Set(printers.map { URL(fileURLWithPath: $0.config.spool).standardizedFileURL.path.lowercased() }).count == printers.count,
              printers.allSatisfy({ !$0.id.isEmpty && (1024...65535).contains($0.config.port) && $0.queue.hasPrefix("HP_M452nw_") && $0.queue.range(of: "^[A-Za-z0-9_-]{1,127}$", options: .regularExpression) != nil })
        else { throw PrintError("Printer settings contain duplicate identities, queues, ports or job folders. Restore a valid configuration before continuing.") }
    }

    func matching(_ printer: DiscoveredPrinter) -> Int? {
        printers.firstIndex { $0.id == printer.identity || ($0.config.uuid.isEmpty && $0.config.uri == printer.uri) }
    }

    mutating func add(_ printer: DiscoveredPrinter, base: URL, portAvailable: (Int) -> Bool = { _ in true }) throws -> InstalledPrinter {
        if let index = matching(printer) {
            printers[index].id = printer.identity
            printers[index].name = "\(printer.name) (Open Print)"
            printers[index].config.uri = printer.uri
            printers[index].config.uuid = printer.uuid
            try validate()
            return printers[index]
        }
        let used = Set(printers.map { $0.config.port })
        guard let port = (8631...65535).first(where: { !used.contains($0) && portAvailable($0) }) else { throw PrintError("No free local printer port is available.") }
        let queue = "HP_M452nw_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let config = DriverConfig(uri: printer.uri, uuid: printer.uuid, port: port, spool: base.appendingPathComponent("Jobs/\(queue)").path)
        let installed = InstalledPrinter(id: printer.identity, name: "\(printer.name) (Open Print)", queue: queue, config: config)
        printers.append(installed)
        try validate()
        return installed
    }
}
