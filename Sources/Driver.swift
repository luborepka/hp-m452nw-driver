import Foundation

struct DriverConfig: Codable { var uri: String; var uuid: String; var port: Int; var spool: String }
struct ProtocolError: Error { let message: String; let status: Int32; init(_ message: String, _ status: Int32 = 0x0400) { self.message = message; self.status = status } }

// All protocol framing and attribute encoding is delegated to system libcups.
struct IPP {
    let pointer: OpaquePointer
    var group = IPP_TAG_PRINTER
    func string(_ name: String, _ fallback: String = "") -> String {
        guard let value = ippGetString(ippFindAttribute(pointer, name, IPP_TAG_ZERO), 0, nil) else { return fallback }
        return String(cString: value)
    }
    func integer(_ name: String, _ fallback: Int = 0) -> Int {
        guard let attr = ippFindAttribute(pointer, name, IPP_TAG_ZERO) else { return fallback }
        return Int(ippGetInteger(attr, 0))
    }
    func text(_ name: String, _ value: String, _ tag: ipp_tag_t = IPP_TAG_KEYWORD) {
        ippAddString(pointer, group, tag, name, nil, value)
    }
    func strings(_ name: String, _ values: [String], _ tag: ipp_tag_t = IPP_TAG_KEYWORD) {
        let strings = values.map { strdup($0)! }; defer { strings.forEach { free($0) } }
        let pointers = strings.map { UnsafePointer<CChar>?($0) }
        pointers.withUnsafeBufferPointer { _ = ippAddStrings(pointer, group, tag, name, Int32(values.count), nil, $0.baseAddress) }
    }
    func number(_ name: String, _ value: Int, _ tag: ipp_tag_t = IPP_TAG_INTEGER) { ippAddInteger(pointer, group, tag, name, Int32(value)) }
    func flag(_ name: String, _ value: Bool) { ippAddBoolean(pointer, group, name, value ? 1 : 0) }
}

final class Job: Codable {
    var id: Int; var title: String; var user: String; var sides: String; var copies: Int; var paper: Paper; var color: String
    var state = 3; var phase = "receiving"; var message = "Receiving document"; var document_received = false
    var created = Int(Date().timeIntervalSince1970); var completed: Int?; var physical_id: Int?; var sheets: Int?
    init(id: Int, request: IPP) throws {
        self.id = id; title = String(request.string("job-name", "Document").prefix(255)); user = String(request.string("requesting-user-name", "local").prefix(255))
        sides = request.string("sides", "one-sided"); copies = request.integer("copies", 1)
        color = request.string("print-color-mode", request.string("output-mode", "color"))
        var media = request.string("media", "iso_a4_210x297mm")
        if let col = ippGetCollection(ippFindAttribute(request.pointer, "media-col", IPP_TAG_BEGIN_COLLECTION), 0),
           let size = ippGetCollection(ippFindAttribute(col, "media-size", IPP_TAG_BEGIN_COLLECTION), 0) {
            let dimensions = IPP(pointer: size)
            switch (dimensions.integer("x-dimension"), dimensions.integer("y-dimension")) {
            case (21000, 29700): media = "iso_a4_210x297mm"
            case (21590, 27940): media = "na_letter_8.5x11in"
            default: throw ProtocolError("Choose A4 or US Letter", 0x040b)
            }
        }
        guard ["iso_a4_210x297mm", "na_letter_8.5x11in", "A4", "Letter"].contains(media),
              ["one-sided", "two-sided-long-edge", "two-sided-short-edge"].contains(sides), (1...50).contains(copies),
              ["auto", "color", "monochrome", "auto-monochrome"].contains(color) else { throw ProtocolError("Unsupported print settings", 0x040b) }
        guard ["application/pdf", "application/octet-stream"].contains(request.string("document-format", "application/pdf")) else { throw ProtocolError("Only PDF input is supported", 0x040a) }
        guard request.string("compression", "none") == "none" else { throw ProtocolError("Compression is not supported", 0x040f) }
        paper = ["Letter", "na_letter_8.5x11in"].contains(media) ? .letter : .a4
        color = color.contains("monochrome") ? "monochrome" : "color"
    }
    var terminal: Bool { [7, 8, 9].contains(state) }
    var duplex: Bool { sides != "one-sided" }
}

