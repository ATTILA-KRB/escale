import Foundation
import IOKit
import IOKit.serial

/// Un port série détecté.
public struct DetectedSerialPort: Hashable, Identifiable, Sendable {
    /// Chemin d'appel sortant (`/dev/cu.…`).
    public let path: String
    /// Nom lisible : produit USB si connu, sinon nom du périphérique.
    public let name: String
    public var id: String { path }
    public init(path: String, name: String) { self.path = path; self.name = name }
}

/// Liste des ports série de la machine : IOKit (nom du produit USB), repli sur l'énumération de `/dev/cu.*`.
public enum SerialPortDiscovery {
    public static func list() -> [DetectedSerialPort] {
        var found = ioKitPorts()
        let known = Set(found.map(\.path))
        for p in devPorts() where !known.contains(p.path) { found.append(p) }
        return found.sorted { $0.path < $1.path }
    }

    /// `/dev/cu.*` seul (repli, et testable sans IOKit).
    public static func devPorts(directory: String = "/dev") -> [DetectedSerialPort] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("cu.") }.sorted().map {
            DetectedSerialPort(path: "\(directory)/\($0)", name: String($0.dropFirst(3)))
        }
    }

    static func ioKitPorts() -> [DetectedSerialPort] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [DetectedSerialPort] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, kIOCalloutDeviceKey, parents: false) as? String else { continue }
            let product = property(service, "USB Product Name", parents: true) as? String
            let fallback = String(path.split(separator: "/").last ?? "").replacingOccurrences(of: "cu.", with: "")
            let name = (product?.isEmpty == false) ? "\(product!) (\(fallback))" : fallback
            result.append(DetectedSerialPort(path: path, name: name))
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String, parents: Bool) -> Any? {
        let options = IOOptionBits(parents ? kIORegistryIterateRecursively | kIORegistryIterateParents : 0)
        return IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
    }
}
