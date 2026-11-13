@testable import CMFMCore
import XCTest

final class CoreTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmfm-tests-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        // Resolve /var -> /private/var so paths match what the scanner reports.
        sandbox = sandbox.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func write(_ relative: String, bytes: Int, fill: UInt8 = 7) throws {
        let url = sandbox.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    // MARK: Scanner

    func testScanSumsSizesAndFoldsSmallEntries() throws {
        try write("a/b/c/big.bin", bytes: 3 << 20)
        try write("a/b/c/tiny.txt", bytes: 100)
        try write("a/b/small-dir/tiny.txt", bytes: 100)
        try write("top.bin", bytes: 2 << 20)

        let tree = try XCTUnwrap(DiskScanner.scan(root: sandbox.path, progress: ScanProgress()))
        XCTAssertEqual(tree.fileCount, 4)
        XCTAssertGreaterThanOrEqual(tree.size, 5 << 20)
        XCTAssertEqual(tree.size, DiskScanner.sizeOf(sandbox.path) - DiskScanner.lstatInfo(sandbox.path)!.size,
                       accuracy: 64 * 1024)

        let files = tree.files(minSize: 1 << 20).map(\.name)
        XCTAssertEqual(files, ["big.bin", "top.bin"])

        let c = try XCTUnwrap(tree.children.first { $0.name == "a" }?.children.first?.children.first { $0.name == "c" })
        XCTAssertTrue(c.children.contains { $0.isAggregate }, "tiny.txt folds into the aggregate")
        let b = try XCTUnwrap(c.parent)
        XCTAssertFalse(b.children.contains { $0.name == "small-dir" }, "sub-megabyte directories are not kept as nodes")
        XCTAssertEqual(tree.children.reduce(0) { $0 + $1.size }, tree.size)
    }

    func testUnreadableDirectoryDoesNotLoseSiblingSizes() throws {
        try write("x/y/a-locked/secret.bin", bytes: 2 << 20)
        try write("x/y/z-after/big.bin", bytes: 4 << 20)
        try write("x/y/z-last.bin", bytes: 3 << 20)
        let locked = sandbox.appendingPathComponent("x/y/a-locked").path
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }

        let tree = try XCTUnwrap(DiskScanner.scan(root: sandbox.path, progress: ScanProgress()))
        XCTAssertGreaterThanOrEqual(tree.size, 7 << 20)
        XCTAssertEqual(Set(tree.files(minSize: 1 << 20).map(\.name)), ["big.bin", "z-last.bin"])
        XCTAssertEqual(tree.children.reduce(0) { $0 + $1.size }, tree.size)
    }

    func testCancelledScanReturnsNil() throws {
        try write("a/b/c/big.bin", bytes: 1 << 20)
        let progress = ScanProgress()
        progress.cancel()
        XCTAssertNil(DiskScanner.scan(root: sandbox.path, progress: progress))
    }

    func testDetachUpdatesAncestors() throws {
        try write("a/b/c/big.bin", bytes: 3 << 20)
        try write("a/b/c/other.bin", bytes: 2 << 20)
        let tree = try XCTUnwrap(DiskScanner.scan(root: sandbox.path, progress: ScanProgress()))
        let before = tree.size
        let big = try XCTUnwrap(tree.files(minSize: 3 << 20).first)
        big.detach()
        XCTAssertEqual(tree.size, before - big.size)
        XCTAssertEqual(tree.files(minSize: 1 << 20).map(\.name), ["other.bin"])
    }

    // MARK: Treemap

    func testTreemapFillsRectWithProportionalAreas() {
        let values: [Double] = [50, 25, 12, 8, 5]
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rects = Treemap.layout(values: values, in: bounds)
        let total = values.reduce(0, +)
        for (value, rect) in zip(values, rects) {
            XCTAssertTrue(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
            XCTAssertEqual(Double(rect.width * rect.height), value / total * 120_000, accuracy: 0.5)
        }
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                let overlap = a.intersection(b)
                XCTAssertLessThan(overlap.isNull ? 0 : overlap.width * overlap.height, 0.01)
            }
        }
    }

    func testTreemapHandlesEmptyInput() {
        XCTAssertEqual(Treemap.layout(values: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)), [])
        XCTAssertEqual(Treemap.layout(values: [0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10)), [.zero, .zero])
    }

    // MARK: SafeRemover

    func testRemoverRefusesDangerousPaths() {
        let remover = SafeRemover(home: "/Users/someone")
        let refused = [
            "/", "/Users/someone", "/Users/someone/Documents", "/Users/someone/Library/Caches",
            "/Users/someone/Library", "/Users/someone/.ssh/id_rsa", "/Users/someone/Library/Keychains/login.keychain-db",
            "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/file", "/Users/other/Documents/file",
            "/System/Library/thing", "/Applications", "/Applications/Foo.app/Contents", "/Applications/notanapp",
            "/Users/someone/Documents/../../other/Documents/file", "/Users/someone/Library/Caches/..", "relative/path",
        ]
        for path in refused {
            XCTAssertThrowsError(try remover.validate(path), path)
        }
    }

    func testRemoverAcceptsLeaves() {
        let remover = SafeRemover(home: "/Users/someone")
        let accepted = [
            "/Users/someone/Library/Caches/com.foo.bar", "/Users/someone/.cache/uv", "/Users/someone/.Trash/old.zip",
            "/Users/someone/Downloads/big.dmg", "/Users/someone/Library/Preferences/com.foo.bar.plist",
            "/Applications/Foo.app",
        ]
        for path in accepted {
            XCTAssertNoThrow(try remover.validate(path), path)
        }
    }

    func testRemoverDeletesOnlyTheValidatedItem() throws {
        try write("Library/Caches/com.foo/data.bin", bytes: 10)
        try write("Library/Caches/com.keep/data.bin", bytes: 10)
        let remover = SafeRemover(home: sandbox.path)
        try remover.remove(sandbox.path + "/Library/Caches/com.foo", permanent: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path + "/Library/Caches/com.foo"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path + "/Library/Caches/com.keep/data.bin"))
        XCTAssertThrowsError(try remover.remove(sandbox.path + "/Library/Caches", permanent: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path + "/Library/Caches"))
    }

    // MARK: Cleanup catalog

    func testCompactBytesStaysShort() {
        XCTAssertEqual(Fmt.compactBytes(0), "0K")
        XCTAssertEqual(Fmt.compactBytes(840_000), "840K")
        XCTAssertEqual(Fmt.compactBytes(62_300_000_000), "62G")
        XCTAssertEqual(Fmt.compactBytes(999_900_000), "1" + (Locale.current.decimalSeparator ?? ".") + "0G")
    }

    func testSmartCleanNeverTouchesTrashOrOptInCategories() {
        let smart = Set(CleanupCatalog.categories.filter(\.isSmartCleanable).map(\.id))
        XCTAssertEqual(smart, ["app-caches", "dev-caches", "browser-caches", "logs"])
    }

    func testCleanupScanFindsCandidatesAndSkipsOwnLogs() throws {
        try write("Library/Caches/com.foo/data.bin", bytes: 200_000)
        try write("Library/Logs/SomeApp/a.log", bytes: 50_000)
        try write("Library/Logs/CleanMyFuckingMac/app.log", bytes: 50_000)
        try write(".cache/uv/archive/x.whl", bytes: 300_000)
        try write("Library/Application Support/Google/Chrome/Default/Code Cache/js/x", bytes: 80_000)
        try write("Library/Application Support/Google/Chrome/Default/Login Data", bytes: 80_000)

        let results = CleanupScanner.scan(home: sandbox.path)
        func labels(_ id: String) -> [String] { results.first { $0.id == id }!.items.map(\.label) }
        XCTAssertEqual(labels("app-caches"), ["com.foo"])
        XCTAssertEqual(labels("logs"), ["SomeApp"])
        XCTAssertEqual(labels("dev-caches"), ["uv (Python)"])
        XCTAssertEqual(labels("browser-caches"), ["Chrome · Default · Code Cache"])
        XCTAssertEqual(labels("trash"), [])

        let remover = SafeRemover(home: sandbox.path)
        for item in results.flatMap(\.items) {
            XCTAssertNoThrow(try remover.validate(item.path), item.path)
        }
    }

    // MARK: Duplicates

    func testDuplicateFinderGroupsIdenticalContentOnly() throws {
        try write("one.bin", bytes: 200_000, fill: 1)
        try write("sub/two.bin", bytes: 200_000, fill: 1)
        try write("same-size-different.bin", bytes: 200_000, fill: 2)
        try write("unique.bin", bytes: 123_456, fill: 1)
        // Same first 64 KB, different tail.
        var tail = Data(repeating: 1, count: 200_000)
        tail[199_999] = 9
        try tail.write(to: sandbox.appendingPathComponent("tail-differs.bin"))

        let tree = try XCTUnwrap(DiskScanner.scan(root: sandbox.path, progress: ScanProgress(), minNodeSize: 1))
        let groups = DuplicateFinder.find(candidates: tree.files(minSize: 1))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.map(\.name).sorted(), ["one.bin", "two.bin"])
        XCTAssertEqual(groups[0].wasted, groups[0].size)
    }

    // MARK: App leftovers

    func testLeftoverMatchingIsStrict() {
        func match(_ entry: String, name: Bool = true) -> Bool {
            AppInventory.matches(entry: entry, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", allowName: name)
        }
        XCTAssertTrue(match("com.tinyspeck.slackmacgap"))
        XCTAssertTrue(match("com.tinyspeck.slackmacgap.plist"))
        XCTAssertTrue(match("com.tinyspeck.slackmacgap.savedState"))
        XCTAssertTrue(match("com.tinyspeck.slackmacgap.helper"))
        XCTAssertTrue(match("BQR82RBBHL.com.tinyspeck.slackmacgap"))
        XCTAssertTrue(match("Slack"))
        XCTAssertFalse(match("Slack", name: false))
        XCTAssertFalse(match("com.tinyspeck.slackmacgap2"))
        XCTAssertFalse(match("com.tinyspeck"))
        XCTAssertFalse(match("SlackHelper"))
        // Generic two-part ids never prefix-match.
        XCTAssertFalse(AppInventory.matches(entry: "com.google.Chrome", bundleID: "com.google", appName: "G", allowName: true))
    }

    // MARK: Misc

    func testUserContentFilter() {
        let home = "/Users/someone"
        XCTAssertTrue(PathFilter.isUserContent("/Users/someone/Downloads/film.mkv", home: home))
        XCTAssertTrue(PathFilter.isUserContent("/Users/someone/Documents/Thing.app", home: home))
        XCTAssertFalse(PathFilter.isUserContent("/Users/someone/Library/Caches/x", home: home))
        XCTAssertFalse(PathFilter.isUserContent("/Users/someone/.cache/uv/x", home: home))
        XCTAssertFalse(PathFilter.isUserContent("/Users/someone/dev/app/node_modules/x.node", home: home))
        XCTAssertFalse(PathFilter.isUserContent("/Users/someone/Apps/Thing.app/Contents/x", home: home))
        XCTAssertFalse(PathFilter.isUserContent("/Applications/x", home: home))
    }

    func testProcessLineParsing() throws {
        let entry = try XCTUnwrap(SystemInfo.parseProcessLine("  412  204800   3,5 /Applications/Some App.app/Contents/MacOS/Some App"))
        XCTAssertEqual(entry.pid, 412)
        XCTAssertEqual(entry.memory, 204_800 * 1024)
        XCTAssertEqual(entry.cpu, 3.5)
        XCTAssertEqual(entry.name, "Some App")
        XCTAssertEqual(entry.app, "Some App")
        let helper = try XCTUnwrap(SystemInfo.parseProcessLine(
            "9 1024 0.0 /Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"))
        XCTAssertEqual(helper.app, "Google Chrome")
        XCTAssertEqual(SystemInfo.parseProcessLine("7 10 1.0 /usr/sbin/mds_stores")?.app, "mds_stores")
        XCTAssertNil(SystemInfo.parseProcessLine("garbage"))
    }

    func testCPUUsageFromTickDeltas() {
        let before = CPUTicks(busy: 100, total: 1000)
        XCTAssertEqual(CPUTicks(busy: 150, total: 1200).usage(since: before), 0.25)
        XCTAssertEqual(before.usage(since: before), 0)
        XCTAssertGreaterThan(SystemInfo.cpuTicks().total, 0)
    }

    private func inputs(freeGB: Int64 = 200, usedMemoryGB: Int64 = 8, battery: BatteryHealth? = nil,
                        smart: Bool? = true, uptimeDays: Double = 1) -> HealthInputs {
        HealthInputs(disk: DiskUsage(total: 500 << 30, free: freeGB << 30),
                     memory: MemoryUsage(total: 16 << 30, used: usedMemoryGB << 30), swapUsed: 0, battery: battery,
                     smartVerified: smart, uptime: uptimeDays * 86_400, loadAverage: 2, cores: 10, thermalPressure: .nominal)
    }

    func testHealthyMacScoresFull() {
        let report = HealthReport(inputs: inputs(battery: BatteryHealth(cycleCount: 120, capacityPercent: 97, temperatureCelsius: 30)))
        XCTAssertEqual(report.score, 100)
        XCTAssertEqual(report.worst, .good)
        XCTAssertTrue(report.kpis.contains { $0.id == "battery-cycles" })
    }

    func testHealthPenalties() {
        let full = HealthReport(inputs: inputs(freeGB: 20))
        XCTAssertEqual(full.kpis.first { $0.id == "disk" }?.status, .critical)
        XCTAssertEqual(full.score, 70)
        XCTAssertFalse(full.kpis.contains { $0.id.hasPrefix("battery") }, "no battery KPIs on a desktop")

        let worn = HealthReport(inputs: inputs(usedMemoryGB: 15, battery: BatteryHealth(cycleCount: 1200, capacityPercent: 76, temperatureCelsius: nil), uptimeDays: 30))
        XCTAssertEqual(worn.score, 100 - 20 - 8 - 12 - 4)
        XCTAssertEqual(worn.worst, .critical)

        let failing = HealthReport(inputs: inputs(smart: false))
        XCTAssertEqual(failing.score, 60)
        XCTAssertFalse(HealthReport(inputs: inputs(smart: nil)).kpis.contains { $0.id == "smart" })
    }

    func testLogWritesRotatesAndClears() throws {
        let log = AppLog(directory: sandbox.appendingPathComponent("logs"), maxFileSize: 200, maxEntries: 3)
        for index in 0..<10 { log.log(.info, "test", "message number \(index) with some padding text") }
        log.flush()
        XCTAssertEqual(log.snapshot().map(\.message.first), ["m", "m", "m"])
        XCTAssertEqual(log.snapshot().count, 3)
        XCTAssertTrue(log.snapshot().last!.message.contains("number 9"))
        let rotated = sandbox.appendingPathComponent("logs/app.1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        XCTAssertTrue(try String(contentsOf: log.fileURL).contains("[INFO] [test] message number 9"))
        log.clear()
        XCTAssertTrue(log.snapshot().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.fileURL.path))
    }
}
