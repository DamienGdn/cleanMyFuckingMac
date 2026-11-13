import Foundation

public struct InstalledApp: Identifiable, Sendable {
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String
    public let size: Int64
    public let lastUsed: Date?
    public var id: String { path }
}

public enum AppInventory {
    /// ~/Library subfolders where apps leave data behind.
    static let leftoverDirectories = [
        "Application Support", "Caches", "Preferences", "Logs", "Containers", "Group Containers",
        "Saved Application State", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents", "Application Scripts",
    ]
    /// Folders where an entry named after the app (not its bundle id) is common.
    private static let nameMatchedDirectories: Set<String> = ["Application Support", "Caches", "Logs"]
    private static let strippedExtensions = [".plist", ".savedstate", ".binarycookies"]

    /// Third-party apps of /Applications and ~/Applications, largest first. Apple's own apps are left out.
    public static func list(home: String) -> [InstalledApp] {
        let fm = FileManager.default
        var paths: [String] = []
        for directory in ["/Applications", home + "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".app") {
                paths.append(directory + "/" + name)
            }
        }
        var apps = [InstalledApp?](repeating: nil, count: paths.count)
        apps.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: paths.count) { index in
                base[index] = describe(paths[index])
            }
        }
        return apps.compactMap { $0 }.sorted { $0.size > $1.size }
    }

    private static func describe(_ path: String) -> InstalledApp? {
        let plistURL = URL(fileURLWithPath: path + "/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.hasPrefix("com.apple.") else { return nil }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let lastUsed = NSMetadataItem(url: URL(fileURLWithPath: path))?
            .value(forAttribute: kMDItemLastUsedDate as String) as? Date
        return InstalledApp(path: path,
                            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName,
                            bundleID: bundleID,
                            version: (info["CFBundleShortVersionString"] as? String) ?? "",
                            size: DiskScanner.sizeOf(path),
                            lastUsed: lastUsed)
    }

    /// Data the app left in ~/Library, with sizes, largest first.
    public static func leftovers(for app: InstalledApp, home: String) -> [CleanItem] {
        let fm = FileManager.default
        var found: [CleanItem] = []
        for directory in leftoverDirectories {
            let base = home + "/Library/" + directory
            for entry in (try? fm.contentsOfDirectory(atPath: base)) ?? []
            where matches(entry: entry, bundleID: app.bundleID, appName: app.name,
                          allowName: nameMatchedDirectories.contains(directory)) {
                let path = base + "/" + entry
                found.append(CleanItem(path: path, label: directory + "/" + entry, size: DiskScanner.sizeOf(path)))
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    /// Whether a ~/Library entry belongs to the app. Deliberately strict: a false positive deletes someone else's data.
    static func matches(entry: String, bundleID: String, appName: String, allowName: Bool) -> Bool {
        var base = entry.lowercased()
        for suffix in strippedExtensions where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        let id = bundleID.lowercased()
        // A bundle id with fewer than three parts ("com.foo") is too generic to prefix-match.
        let specific = id.split(separator: ".").count >= 3
        if base == id { return true }
        if specific, base.hasPrefix(id + ".") || base.hasSuffix("." + id) { return true }
        let name = appName.lowercased()
        return allowName && name.count >= 4 && base == name
    }
}
