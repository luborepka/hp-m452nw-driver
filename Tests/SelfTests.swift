import AppKit
import Foundation
import PDFKit

func runSelfTests() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw PrintError("Test failed: \(message)") }
    }
    for count in 1...100 {
        let plan = try PassPlan(pages: count)
        try check(plan.fronts.count == (count + 1) / 2, "sheet count \(count)")
        try check(plan.backs.count == plan.fronts.count, "equal passes \(count)")
        let stack = Array(plan.fronts.reversed())
        for (front, back) in zip(stack, plan.backs) {
            try check(back == (front + 1 < count ? front + 1 : nil), "matching physical sheet \(count), \(front)")
        }
        try check(Set(plan.fronts + plan.backs.compactMap { $0 }) == Set(0..<count), "all pages once \(count)")
    }
    for invalid in [0, -1, 101] {
        do { _ = try PassPlan(pages: invalid); throw PrintError("Invalid count was accepted: \(invalid)") }
        catch let error as PrintError { try check(!error.message.hasPrefix("Invalid count"), "reject invalid page count") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hp-open-print-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for count in [1, 2, 3, 4, 5] {
        let input = root.appendingPathComponent("input-\(count).pdf")
        try makeTestPDF(input, pages: count)
        let before = try Data(contentsOf: input)
        for binding in [Binding.long, .short] {
            let directory = root.appendingPathComponent("passes-\(count)-\(binding.rawValue)")
            let prepared = try preparePDF(input, directory: directory, binding: binding, paper: .a4)
            let fronts = try loadPDF(prepared.fronts), backs = try loadPDF(prepared.backs)
            let plan = try PassPlan(pages: count)
            try check(fronts.pageCount == plan.fronts.count && backs.pageCount == plan.backs.count, "written page counts")
            for (position, index) in plan.fronts.enumerated() {
                try check(fronts.page(at: position)?.string?.contains("Page \(index + 1) of \(count)") == true, "front text and order: expected Page \(index + 1) of \(count); source=\(PDFDocument(data: before)?.page(at: index)?.string ?? "<no text>"); prepared=\(fronts.page(at: position)?.string ?? "<no text>")")
            }
            for (position, index) in plan.backs.enumerated() {
                let page = backs.page(at: position)!
                if let index {
                    try check(page.string?.contains("Page \(index + 1) of \(count)") == true, "back text and reverse order")
                    try check(page.rotation == (binding == .short ? 180 : 0), "binding rotation")
                } else {
                    try check((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "blank back for odd last page")
                }
            }
            do {
                _ = try preparePDF(input, directory: directory, binding: binding, paper: .a4)
                throw PrintError("Existing passes overwritten")
            } catch let error as PrintError { try check(error.message != "Existing passes overwritten", "protect prepared files") }
        }
        let after = try Data(contentsOf: input)
        try check(before == after, "source PDF unchanged")
    }
    // Changing the binding must preserve source /Rotate and crop geometry.
    let rotatedInput = root.appendingPathComponent("rotated.pdf")
    let rotated = PDFDocument()
    let original = try loadPDF(root.appendingPathComponent("input-2.pdf"))
    for i in 0..<2 { let page = original.page(at: i)!.copy() as! PDFPage; page.rotation = 90; rotated.insert(page, at: i) }
    try check(rotated.write(to: rotatedInput), "write rotated input")
    for binding in [Binding.long, .short] {
        let prepared = try preparePDF(rotatedInput, directory: root.appendingPathComponent("rotated-\(binding.rawValue)"), binding: binding, paper: .letter)
        let fronts = try loadPDF(prepared.fronts), backs = try loadPDF(prepared.backs)
        let bounds = fronts.page(at: 0)!.bounds(for: .mediaBox)
        try check(bounds.width > bounds.height && abs(bounds.width - 792) < 1, "landscape letter size")
        try check(backs.page(at: 0)!.rotation == (binding == .long ? 180 : 0), "landscape binding rotation")
    }
    let copies = try preparePDF(root.appendingPathComponent("input-3.pdf"), directory: root.appendingPathComponent("copies"), binding: .long, paper: .a4, copies: 2)
    let copyFronts = try loadPDF(copies.fronts), copyBacks = try loadPDF(copies.backs)
    try check(copies.sheets == 4 && copyFronts.pageCount == 4 && copyBacks.pageCount == 4, "two copies of odd-length document")
    for position in [0, 2] {
        try check((copyBacks.page(at: position)?.string ?? "").isEmpty, "each odd copy has its own blank back")
    }
    let mixed = PDFDocument(url: rotatedInput)!
    mixed.page(at: 1)!.rotation = 0
    let mixedInput = root.appendingPathComponent("mixed.pdf")
    try check(mixed.write(to: mixedInput), "write mixed input")
    do {
        _ = try preparePDF(mixedInput, directory: root.appendingPathComponent("mixed"), binding: .long, paper: .a4)
        throw PrintError("Mixed orientation accepted")
    } catch let error as PrintError { try check(error.message.contains("mixes portrait"), "reject ambiguous binding") }
    print("PASS: \(checks) checks — sheet pairing, real PDFs, blank backs, binding rotations, source preservation and collated copies")
}


func makeTestPDF(_ url: URL, pages: Int = 4) throws {
    let pdf = PDFDocument()
    for index in 1...pages {
        let page = NSView(frame: Paper.a4.rect)
        let title = NSTextField(labelWithString: "HP OPEN PRINT\nPage \(index) of \(pages)\n\(index % 2 == 1 ? "FRONT" : "BACK")")
        // Named PDF fonts keep calibration text portable across macOS versions.
        title.font = NSFont(name: "Helvetica-Bold", size: 38)!
        title.frame = CGRect(x: 48, y: 380, width: 490, height: 220)
        page.addSubview(title)
        let top = NSTextField(labelWithString: "↑ TOP EDGE — keep both sides upright ↑")
        top.font = NSFont(name: "Helvetica", size: 13)!
        top.frame = CGRect(x: 48, y: 745, width: 500, height: 30); page.addSubview(top)
        for (i, color) in [NSColor.cyan, .magenta, .yellow, .black].enumerated() {
            let swatch = NSBox(frame: CGRect(x: 48 + i * 110, y: 240, width: 90, height: 60))
            swatch.boxType = .custom; swatch.borderWidth = 0; swatch.fillColor = color
            page.addSubview(swatch)
        }
        let footer = NSTextField(wrappingLabelWithString: "A successful two-sided test pairs pages 1/2 and 3/4 on two sheets. Read both sides like a book. Check that the four color blocks print and the text is sharp.")
        footer.frame = CGRect(x: 48, y: 100, width: 480, height: 90); footer.font = NSFont(name: "Helvetica", size: 16)!; page.addSubview(footer)
        guard let generated = PDFDocument(data: page.dataWithPDF(inside: page.bounds))?.page(at: 0) else { throw PrintError("Cannot generate test document.") }
        pdf.insert(generated, at: pdf.pageCount)
    }
    guard pdf.write(to: url) else { throw PrintError("Cannot save test document.") }
}
