import AppKit
import PDFKit

func runDiagnostics() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String, default fallback: String? = nil) throws -> String {
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        if let fallback { return fallback }
        throw PrintError("Missing \(name). Run --help for usage.")
    }
    func url(_ value: String) -> URL { URL(fileURLWithPath: value) }
    func endpoint() throws -> String { try option("--uri", default: PrinterDiscovery().discover().first!.uri) }
    switch args.first {
    case "--discover":
        let data = try JSONEncoder().encode(PrinterDiscovery().discover())
        print(String(data: data, encoding: .utf8)!)
    case "--probe":
        let uri: String
        if args.contains("--uri") { uri = try option("--uri") } else { uri = try endpoint() }
        let info = try Printer(uri: uri).probe()
        if args.contains("--json") {
            let object: [String: Any] = ["model": cString(info.model), "uri": uri, "state": Int(info.state), "accepting": info.accepting != 0, "pdf": info.pdf != 0, "tray1": info.tray1 != 0, "tray1_loaded": Int(info.tray1_loaded), "reasons": cString(info.reasons)]
            print(String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
        } else {
            print("Model: \(cString(info.model))\nURI: \(uri)\nState: \(info.state)\nAccepting jobs: \(info.accepting != 0)\nPDF: \(info.pdf != 0)\nTray 1: \(info.tray1 != 0)\nTray 1 loaded: \(info.tray1_loaded)\nReasons: \(cString(info.reasons))")
        }
    case "--make-test":
        let file = url(try option("--output")); try makeTestPDF(file); print(file.path)
    case "--inspect":
        let pdf = try loadPDF(url(option("--input")))
        let pages: [[String: Any]] = (0..<pdf.pageCount).map { ["text": pdf.page(at: $0)?.string ?? "", "rotation": pdf.page(at: $0)!.rotation] }
        print(String(data: try JSONSerialization.data(withJSONObject: pages), encoding: .utf8)!)
    case "--prepare":
        guard let binding = Binding(rawValue: try option("--binding", default: "long")),
              let paper = Paper(rawValue: try option("--paper", default: "a4")) else { throw PrintError("Use --binding long|short and --paper a4|letter.") }
        guard let copies = Int(try option("--copies", default: "1")) else { throw PrintError("Invalid copies.") }
        let result = try preparePDF(url(option("--input")), directory: url(option("--output")), binding: binding, paper: paper, copies: copies)
        if args.contains("--json") {
            let object: [String: Any] = ["pages": result.pages, "sheets": result.sheets, "fronts": result.fronts.path, "backs": result.backs.path]
            print(String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
        } else { print("\(result.pages) pages / \(result.sheets) sheets\nFronts: \(result.fronts.path)\nBacks: \(result.backs.path)") }
    case "--submit":
        let input = url(try option("--input"))
        _ = try loadPDF(input)
        let uri = try option("--uri")
        guard let paper = Paper(rawValue: try option("--paper", default: "a4")) else { throw PrintError("Use --paper a4|letter.") }
        let id = try Printer(uri: uri).submit(input, title: option("--title", default: input.lastPathComponent), paper: paper.ipp, tray: option("--tray", default: "auto"), color: option("--color", default: "color"))
        print("Job ID: \(id)")
    case "--status", "--cancel":
        guard let id = Int(try option("--job")), id > 0, id <= Int(Int32.max) else { throw PrintError("Use a positive --job ID.") }
        let printer = Printer(uri: try option("--uri"))
        if args.first == "--cancel" { try printer.cancel(id); print("Cancelled job \(id)") }
        else {
            let (state, reasons) = try printer.status(id)
            if args.contains("--json") { print(String(data: try JSONSerialization.data(withJSONObject: ["state": state, "reasons": reasons]), encoding: .utf8)!) }
            else { print("Job \(id): state=\(state) reasons=\(reasons)") }
        }
    case "--self-test": try runSelfTests(); try runDriverTests()
    default:
        print("""
        HP Open Print — HP Color LaserJet M452nw
        Native printing: select HP M452nw (Open Print) in any application's Print dialog.
        Diagnostic tools:
          --discover
          --probe [--uri ipp://printer/ipp/print]
          --make-test --output test.pdf
          --prepare --input document.pdf --output empty-directory [--binding long|short] [--paper a4|letter]
          --submit --uri URI --input pass.pdf [--tray auto|tray-1|tray-2] [--paper a4|letter] [--color color|monochrome]
          --status --uri URI --job ID
          --cancel --uri URI --job ID
          --self-test
        Job states: 3 pending, 4 held, 5 processing, 6 stopped, 7 cancelled, 8 aborted, 9 completed.
        The submit command prints exactly one pass. Prepare and inspect both PDF passes before manual duplex printing.
        """)
    }
}
