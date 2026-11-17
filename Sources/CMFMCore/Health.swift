import Foundation
import IOKit

public struct BatteryHealth: Sendable {
    public let cycleCount: Int
    /// Current full-charge capacity as a share of the design capacity, 0...100+.
    public let capacityPercent: Int
    public let temperatureCelsius: Double?
}

/// Raw measurements the health score is computed from.
public struct HealthInputs: Sendable {
    public var disk: DiskUsage
    public var memory: MemoryUsage
    public var swapUsed: Int64
    public var battery: BatteryHealth?
    /// Nil when the drive does not report SMART.
    public var smartVerified: Bool?
    public var uptime: TimeInterval
    public var loadAverage: Double
    public var cores: Int
    public var thermalPressure: ThermalPressure

    public enum ThermalPressure: Sendable { case nominal, fair, serious, critical }

    public init(disk: DiskUsage, memory: MemoryUsage, swapUsed: Int64, battery: BatteryHealth?, smartVerified: Bool?,
                uptime: TimeInterval, loadAverage: Double, cores: Int, thermalPressure: ThermalPressure) {
        self.disk = disk
        self.memory = memory
        self.swapUsed = swapUsed
        self.battery = battery
        self.smartVerified = smartVerified
        self.uptime = uptime
        self.loadAverage = loadAverage
        self.cores = cores
        self.thermalPressure = thermalPressure
    }
}

public struct HealthKPI: Identifiable, Sendable {
    public enum Status: Int, Sendable, Comparable {
        case good, warning, critical
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let value: String
    public let detail: String
    public let status: Status
    /// Points removed from the score of 100.
    public let penalty: Int
}

public struct HealthReport: Sendable {
    public let kpis: [HealthKPI]
    public var score: Int { max(0, 100 - kpis.reduce(0) { $0 + $1.penalty }) }
    public var worst: HealthKPI.Status { kpis.map(\.status).max() ?? .good }

