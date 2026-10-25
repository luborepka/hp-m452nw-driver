import Foundation
import PDFKit
import AppKit

struct PrintError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func cString<T>(_ value: T) -> String {
    var value = value
    return withUnsafePointer(to: &value) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}

protocol PrinterTransport {
    func probe() throws -> HPPrinterInfo
    func submit(_ file: URL, title: String, paper: String, tray: String, color: String, check: Bool) throws -> Int
    func status(_ id: Int) throws -> (Int, String)
    func cancel(_ id: Int) throws
}
struct Printer: PrinterTransport {
    let uri: String
    func probe() throws -> HPPrinterInfo {
        var info = HPPrinterInfo()
        var error = [CChar](repeating: 0, count: 1024)
        guard hp_probe(uri, &info, &error, error.count) != 0 else { throw PrintError(String(cString: error)) }
        guard info.pdf != 0 else { throw PrintError("This printer does not accept PDF documents.") }
        return info
    }
    func submit(_ file: URL, title: String, paper: String, tray: String, color: String, check: Bool = true) throws -> Int {
        guard ["iso_a4_210x297mm", "na_letter_8.5x11in"].contains(paper),
              ["auto", "tray-1", "tray-2"].contains(tray), ["color", "monochrome"].contains(color)
        else { throw PrintError("Unsupported paper, tray or color choice.") }
        if check {
            let info = try probe()
            guard info.accepting != 0 else { throw PrintError("The printer is not accepting jobs: \(cString(info.reasons))") }
            if tray == "tray-1", info.tray1 == 0 { throw PrintError("The printer does not advertise Tray 1.") }
        }
        var error = [CChar](repeating: 0, count: 1024)
        let id = hp_submit(uri, file.path, title, paper, tray, color, &error, error.count)
        guard id > 0 else { throw PrintError("\(String(cString: error))\nThe submission may have reached the printer. Check its job list before printing again.") }
        return Int(id)
    }
    func status(_ id: Int) throws -> (Int, String) {
        var reason = [CChar](repeating: 0, count: 1024)
        let state = hp_job_state(uri, Int32(id), &reason, reason.count)
        guard state >= 3 else { throw PrintError("Cannot read job \(id): \(String(cString: reason))") }
        return (Int(state), String(cString: reason))
    }
    func cancel(_ id: Int) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard hp_cancel(uri, Int32(id), &error, error.count) != 0 else { throw PrintError(String(cString: error)) }
    }
}

enum Binding: String, Codable { case long, short }
enum Paper: String, Codable {
    case a4, letter
    var ipp: String { self == .a4 ? "iso_a4_210x297mm" : "na_letter_8.5x11in" }
    var rect: CGRect { CGRect(x: 0, y: 0, width: self == .a4 ? 595.276 : 612, height: self == .a4 ? 841.89 : 792) }
}

struct PassPlan {
    let fronts: [Int]
    let backs: [Int?]
    init(pages: Int) throws {
        guard pages > 0 else { throw PrintError("The PDF has no pages.") }
        guard pages <= 100 else { throw PrintError("Manual duplex supports up to 100 pages (50 sheets, Tray 1 capacity). Split this PDF into smaller jobs.") }
        fronts = Array(stride(from: 0, to: pages, by: 2))
        backs = fronts.reversed().map { $0 + 1 < pages ? $0 + 1 : nil }
    }
}

struct PreparedPDF {
    let fronts: URL
    let backs: URL
    let pages: Int
    let sheets: Int
}

func loadPDF(_ url: URL) throws -> PDFDocument {
    guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
        throw PrintError("Open an unlocked PDF with at least one page. Use File → Print → PDF in the original application to create one.")
    }
    return pdf
}

