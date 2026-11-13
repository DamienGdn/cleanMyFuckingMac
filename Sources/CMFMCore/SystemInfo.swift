import Foundation
import IOKit.ps

public struct DiskUsage: Sendable {
    public let total: Int64
    public let free: Int64
    public var used: Int64 { total - free }

    public init(total: Int64, free: Int64) {
        self.total = total
        self.free = free
    }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct MemoryUsage: Sendable {
    public let total: Int64
    public let used: Int64

    public init(total: Int64, used: Int64) {
        self.total = total
        self.used = used
    }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct CPUTicks: Sendable {
    public let busy: UInt64
    public let total: UInt64

    /// Share of CPU time spent working between an earlier sample and this one, 0...1.
    public func usage(since earlier: CPUTicks) -> Double {
        let elapsed = total &- earlier.total
        return elapsed > 0 ? min(1, Double(busy &- earlier.busy) / Double(elapsed)) : 0
    }
}

public struct NetworkCounters: Sendable {
    public let received: UInt64
    public let sent: UInt64
}

public struct BatteryInfo: Sendable {
    public let percent: Int
    public let isCharging: Bool
}

public struct ProcessEntry: Identifiable, Sendable {
    public let pid: Int32
    public let name: String
    /// Owning application ("Google Chrome" for all its helpers), or the process name.
    public let app: String
    public let memory: Int64
    public let cpu: Double
    public var id: Int32 { pid }
}

public struct LaunchItem: Identifiable, Sendable {
    public let path: String
    public let label: String
    public let program: String
    public let runAtLoad: Bool
    /// Lives in the user's own LaunchAgents folder, so it can be removed without admin rights.
    public let isUserOwned: Bool
    public var id: String { path }
}

public enum SystemInfo {
    public static func diskUsage(path: String = "/") -> DiskUsage {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DiskUsage(total: Int64(values?.volumeTotalCapacity ?? 0),
                         free: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    public static func memoryUsage() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return MemoryUsage(total: total, used: 0) }
        let pages = Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return MemoryUsage(total: total, used: pages * Int64(vm_kernel_page_size))
    }

    /// Every running process, from `ps`.
    public static func processes() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,pcpu=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap(parseProcessLine)
    }

    static func parseProcessLine(_ line: Substring) -> ProcessEntry? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let rssKB = Int64(parts[1]),
              let cpu = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let command = String(parts[3])
        let name = (command as NSString).lastPathComponent
        // The outermost .app bundle owns the process: helpers are billed to their parent app.
        let bundle = command.split(separator: "/").first { $0.hasSuffix(".app") }
        return ProcessEntry(pid: pid, name: name, app: bundle.map { String($0.dropLast(4)) } ?? name,
                            memory: rssKB * 1024, cpu: cpu)
    }

    public static func cpuTicks() -> CPUTicks {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return CPUTicks(busy: 0, total: 0) }
        // cpu_ticks = (user, system, idle, nice)
        let (user, system, idle, nice) = info.cpu_ticks
        let busy = UInt64(user) + UInt64(system) + UInt64(nice)
        return CPUTicks(busy: busy, total: busy + UInt64(idle))
    }

    /// Bytes through the physical interfaces (en*) since boot. 32-bit kernel counters: diff with wrapping.
    public static func networkCounters() -> NetworkCounters {
        var received: UInt64 = 0, sent: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return NetworkCounters(received: 0, sent: 0) }
        defer { freeifaddrs(list) }
        var cursor = list
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: interface.pointee.ifa_name).hasPrefix("en"),
                  let data = interface.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(stats.ifi_ibytes)
            sent += UInt64(stats.ifi_obytes)
        }
        return NetworkCounters(received: received, sent: sent)
    }

    /// Nil on Macs without a battery.
    public static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return BatteryInfo(percent: current * 100 / maximum,
                               isCharging: (description[kIOPSIsChargingKey] as? Bool) ?? false)
        }
        return nil
    }

    public static func launchItems(home: String) -> [LaunchItem] {
        let userDirectory = home + "/Library/LaunchAgents"
        var items: [LaunchItem] = []
        for directory in [userDirectory, "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".plist") {
                let path = directory + "/" + name
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
                items.append(LaunchItem(path: path,
                                        label: (plist["Label"] as? String) ?? name,
                                        program: program,
                                        runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false,
                                        isUserOwned: directory == userDirectory))
            }
        }
        return items.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    /// The TCC database folder is only listable with Full Disk Access.
    public static func hasFullDiskAccess(home: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Application Support/com.apple.TCC")) != nil
    }
}