    public init(inputs: HealthInputs) {
        var kpis: [HealthKPI] = []
        func add(_ id: String, _ title: String, _ symbol: String, _ value: String,
                 _ levels: (status: HealthKPI.Status, penalty: Int, detail: String)) {
            kpis.append(HealthKPI(id: id, title: title, symbol: symbol, value: value, detail: levels.detail,
                                  status: levels.status, penalty: levels.penalty))
        }

        let freeShare = inputs.disk.total > 0 ? Double(inputs.disk.free) / Double(inputs.disk.total) : 1
        add("disk", String(localized: "Disk space"), "internaldrive.fill", String(localized: "\(Fmt.bytes(inputs.disk.free)) free"),
            freeShare < 0.10 ? (.critical, 30, String(localized: "Less than \(10)% free: macOS slows down and updates fail."))
            : freeShare < 0.20 ? (.warning, 12, String(localized: "Less than \(20)% free: make some room."))
            : (.good, 0, String(localized: "\(Int(freeShare * 100))% of the disk is free.")))

        if let verified = inputs.smartVerified {
            add("smart", String(localized: "SSD status"), "checkmark.shield.fill",
                verified ? String(localized: "Verified") : String(localized: "Failing"),
                verified ? (.good, 0, String(localized: "The drive reports no errors (SMART)."))
                : (.critical, 40, String(localized: "The drive reports errors: back up your data now.")))
        }

        if let battery = inputs.battery {
            add("battery-health", String(localized: "Battery health"), "battery.100", "\(min(100, battery.capacityPercent)) %",
                battery.capacityPercent < 80 ? (.critical, 20, String(localized: "Below \(80)% of the original capacity: replacement advised."))
                : battery.capacityPercent < 90 ? (.warning, 6, String(localized: "Capacity declining, normal wear."))
                : (.good, 0, String(localized: "Capacity close to the original.")))
            add("battery-cycles", String(localized: "Charge cycles"), "arrow.triangle.2.circlepath", "\(battery.cycleCount)",
                battery.cycleCount > 1000 ? (.warning, 8, String(localized: "Beyond the 1000 cycles Apple plans for."))
                : (.good, 0, String(localized: "Out of the 1000 cycles Apple plans for.")))
            if let temperature = battery.temperatureCelsius {
                add("battery-temperature", String(localized: "Battery temperature"), "thermometer.medium",
                    String(format: "%.0f °C", temperature),
                    temperature > 45 ? (.critical, 10, String(localized: "Too hot: the battery wears fast above 45 °C."))
                    : temperature > 38 ? (.warning, 3, String(localized: "Warm. Avoid soft surfaces and direct sunlight."))
                    : (.good, 0, String(localized: "Normal temperature.")))
            }
        }

        let memoryShare = inputs.memory.usedFraction
        add("memory", String(localized: "Memory"), "memorychip.fill", String(localized: "\(Int((memoryShare * 100).rounded()))% used"),
            memoryShare > 0.92 ? (.critical, 12, String(localized: "Memory saturated: quit the hungriest apps."))
            : memoryShare > 0.82 ? (.warning, 4, String(localized: "Memory is filling up."))
            : (.good, 0, String(localized: "\(Fmt.bytes(inputs.memory.total - inputs.memory.used)) available.")))

        add("swap", String(localized: "Swap memory"), "arrow.left.arrow.right", Fmt.bytes(inputs.swapUsed),
            inputs.swapUsed > 8 << 30 ? (.critical, 10, String(localized: "The Mac writes a lot of memory to disk: not enough RAM."))
            : inputs.swapUsed > 3 << 30 ? (.warning, 4, String(localized: "Notable swap: too many apps open at once."))
            : (.good, 0, String(localized: "Little or no swap.")))

        let loadPerCore = inputs.cores > 0 ? inputs.loadAverage / Double(inputs.cores) : 0
        add("load", String(localized: "CPU load"), "cpu.fill", String(format: "%.1f", inputs.loadAverage),
            loadPerCore > 1.5 ? (.warning, 5, String(localized: "Average load above the number of cores (\(inputs.cores))."))
            : (.good, 0, String(localized: "1-minute average load, for \(inputs.cores) cores.")))

        let heat = String(localized: "Heat")
        switch inputs.thermalPressure {
        case .nominal: add("thermal", heat, "flame.fill", String(localized: "Normal"), (.good, 0, String(localized: "No thermal throttling.")))
        case .fair: add("thermal", heat, "flame.fill", String(localized: "Moderate"), (.good, 0, String(localized: "Fans active, no throttling.")))
        case .serious: add("thermal", heat, "flame.fill", String(localized: "High"), (.warning, 8, String(localized: "The system is throttling performance.")))
        case .critical: add("thermal", heat, "flame.fill", String(localized: "Critical"), (.critical, 15, String(localized: "Heavy throttling: let the Mac cool down.")))
        }

        let days = Int(inputs.uptime / 86_400)
        add("uptime", String(localized: "Up for"), "clock.fill",
            days >= 1 ? String(localized: "\(days) d") : "\(Int(inputs.uptime / 3600)) h",
            days > 14 ? (.warning, 4, String(localized: "A restart frees memory and temporary files."))
            : (.good, 0, String(localized: "Recently restarted.")))

        self.kpis = kpis
    }
}

extension SystemInfo {
    public static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? Int64(usage.xsu_used) : 0
    }

    public static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    /// Nil on Macs without a battery.
    public static func batteryHealth() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        // Depending on the Mac, capacities sit at the top level or one level down (BatteryData).
        let nested = properties.values.compactMap { $0 as? [String: Any] }
        func value(_ key: String) -> Int? {
            (properties[key] as? Int) ?? nested.lazy.compactMap { $0[key] as? Int }.first
        }
        guard let cycles = value("CycleCount"), let design = value("DesignCapacity"), design > 0 else { return nil }
        // AppleRawMaxCapacity is in mAh like DesignCapacity; top-level MaxCapacity is already a percentage on Apple silicon.
        let maximum = value("AppleRawMaxCapacity") ?? value("NominalChargeCapacity") ?? design
        // Temperature is in hundredths of a degree Celsius.
        let temperature = value("Temperature").map { Double($0) / 100 }
        return BatteryHealth(cycleCount: cycles, capacityPercent: maximum * 100 / design, temperatureCelsius: temperature)
    }

    /// SMART verdict of the boot drive, from `diskutil`. Nil when unsupported or unreadable.
    public static func smartVerified() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let status = plist["SMARTStatus"] as? String, status != "Not Supported" else { return nil }
        return status == "Verified"
    }

    public static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
