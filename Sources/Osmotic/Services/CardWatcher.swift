import AppKit
import DiskArbitration
import Foundation
import IOKit
import OsmoticCore

/// Cards plugged into the Mac: an Osmo in storage mode mounts its SD card as a removable volume
/// with `DCIM` on it. The watcher keeps the list current (mount and unmount notifications) and reads
/// how fast the cable actually negotiated, which is worth knowing before copying 100 GB.
@Observable
final class CardWatcher {
    struct Card: Identifiable, Hashable {
        let volume: URL
        let name: String
        let freeBytes: Int
        let totalBytes: Int
        let link: Link?
        var id: URL { volume }
    }

    /// What the USB port settled on. The camera and the cable both have to support a speed for it to
    /// show up here: a charge-only cable lands on `.high` even on a Thunderbolt port.
    enum Link: Int, Hashable {
        case low = 0
        case full = 1
        case high = 2
        case superSpeed = 3
        case superPlus = 4
        case superPlus20 = 5

        /// What the standard calls it: "USB 2.0", "USB 3".
        var label: String {
            switch self {
            case .low, .full: "USB 1"
            case .high: "USB 2.0"
            case .superSpeed: "USB 3"
            case .superPlus: "USB 3 (10 Gb/s)"
            case .superPlus20: "USB 3 (20 Gb/s)"
            }
        }

        /// Its ceiling, as the bus states it.
        var headline: String {
            switch self {
            case .low: "1.5 Mb/s"
            case .full: "12 Mb/s"
            case .high: "480 Mb/s"
            case .superSpeed: "5 Gb/s"
            case .superPlus: "10 Gb/s"
            case .superPlus20: "20 Gb/s"
            }
        }

        /// True while a different cable could plausibly do better (anything below SuperSpeed).
        var isSlow: Bool { rawValue < Link.superSpeed.rawValue }
    }

    private(set) var cards: [Card] = []
    /// Measured read speed per card, in MB/s: what the cable and the card really give, which is the
    /// number worth seeing before copying 40 GB.
    private(set) var measured: [URL: Double] = [:]
    /// Cards whose measurement is running.
    private(set) var measuring: Set<URL> = []
    /// macOS is refusing to read a removable volume: the app needs permission in
    /// Privacy & Security › Files and Folders, or the reader can point at the card themselves.
    private(set) var accessDenied = false
    /// A DJI camera is on the USB bus but none of its cards is mounted: it left storage mode, or
    /// the card was ejected in Finder. Unplugging and plugging it back in brings the card back.
    private(set) var cameraWithoutCard: String?
    /// The first scan is always logged, even when it finds nothing, so a log says what the app saw.
    @ObservationIgnored private var scanned = false

    init(watch: Bool = true) {
        refresh()
        guard watch else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// Looks again, off the main thread. The first read of a removable volume is what makes macOS ask
    /// for permission, and that question blocks whoever asked: never the thread drawing the window.
    func refresh() {
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.scan() }.value
            guard let self else { return }
            if result.denied != accessDenied {
                accessDenied = result.denied
                if result.denied { log("card: a removable volume couldn't be read (permission or I/O)") }
            }
            let bare = result.cards.isEmpty ? result.djiOnUSB : nil
            if bare != cameraWithoutCard {
                cameraWithoutCard = bare
                if let bare { log("card: \(bare) is on USB but no card is mounted") }
            }
            guard result.cards != cards || !scanned else { return }
            scanned = true
            cards = result.cards
            measured = measured.filter { entry in result.cards.contains { $0.volume == entry.key } }
            let listed = result.cards.map { "\($0.name) [\($0.link?.label ?? "unknown link")]" }.joined(separator: ", ")
            log("card: \(listed.isEmpty ? "none plugged in" : listed)")
            for card in result.cards where measured[card.volume] == nil { measure(card) }
        }
    }

    /// Reads a stretch of the biggest clip on the card, once per mount, to report real MB/s.
    func measure(_ card: Card) {
        guard !measuring.contains(card.volume) else { return }
        measuring.insert(card.volume)
        let volume = card.volume
        Task { [weak self] in
            let speed = await Task.detached(priority: .utility) { CardProbe.readSpeed(on: volume) }.value
            guard let self else { return }
            measuring.remove(volume)
            guard let speed else { return }
            measured[volume] = speed
            log("card: \(card.name) reads at \(String(format: "%.0f", speed)) MB/s")
        }
    }

    /// MB/s measured for this card, when the measurement has finished.
    func speed(of card: Card) -> Double? { measured[card.volume] }
    func isMeasuring(_ card: Card) -> Bool { measuring.contains(card.volume) }

    /// A volume the reader pointed at themselves (an open panel): macOS counts that as consent, so it
    /// works even when the permission was refused earlier.
    func card(at volume: URL) -> Card? {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        guard CardScanner.isCameraCard(volume) else { return nil }
        let values = try? volume.resourceValues(forKeys: Set(keys))
        accessDenied = false
        return Card(
            volume: volume,
            name: values?.volumeName ?? volume.lastPathComponent,
            freeBytes: values?.volumeAvailableCapacity ?? 0,
            totalBytes: values?.volumeTotalCapacity ?? 0,
            link: Self.link(of: volume))
    }

    /// Off the main thread: which mounted volumes are camera cards, and whether macOS refused a look.
    private nonisolated static func scan() -> (cards: [Card], denied: Bool, djiOnUSB: String?) {
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey, .volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
        ]
        let volumes =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var cards: [Card] = []
        var denied = false
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)), values.volumeIsRemovable == true
            else { continue }
            switch CardScanner.access(to: volume) {
            case .card:
                cards.append(
                    Card(
                        volume: volume,
                        name: values.volumeName ?? volume.lastPathComponent,
                        freeBytes: values.volumeAvailableCapacity ?? 0,
                        totalBytes: values.volumeTotalCapacity ?? 0,
                        link: link(of: volume)))
            case .denied: denied = true
            case .notACard: break
            }
        }
        return (cards, denied, djiCameraOnUSB())
    }

    /// The product name of a DJI device on the USB bus (vendor 0x2CA3), if there is one.
    nonisolated static func djiCameraOnUSB() -> String? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let vendor =
                IORegistryEntryCreateCFProperty(service, "idVendor" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            guard vendor?.intValue == 0x2CA3 else { continue }
            let name =
                IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            return name ?? "DJI camera"
        }
        return nil
    }

    // ---- How the cable negotiated ----------------------------------------------------------------

    /// The USB speed of the device this volume lives on: the disk's BSD name, then one search up the
    /// IO registry for the `Device Speed` the USB host device published.
    nonisolated static func link(of volume: URL) -> Link? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
            let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) })
        else { return nil }

        // The whole-disk media (disk5), not the partition (disk5s1), is the one under the USB device.
        // Splitting on "s" would cut "disk5" itself, so the suffix is trimmed after the digits.
        var whole = ""
        for ch in bsd {
            if ch.isNumber || whole.isEmpty || !whole.last!.isNumber { whole.append(ch) } else { break }
        }
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, whole) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }

        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        guard
            let value = IORegistryEntrySearchCFProperty(
                media, kIOServicePlane, "Device Speed" as CFString, kCFAllocatorDefault, options) as? NSNumber
        else { return nil }
        return Link(rawValue: value.intValue)
    }
}
