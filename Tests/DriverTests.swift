import Foundation
import PDFKit

private final class FakePrinter: PrinterTransport {
    var loaded: Int32 = 0
    var states = [9]
    var submissions: [(String, [String])] = []
    var cancelled: [Int] = []
    var failSubmit = false
    var failCancel = false
    var onSubmit: (() throws -> Void)?
    func probe() throws -> HPPrinterInfo { var info = HPPrinterInfo(); info.accepting = 1; info.pdf = 1; info.tray1 = 1; info.tray1_loaded = loaded; return info }
    func submit(_ file: URL, title: String, paper: String, tray: String, color: String, check: Bool) throws -> Int {
        if failSubmit { throw PrintError("Lost response") }
        let pdf = try loadPDF(file)
        submissions.append((tray, (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }))
        try onSubmit?()
        return 100 + submissions.count
    }
    func status(_ id: Int) throws -> (Int, String) { (states.count > 1 ? states.removeFirst() : states[0], "none") }
    func cancel(_ id: Int) throws { cancelled.append(id); if failCancel { throw PrintError("Cancel reply lost") } }
}

func runDriverTests() throws {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        count += 1; if !condition() { throw PrintError("Driver test failed: \(message)") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hp-driver-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs/1"), withIntermediateDirectories: true)
    let record = root.appendingPathComponent("Jobs/1/record.json")
    try Data("{\"state\":5}".utf8).write(to: record)
    do { try requireIdle(root); throw PrintError("Active job accepted") }
    catch { try check(error.localizedDescription.contains("Finish or cancel"), "installer refuses active jobs") }
    try Data("{\"state\":9}".utf8).write(to: record)
    try requireIdle(root)
    try Data("broken".utf8).write(to: record)
    do { try requireIdle(root); throw PrintError("Unreadable record accepted") }
    catch { try check(error.localizedDescription != "Unreadable record accepted", "installer refuses unreadable records") }
    try FileManager.default.removeItem(at: root.appendingPathComponent("Jobs"))
    let settings = root.appendingPathComponent("config.json")
    let uuid = "b143c9c9-7655-5bfd-bed0-cf7166adfbb1"
    let old = DriverConfig(uri: "ipp://old/ipp/print", uuid: uuid, port: 8631, spool: root.appendingPathComponent("Jobs").path)
    try JSONEncoder().encode(old).write(to: settings)
    var registry = try DriverRegistry.load(settings)
    try check(registry.printers.count == 1 && registry.printers[0].queue == "HP_M452nw_Open" && registry.printers[0].config.spool == old.spool, "migration preserves queue and recovery files")
    let first = DiscoveredPrinter(name: "Office", uri: "ipp://updated/ipp/print", hostname: "office-a.local.", uuid: "urn:uuid:" + uuid.uppercased())
    let updated = try registry.add(first, base: root)
    try check(registry.printers.count == 1 && updated.config.port == 8631 && updated.queue == "HP_M452nw_Open" && updated.config.uri == first.uri, "same UUID updates address without duplicating printer")
    let second = DiscoveredPrinter(name: "Office", uri: "ipp://second/ipp/print", hostname: "office-b.local.", uuid: "b143c9c9-7655-5bfd-bed0-cf7166adfbb2")
    var reusedAddress = DriverRegistry(printers: [updated])
    _ = try reusedAddress.add(DiscoveredPrinter(name: second.name, uri: first.uri, hostname: second.hostname, uuid: second.uuid), base: root)
    try check(reusedAddress.printers.count == 2, "different UUID at a reused address never replaces another printer")
    let added = try registry.add(second, base: root, portAvailable: { $0 != 8632 })
    try check(registry.printers.count == 2 && added.config.port == 8633 && added.queue != updated.queue && added.config.spool != updated.config.spool, "second printer has isolated queue, free port and job folder")
    _ = try registry.add(second, base: root)
    try check(registry.printers.count == 2 && registry.printers[1].queue == added.queue, "adding an installed printer is idempotent")
    try JSONEncoder().encode(registry).write(to: settings)
    let loaded = try DriverRegistry.load(settings)
    try check(loaded.printers.map { $0.id } == registry.printers.map { $0.id }, "all printers survive configuration reload")
    for kind in 0..<4 {
        var invalid = registry
        switch kind {
        case 0: invalid.printers[1].config.port = invalid.printers[0].config.port
        case 1: invalid.printers[1].config.spool = invalid.printers[0].config.spool
        case 2: invalid.printers[1].queue = invalid.printers[0].queue
        default: invalid.printers[1].id = invalid.printers[0].id
        }
        do { try invalid.validate(); throw PrintError("Shared printer state accepted") }
        catch { try check(error.localizedDescription != "Shared printer state accepted", "reject overlapping printer settings") }
    }
    let nested = root.appendingPathComponent("Jobs/other-printer/1")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("{\"state\":5}".utf8).write(to: nested.appendingPathComponent("record.json"))
    do { try requireIdle(root); throw PrintError("Nested active job accepted") }
    catch { try check(error.localizedDescription.contains("Finish or cancel"), "updates inspect every printer's jobs") }
    try FileManager.default.removeItem(at: root.appendingPathComponent("Jobs"))
    func fixture(_ name: String) throws -> (NativeDriver, FakePrinter, Job) {
        let printer = FakePrinter(), config = DriverConfig(uri: "ipp://localhost:9/ipp/print", uuid: UUID().uuidString, port: 18631, spool: root.appendingPathComponent(name).path)
        let driver = try NativeDriver(config, printer: printer, startWorker: false)
        let request = ippNewRequest(IPP_OP_PRINT_JOB)!; defer { ippDelete(request) }
        let attrs = IPP(pointer: request, group: IPP_TAG_JOB); attrs.text("sides", "two-sided-long-edge")
        let job = try Job(id: 1, request: attrs); driver.jobs[1] = job; driver.nextID = 2; try driver.save(job)
        let document = driver.root.appendingPathComponent("upload.pdf"); try makeTestPDF(document)
        try driver.receive(job, document: document)
        return (driver, printer, job)
    }
    let (driver, printer, job) = try fixture("duplex")
    try driver.process(job)
    try check(printer.submissions.map { $0.0 } == ["tray-2", "tray-1"], "fronts from Tray 2; backs from Tray 1")
    try check(printer.submissions[0].1[0].contains("Page 1"), "front order")
    try check(printer.submissions[1].1[0].contains("Page 4"), "back reverse order")
    try check(job.state == 9 && !FileManager.default.fileExists(atPath: driver.folder(job).appendingPathComponent("input.pdf").path), "completed PDF cleanup")
    for value: Int32 in [1, -1] {
        let (driver, printer, job) = try fixture("tray-\(value)"); printer.loaded = value
        try driver.process(job)
        try check(job.state == 6 && printer.submissions.isEmpty, "loaded or unknown Tray 1 blocks printing")
    }
    let (failed, failedPrinter, failedJob) = try fixture("failed")
    failedPrinter.states = [8]
    do { try failed.process(failedJob); throw PrintError("Failed front was accepted") }
    catch { try check(failedJob.state == 8 && failedPrinter.submissions.count == 1, "aborted front never prints backs") }
    let (uncertain, uncertainPrinter, uncertainJob) = try fixture("uncertain")
    uncertainPrinter.failSubmit = true
    do { try uncertain.process(uncertainJob); throw PrintError("Lost submission accepted") }
    catch { try check(uncertainJob.phase == "submitting-fronts", "submission intent saved before sending") }
    let restored = try NativeDriver(uncertain.config, printer: FakePrinter(), startWorker: false)
    try check(restored.jobs[1]?.state == 6 && restored.jobs[1]?.phase == "uncertain", "restart never replays an uncertain submission")
    let (resume, resumePrinter, resumeJob) = try fixture("resume")
    _ = try preparePDF(resume.folder(resumeJob).appendingPathComponent("input.pdf"), directory: resume.folder(resumeJob).appendingPathComponent("passes"), binding: .long, paper: .a4)
    resumeJob.physical_id = 42; try resume.update(resumeJob, state: 5, phase: "printing-fronts")
    let resumed = try NativeDriver(resume.config, printer: resumePrinter, startWorker: false)
    try resumed.process(resumed.jobs[1]!)
    try check(resumePrinter.submissions.map { $0.0 } == ["tray-1"], "restart monitors known front and sends only backs")
    let (cancelDriver, cancelPrinter, cancelJob) = try fixture("cancel-race")
    cancelPrinter.onSubmit = { try cancelDriver.cancel(cancelJob) }
    do { try cancelDriver.process(cancelJob); throw PrintError("Cancelled submission accepted") }
    catch { try check(cancelJob.state == 7 && cancelPrinter.cancelled == [101], "cancel during submission cancels returned physical job") }
    let (uncancel, uncancelPrinter, uncancelJob) = try fixture("cancel-lost")
    uncancelPrinter.failCancel = true; uncancelPrinter.states = [5]
    uncancelPrinter.onSubmit = { try uncancel.cancel(uncancelJob) }
    do { try uncancel.process(uncancelJob); throw PrintError("Unconfirmed cancellation accepted") }
    catch { try check(uncancelJob.state == 6 && uncancelJob.phase == "uncertain", "unconfirmed cancel during submission blocks later jobs") }
    let (single, singlePrinter, singleJob) = try fixture("single")
    singleJob.sides = "one-sided"; try single.save(singleJob); try single.process(singleJob)
    try check(singleJob.state == 9 && singlePrinter.submissions.count == 1, "simplex uses one pass")
    print("PASS: \(count) native lifecycle checks — printer registration, isolation, tray guards, recovery and cancellation")
}
