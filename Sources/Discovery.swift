import Foundation
import Darwin

struct DiscoveredPrinter: Codable {
    let name: String
    let uri: String
    let hostname: String
    let uuid: String
    var identity: String {
        if let value = UUID(uuidString: uuid.lowercased().replacingOccurrences(of: "urn:uuid:", with: "")) { return value.uuidString.lowercased() }
        return hostname.isEmpty ? uri : hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

final class PrinterDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var found: [DiscoveredPrinter] = []
    private var failure: String?
    func discover(timeout: TimeInterval = 4) throws -> [DiscoveredPrinter] {
        browser.delegate = self
        browser.searchForServices(ofType: "_ipp._tcp.", inDomain: "local.")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        browser.stop(); services.forEach { $0.stop() }
        if found.isEmpty { throw PrintError(failure ?? "No HP M452nw found. Check power, Wi-Fi and Local Network access in System Settings → Privacy & Security.") }
        return found.sorted { $0.name < $1.name }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name.localizedCaseInsensitiveContains("M452nw") else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 3)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        failure = "Local printer discovery failed: \(errorDict). Check Local Network permissions."
    }
    func netServiceDidResolveAddress(_ service: NetService) {
        let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let path = txt["rp"].flatMap { String(data: $0, encoding: .utf8) } ?? "ipp/print"
        let uuid = txt["UUID"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var addresses: [String] = []
        for data in service.addresses ?? [] {
            data.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: host))
                }
            }
        }
        // A scoped link-local IPv6 address stays on the LAN even when a VPN
        // advertises an overlapping IPv4 subnet. Do not change the VPN routes.
        let host = addresses.first { $0.lowercased().hasPrefix("fe80:") && $0.contains("%") }
            ?? service.hostName ?? addresses.first ?? ""
        guard !host.isEmpty else { return }
        let authority = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        let item = DiscoveredPrinter(name: service.name, uri: "ipp://\(authority):\(service.port)/\(path)", hostname: service.hostName ?? "", uuid: uuid)
        if !found.contains(where: { $0.identity == item.identity }) { found.append(item) }
    }
}