// Render every page onto the chosen physical sheet. Landscape documents remain
// landscape; PDF rotation and crop boxes are applied once by PDFKit.
func normalizedPage(_ page: PDFPage, paper: Paper) throws -> PDFDocument {
    let bounds = page.bounds(for: .cropBox)
    let rotated = (abs(page.rotation) % 180) != 0
    let landscape = rotated ? bounds.height > bounds.width : bounds.width > bounds.height
    var rect = paper.rect
    if landscape { rect = CGRect(x: 0, y: 0, width: rect.height, height: rect.width) }
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &rect, nil)
    else { throw PrintError("Cannot create PDF page.") }
    context.beginPDFPage(nil)
    // PDFPage.draw handles /Rotate but drawing into a transformed context also
    // needs the displayed size for fitting.
    let displayWidth = rotated ? bounds.height : bounds.width
    let displayHeight = rotated ? bounds.width : bounds.height
    let scale = min((rect.width - 24) / displayWidth, (rect.height - 24) / displayHeight)
    context.translateBy(x: (rect.width - displayWidth * scale) / 2, y: (rect.height - displayHeight * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    // CGPDFPage's drawing transform handles nonzero origins and /Rotate.
    guard let ref = page.pageRef else { throw PrintError("Cannot read the source PDF page content.") }
    do {
        let target = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        context.concatenate(ref.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(ref)
    }
    context.endPDFPage()
    context.closePDF()
    guard let result = PDFDocument(data: data as Data), result.pageCount == 1 else { throw PrintError("Cannot render PDF page.") }
    return result
}

func blankPage(like page: PDFPage) throws -> PDFDocument {
    var rect = page.bounds(for: .mediaBox)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &rect, nil)
    else { throw PrintError("Cannot create blank reverse side.") }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
    context.endPDFPage(); context.closePDF()
    guard let result = PDFDocument(data: data as Data), result.pageCount == 1 else { throw PrintError("Cannot read blank reverse side.") }
    return result
}

func preparePDF(_ source: URL, directory: URL, binding: Binding, paper: Paper, copies: Int = 1) throws -> PreparedPDF {
    let input = try loadPDF(source)
    let plan = try PassPlan(pages: input.pageCount)
    guard copies > 0, copies <= 50, plan.fronts.count * copies <= 50 else { throw PrintError("The complete two-sided job must fit in Tray 1 (50 sheets). Reduce the copy count or split the document.") }
    func isLandscape(_ page: PDFPage) -> Bool {
        let box = page.bounds(for: .cropBox)
        return abs(page.rotation) % 180 != 0 ? box.height > box.width : box.width > box.height
    }
    let orientation = isLandscape(input.page(at: 0)!)
    guard (0..<input.pageCount).allSatisfy({ isLandscape(input.page(at: $0)!) == orientation }) else {
        throw PrintError("This PDF mixes portrait and landscape pages. Fit them to one orientation in the original application's Print dialog or split the job by orientation.")
    }
    let frontPDF = PDFDocument(), backPDF = PDFDocument()
    // PDFPage references its source document. Keep those documents alive until
    // the assembled passes are serialized, including when copying cached pages.
    let normalized = try (0..<input.pageCount).map { try normalizedPage(input.page(at: $0)!, paper: paper) }
    let pages = normalized.map { $0.page(at: 0)! }
    let blank = try input.pageCount % 2 == 1 ? blankPage(like: pages[0]) : nil
    for _ in 0..<copies {
      for index in plan.fronts {
          frontPDF.insert(pages[index].copy() as! PDFPage, at: frontPDF.pageCount)
      }
    }
    for _ in 0..<copies {
      for index in plan.backs {
        if let index {
            let page = input.page(at: index)!
            let bounds = page.bounds(for: .cropBox)
            let rotated = (abs(page.rotation) % 180) != 0
            let landscape = rotated ? bounds.height > bounds.width : bounds.width > bounds.height
            let rotate = (binding == .short) != landscape
            let back = pages[index].copy() as! PDFPage
            if rotate { back.rotation = 180 }
            backPDF.insert(back, at: backPDF.pageCount)
        } else {
            backPDF.insert(blank!.page(at: 0)!.copy() as! PDFPage, at: backPDF.pageCount)
        }
      }
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fronts = directory.appendingPathComponent("fronts.pdf"), backs = directory.appendingPathComponent("backs.pdf")
    guard !FileManager.default.fileExists(atPath: fronts.path), !FileManager.default.fileExists(atPath: backs.path)
    else { throw PrintError("The output directory already contains prepared passes. Choose an empty directory.") }
    try withExtendedLifetime((input, normalized, blank)) {
        guard frontPDF.write(to: fronts), backPDF.write(to: backs) else { throw PrintError("Cannot write prepared PDF files.") }
    }
    for file in [fronts, backs] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    return PreparedPDF(fronts: fronts, backs: backs, pages: input.pageCount, sheets: plan.fronts.count * copies)
}

func repeatPDF(_ source: URL, to destination: URL, copies: Int) throws {
    let input = try loadPDF(source), output = PDFDocument()
    for _ in 0..<copies { for i in 0..<input.pageCount { output.insert(input.page(at: i)!.copy() as! PDFPage, at: output.pageCount) } }
    try withExtendedLifetime(input) {
        guard output.write(to: destination) else { throw PrintError("Cannot save collated document.") }
    }
}