final class NativeDriver {
    let config: DriverConfig
    let name: String
    let queue: String
    let printer: PrinterTransport
    let root: URL
    let lock = NSRecursiveLock()
    let worker = DispatchQueue(label: "org.hpopenprint.jobs")
    var jobs: [Int: Job] = [:]
    var nextID = 1
    let started = Date()
    let startWorker: Bool
    var uri: String { "ipp://localhost:\(config.port)/ipp/print" }
    static let reload = "Reload the output stack into front Tray 1, printed side DOWN, TOP EDGE first. Keep its order and press OK if asked."

    init(_ config: DriverConfig, printer: PrinterTransport? = nil, startWorker: Bool = true, name: String = "HP M452nw Open", queue: String = "HP_M452nw_Open") throws {
        self.name = name; self.queue = queue
        self.config = config; self.printer = printer ?? Printer(uri: config.uri); self.startWorker = startWorker; root = URL(fileURLWithPath: config.spool, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let file = directory.appendingPathComponent("record.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: file))
            jobs[job.id] = job; nextID = max(nextID, job.id + 1)
            if !job.terminal {
                if job.phase.hasPrefix("submitting") {
                    job.state = 6; job.phase = "uncertain"; job.message = "Submission outcome unknown after restart. Inspect the printer before cancelling and retrying."; try save(job)
                } else if !job.document_received {
                    job.state = 8; job.message = "Document upload interrupted before printing"; try save(job)
                }
            }
        }
        for job in jobs.values where !job.terminal && job.state != 6 { enqueue(job) }
    }
    func folder(_ job: Job) -> URL { root.appendingPathComponent(String(job.id), isDirectory: true) }
    func save(_ job: Job) throws {
        try FileManager.default.createDirectory(at: folder(job), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder(job).appendingPathComponent("record.json")
        try JSONEncoder().encode(job).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
    }
    func update(_ job: Job, state: Int? = nil, phase: String? = nil, message: String? = nil) throws {
        try lock.withLock {
            guard (state.map({ $0 != job.state }) ?? false) || (phase.map({ $0 != job.phase }) ?? false) || (message.map({ $0 != job.message }) ?? false) else { return }
            if let state { job.state = state }; if let phase { job.phase = phase }; if let message { job.message = message }; try save(job)
        }
    }
    func enqueue(_ job: Job) {
        guard startWorker else { return }
        worker.async { [self] in autoreleasepool {
            do { try process(job) } catch {
                try? lock.withLock {
                    guard !job.terminal, job.phase != "uncertain" else { return }
                    let uncertain = job.phase.hasPrefix("submitting")
                    try update(job, state: uncertain ? 6 : 8, phase: uncertain ? "uncertain" : "failed", message: error.localizedDescription)
                }
            }
        } }
    }
    func receive(_ job: Job, document: URL) throws {
        guard !job.document_received, !job.terminal else { throw ProtocolError("Document already received", 0x0404) }
        let file = try FileHandle(forReadingFrom: document); defer { try? file.close() }
        guard try file.read(upToCount: 5) == Data("%PDF-".utf8) else { try update(job, state: 8, message: "Input must be a PDF"); throw ProtocolError("Input must be a PDF", 0x040a) }
        try FileManager.default.moveItem(at: document, to: folder(job).appendingPathComponent("input.pdf"))
        job.document_received = true; try update(job, phase: "pending", message: "Preparing document"); enqueue(job)
    }
    func submit(_ job: Job, side: String, file: URL, tray: String) throws {
        try lock.withLock {
            guard !job.terminal, job.phase != "uncertain" else { throw PrintError("Job stopped") }
            try update(job, phase: "submitting-\(side)", message: "Sending \(side) to printer")
        }
        let id = try printer.submit(file, title: "\(job.title) - \(side)", paper: job.paper.ipp, tray: tray, color: job.color, check: false)
        try lock.withLock {
            job.physical_id = id
            if job.terminal || job.phase == "uncertain" { try cancelPhysical(job, id); throw PrintError("Job cancelled") }
            try update(job, phase: "printing-\(side)")
        }
    }
    func wait(_ job: Job, back: Bool = false) throws {
        while true {
            let id: Int = try lock.withLock {
                guard !job.terminal, job.phase != "uncertain", let id = job.physical_id else { throw PrintError("Job stopped") }; return id
            }
            do {
                let (state, reason) = try printer.status(id)
                if state == 9 { return }
                if [7, 8].contains(state) { try update(job, state: state, message: "Physical job stopped: \(reason)"); throw PrintError("Physical job stopped") }
                try update(job, message: back ? Self.reload : "Printing front sides. Leave Tray 1 empty until the printer requests it.")
            } catch {
                if lock.withLock({ job.terminal || job.phase == "uncertain" }) { throw error }
                try update(job, message: "Cannot confirm printer status; keeping this job without resending. \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }
    func process(_ job: Job) throws {
        guard lock.withLock({ !job.terminal && job.state != 6 }) else { return }
        let directory = folder(job), passes = directory.appendingPathComponent("passes")
        if job.phase == "pending" {
            let info = try printer.probe()
            guard info.accepting != 0 else { throw PrintError("The printer is not accepting jobs") }
            if job.duplex {
                guard info.tray1_loaded == 0 else { try update(job, state: 6, message: "Empty front Tray 1, cancel this job and print again."); return }
                let prepared = try preparePDF(directory.appendingPathComponent("input.pdf"), directory: passes, binding: job.sides.hasSuffix("short-edge") ? .short : .long, paper: job.paper, copies: job.copies)
                job.sheets = prepared.sheets
            } else if job.copies > 1 {
                try repeatPDF(directory.appendingPathComponent("input.pdf"), to: directory.appendingPathComponent("single.pdf"), copies: job.copies)
            }
            try lock.withLock {
                guard !job.terminal, job.state != 6 else { throw PrintError("Job stopped") }
                try update(job, state: 5)
            }
            let fronts = job.duplex ? passes.appendingPathComponent("fronts.pdf") : directory.appendingPathComponent(job.copies == 1 ? "input.pdf" : "single.pdf")
            try submit(job, side: "fronts", file: fronts, tray: job.duplex ? "tray-2" : "auto")
        }
        if job.phase == "printing-fronts" {
            try wait(job)
            if job.duplex {
                guard try printer.probe().tray1_loaded == 0 else { try update(job, state: 6, message: "Tray 1 was loaded early. Inspect the stack, cancel and restart."); return }
                try submit(job, side: "backs", file: passes.appendingPathComponent("backs.pdf"), tray: "tray-1")
            }
        }
        if job.phase == "printing-backs" { try wait(job, back: true) }
        try lock.withLock {
            guard !job.terminal, job.state != 6 else { return }
            job.completed = Int(Date().timeIntervalSince1970); try update(job, state: 9, phase: "completed", message: "Printing complete")
            if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
                for case let file as URL in files where file.pathExtension == "pdf" { try FileManager.default.removeItem(at: file) }
            }
        }
    }
    func cancel(_ job: Job) throws {
        guard !job.terminal else { throw ProtocolError("Job has finished", 0x0404) }
        try update(job, state: 7, message: "Cancelled. Inspect the printer before retrying any uncertain submission.")
        if let id = job.physical_id { try cancelPhysical(job, id) }
    }
    func cancelPhysical(_ job: Job, _ id: Int) throws {
        do { try printer.cancel(id) } catch {
            if let status = try? printer.status(id), [7, 8, 9].contains(status.0) { return }
            try update(job, state: 6, phase: "uncertain", message: "Cancellation unconfirmed. Cancel at the printer before cancelling this queue job again.")
            throw error
        }
    }

    func handle(_ request: IPP, response: IPP, document: URL) throws {
        try lock.withLock {
            var minor: Int32 = 0
            let major = ippGetVersion(request.pointer, &minor)
            guard (major == 1 && minor == 1) || (major == 2 && minor == 0) else { throw ProtocolError("Unsupported IPP version", 0x0503) }
            switch ippGetOperation(request.pointer).rawValue {
            case 11: attributes(response)
            case 4: _ = try Job(id: 0, request: request)
            case 2, 5:
                // Expired uploads have not printed and can safely be discarded.
                for job in jobs.values where !job.terminal && !job.document_received && Date().timeIntervalSince1970 - Double(job.created) > 300 { try update(job, state: 8, message: "Upload expired before printing") }
                guard !jobs.values.contains(where: { !$0.terminal }) else { throw ProtocolError("Finish or cancel the active job first", 0x0507) }
                let job = try Job(id: nextID, request: request); nextID += 1; jobs[job.id] = job; try save(job)
                if ippGetOperation(request.pointer).rawValue == 2 { try receive(job, document: document) }
                jobAttributes(job, response)
            case 10:
                let which = request.string("which-jobs", "not-completed")
                for job in jobs.values.sorted(by: { $0.id < $1.id }) where which == "all" || (job.terminal == (which == "completed")) { ippAddSeparator(response.pointer); jobAttributes(job, response) }
            case 6, 8, 9:
                let id = request.integer("job-id", Int(request.string("job-uri").split(separator: "/").last ?? "") ?? -1)
                guard let job = jobs[id] else { throw ProtocolError("Job not found", 0x0406) }
                if ippGetOperation(request.pointer).rawValue == 6 {
                    if let last = ippFindAttribute(request.pointer, "last-document", IPP_TAG_BOOLEAN), ippGetBoolean(last, 0) == 0 { throw ProtocolError("Multiple documents are not supported", 0x0501) }
                    try receive(job, document: document)
                } else if ippGetOperation(request.pointer).rawValue == 8 { try cancel(job); return }
                jobAttributes(job, response)
            default: throw ProtocolError("Operation not supported", 0x0501)
            }
        }
    }
    func jobAttributes(_ job: Job, _ response: IPP) {
        var r = response; r.group = IPP_TAG_JOB
        r.number("job-id", job.id); r.number("job-state", job.state, IPP_TAG_ENUM)
        r.text("job-uri", uri + "/jobs/\(job.id)", IPP_TAG_URI); r.text("job-printer-uri", uri, IPP_TAG_URI)
        r.text("job-name", job.title, IPP_TAG_NAME); r.text("job-originating-user-name", job.user, IPP_TAG_NAME)
        r.text("job-state-message", job.message, IPP_TAG_TEXT)
        r.text("job-state-reasons", job.state == 9 ? "job-completed-successfully" : job.state == 7 ? "job-canceled-by-user" : job.state == 6 ? "job-stopped" : "none")
        r.number("time-at-creation", max(1, job.created - Int(started.timeIntervalSince1970)))
        r.number("job-impressions-completed", 0); r.number("job-media-sheets-completed", 0)
    }
    func attributes(_ r: IPP) {
        let active = jobs.values.first { !$0.terminal }
        var identifier = [CChar](repeating: 0, count: 128)
        httpAssembleUUID("localhost", Int32(config.port), queue, 0, &identifier, identifier.count)
        for (key, value) in ["printer-uri-supported": uri, "printer-more-info": "http://localhost:\(config.port)/", "printer-uuid": String(cString: identifier)] { r.text(key, value, IPP_TAG_URI) }
        r.text("printer-name", String(name.prefix(255)), IPP_TAG_NAME)
        for (key, value) in ["printer-info": String(name.prefix(255)), "printer-location": "Local printer driver", "printer-make-and-model": "HP Color LaserJet M452nw Open Print Native", "printer-state-message": active?.message ?? "Ready. Empty front Tray 1 before manual duplex printing."] { r.text(key, value, IPP_TAG_TEXT) }
        r.number("printer-state", active == nil ? 3 : 4, IPP_TAG_ENUM)
        r.flag("printer-is-accepting-jobs", active == nil); r.flag("color-supported", true); r.flag("multiple-document-jobs-supported", false)
        r.number("queued-job-count", active == nil ? 0 : 1); r.number("printer-up-time", max(1, Int(Date().timeIntervalSince(started))))
        r.number("multiple-operation-time-out", 300); r.number("copies-default", 1)
        ippAddRange(r.pointer, r.group, "copies-supported", 1, 50)
        for key in ["printer-resolution-default", "printer-resolution-supported"] { ippAddResolution(r.pointer, r.group, key, IPP_RES_PER_INCH, 600, 600) }
        for (key, value) in ["print-quality-default": 4, "print-quality-supported": 4, "finishings-default": 3, "finishings-supported": 3, "orientation-requested-default": 3] { r.number(key, value, IPP_TAG_ENUM) }
        let operations: [Int32] = [2, 4, 5, 6, 8, 9, 10, 11], orientations: [Int32] = [3, 4, 5, 6]
        operations.withUnsafeBufferPointer { _ = ippAddIntegers(r.pointer, r.group, IPP_TAG_ENUM, "operations-supported", Int32(operations.count), $0.baseAddress) }
        orientations.withUnsafeBufferPointer { _ = ippAddIntegers(r.pointer, r.group, IPP_TAG_ENUM, "orientation-requested-supported", Int32(orientations.count), $0.baseAddress) }
        r.text("charset-configured", "utf-8", IPP_TAG_CHARSET); r.text("charset-supported", "utf-8", IPP_TAG_CHARSET)
        r.text("natural-language-configured", "en", IPP_TAG_LANGUAGE); r.text("generated-natural-language-supported", "en", IPP_TAG_LANGUAGE)
        r.text("document-format-default", "application/pdf", IPP_TAG_MIMETYPE); r.strings("document-format-supported", ["application/pdf", "application/octet-stream"], IPP_TAG_MIMETYPE)
        for (key, value) in ["uri-security-supported": "none", "uri-authentication-supported": "none", "printer-state-reasons": "none", "compression-supported": "none", "pdl-override-supported": "attempted", "sides-default": "one-sided", "print-color-mode-default": "color", "output-mode-default": "color", "media-default": "iso_a4_210x297mm", "multiple-document-handling-default": "separate-documents-collated-copies", "multiple-document-handling-supported": "separate-documents-collated-copies"] { r.text(key, value) }
        for (key, values) in ["ipp-versions-supported": ["1.1", "2.0"], "sides-supported": ["one-sided", "two-sided-long-edge", "two-sided-short-edge"], "print-color-mode-supported": ["auto", "color", "monochrome"], "output-mode-supported": ["color", "monochrome"], "media-supported": ["iso_a4_210x297mm", "na_letter_8.5x11in"], "which-jobs-supported": ["completed", "not-completed", "all"], "job-creation-attributes-supported": ["copies", "media", "sides", "print-color-mode", "job-name", "orientation-requested"]] { r.strings(key, values) }
        let media = ippNew()!, size = ippNew()!; defer { ippDelete(media); ippDelete(size) }
        let dimensions = IPP(pointer: size, group: IPP_TAG_ZERO); dimensions.number("x-dimension", 21000); dimensions.number("y-dimension", 29700)
        ippAddCollection(media, IPP_TAG_ZERO, "media-size", size)
        let collection = IPP(pointer: media, group: IPP_TAG_ZERO); collection.text("media-source", "auto"); collection.text("media-type", "stationery")
        ippAddCollection(r.pointer, r.group, "media-col-default", media)
    }

    func connection(_ http: OpaquePointer) {
        defer { httpClose(http) }
        let document = root.appendingPathComponent(".upload-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: document) }
        guard let request = hp_receive(http, document.path) else { return }
        defer { ippDelete(request) }
        let response = ippNewResponse(request)!
        defer { ippDelete(response) }
        do { try handle(IPP(pointer: request), response: IPP(pointer: response), document: document) }
        catch {
            let status = ipp_status_t(rawValue: (error as? ProtocolError)?.status ?? 0x0500)
            ippSetStatusCode(response, status)
            ippAddString(response, IPP_TAG_OPERATION, IPP_TAG_TEXT, "status-message", nil, (error as? ProtocolError)?.message ?? error.localizedDescription)
        }
        hp_reply(http, response)
    }
    func listen() throws {
        let listener = hp_listen(Int32(config.port))
        guard listener >= 0 else { throw PrintError("Cannot listen on local port \(config.port)") }
        let slots = DispatchSemaphore(value: 8)
        DispatchQueue.global().async { [self] in
            while true {
                guard let http = httpAcceptConnection(listener, 1) else {
                    if errno == EINTR { continue }
                    fputs("Local print listener failed\n", stderr); exit(1)
                }
                slots.wait()
                DispatchQueue.global().async { [self] in
                    autoreleasepool { connection(http) }
                    slots.signal()
                }
            }
        }
    }
}
