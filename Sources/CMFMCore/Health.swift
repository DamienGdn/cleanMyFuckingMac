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
        add("disk", "Espace disque", "internaldrive.fill", "\(Fmt.bytes(inputs.disk.free)) libres",
            freeShare < 0.10 ? (.critical, 30, "Moins de 10 % libres : macOS ralentit et les mises à jour échouent.")
            : freeShare < 0.20 ? (.warning, 12, "Moins de 20 % libres : fais de la place.")
            : (.good, 0, "\(Int(freeShare * 100)) % du disque est libre."))

        if let verified = inputs.smartVerified {
            add("smart", "État du SSD", "checkmark.shield.fill", verified ? "Vérifié" : "Défaillant",
                verified ? (.good, 0, "Le disque ne signale aucune erreur (SMART).")
                : (.critical, 40, "Le disque signale des erreurs : sauvegarde tes données maintenant."))
        }

        if let battery = inputs.battery {
            add("battery-health", "Santé de la batterie", "battery.100", "\(min(100, battery.capacityPercent)) %",
                battery.capacityPercent < 80 ? (.critical, 20, "Sous 80 % de la capacité d'origine : remplacement conseillé.")
                : battery.capacityPercent < 90 ? (.warning, 6, "Capacité en baisse, usure normale.")
                : (.good, 0, "Capacité proche de l'origine."))
            add("battery-cycles", "Cycles de charge", "arrow.triangle.2.circlepath", "\(battery.cycleCount)",
                battery.cycleCount > 1000 ? (.warning, 8, "Au-delà des 1000 cycles prévus par Apple.")
                : (.good, 0, "Sur 1000 cycles prévus par Apple."))
            if let temperature = battery.temperatureCelsius {
                add("battery-temperature", "Température batterie", "thermometer.medium", String(format: "%.0f °C", temperature),
                    temperature > 45 ? (.critical, 10, "Trop chaude : la batterie s'use vite au-dessus de 45 °C.")
                    : temperature > 38 ? (.warning, 3, "Chaude. Évite les surfaces molles et le plein soleil.")
                    : (.good, 0, "Température normale."))
            }
        }

        let memoryShare = inputs.memory.usedFraction
        add("memory", "Mémoire", "memorychip.fill", "\(Int((memoryShare * 100).rounded())) % utilisée",
            memoryShare > 0.92 ? (.critical, 12, "Mémoire saturée : quitte les apps les plus gourmandes.")
            : memoryShare > 0.82 ? (.warning, 4, "Mémoire bien remplie.")
            : (.good, 0, "\(Fmt.bytes(inputs.memory.total - inputs.memory.used)) disponibles."))

        add("swap", "Mémoire d'échange", "arrow.left.arrow.right", Fmt.bytes(inputs.swapUsed),
            inputs.swapUsed > 8 << 30 ? (.critical, 10, "Le Mac écrit beaucoup de mémoire sur le disque : manque de RAM.")
            : inputs.swapUsed > 3 << 30 ? (.warning, 4, "Swap notable : trop d'apps ouvertes à la fois.")
            : (.good, 0, "Peu ou pas de swap."))

        let loadPerCore = inputs.cores > 0 ? inputs.loadAverage / Double(inputs.cores) : 0
        add("load", "Charge processeur", "cpu.fill", String(format: "%.1f", inputs.loadAverage),
            loadPerCore > 1.5 ? (.warning, 5, "Charge moyenne supérieure au nombre de cœurs (\(inputs.cores)).")
            : (.good, 0, "Charge moyenne sur 1 min, pour \(inputs.cores) cœurs."))

        switch inputs.thermalPressure {
        case .nominal: add("thermal", "Chauffe", "flame.fill", "Normale", (.good, 0, "Aucun bridage thermique."))
        case .fair: add("thermal", "Chauffe", "flame.fill", "Modérée", (.good, 0, "Ventilation active, sans bridage."))
        case .serious: add("thermal", "Chauffe", "flame.fill", "Élevée", (.warning, 8, "Le système bride les performances."))
        case .critical: add("thermal", "Chauffe", "flame.fill", "Critique", (.critical, 15, "Bridage fort : laisse le Mac refroidir."))
        }

        let days = Int(inputs.uptime / 86_400)
        add("uptime", "Allumé depuis", "clock.fill", days >= 1 ? "\(days) j" : "\(Int(inputs.uptime / 3600)) h",
            days > 14 ? (.warning, 4, "Un redémarrage libère mémoire et fichiers temporaires.")
            : (.good, 0, "Redémarrage récent."))

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
