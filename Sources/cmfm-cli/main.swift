import CMFMCore
import Foundation

// Read-only diagnostic front end for the core engine.
let arguments = CommandLine.arguments.dropFirst()
let home = NSHomeDirectory()

func row(_ size: Int64, _ label: String) {
    let padded = Fmt.bytes(size).padding(toLength: 12, withPad: " ", startingAt: 0)
    print("  \(padded) \(label)")
}

switch arguments.first {
case "scan":
    let root = arguments.dropFirst().first ?? home
    let start = Date()
    guard let tree = DiskScanner.scan(root: root, progress: ScanProgress()) else {
        print("Lecture impossible : \(root)")
        exit(1)
    }
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
    print("\(root) : \(Fmt.bytes(tree.size)), \(tree.fileCount) fichiers, \(elapsed) s")
    for child in tree.children.prefix(20) { row(child.size, child.name) }
case "clean":
    var grandTotal: Int64 = 0
    for result in CleanupScanner.scan(home: home) {
        print("\(result.category.title) : \(Fmt.bytes(result.total))")
        for item in result.items.prefix(8) { row(item.size, item.label) }
        grandTotal += result.total
    }
    print("Total nettoyable : \(Fmt.bytes(grandTotal))")
case "apps":
    for app in AppInventory.list(home: home).prefix(25) { row(app.size, "\(app.name) (\(app.bundleID))") }
default:
    print("Usage : cmfm-cli scan [dossier] | clean | apps   (lecture seule)")
}
