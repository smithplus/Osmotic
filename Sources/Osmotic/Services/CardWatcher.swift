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
    /// macOS is refusing to read a removable volume: the app needs permission in
    /// Privacy & Security › Files and Folders, or the reader can point at the card themselves.
    private(set) var accessDenied = false

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
                if result.denied { log("card: macOS refused to read a removable volume (permission)") }
            }
            guard result.cards != cards else { return }
            cards = result.cards
            log("card: \(result.cards.map { "\($0.name) [\($0.link?.label ?? "unknown link")]" }.joined(separator: ", "))")
        }
    }

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
    private nonisolated static func scan() -> (cards: [Card], denied: Bool) {
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
        return (cards, denied)
    }

    // ---- How the cable negotiated ----------------------------------------------------------------

    /// The USB speed of the device this volume lives on: the disk's BSD name, then up the IO registry
    /// until a USB device turns up, and its `Device Speed`.
    nonisolated static func link(of volume: URL) -> Link? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
            let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) })
        else { return nil }

        var media: io_service_t = IO_OBJECT_NULL
        // The whole-disk media (disk5), not the partition (disk5s1), carries the USB parent.
        let whole = bsd.split(separator: "s").first.map(String.init) ?? bsd
        if let matching = IOBSDNameMatching(kIOMainPortDefault, 0, whole) {
            media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        }
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }

        var node = media
        IOObjectRetain(node)
        for _ in 0..<12 {
            if let speed = IORegistryEntryCreateCFProperty(node, "Device Speed" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int, let link = Link(rawValue: speed)
            {
                IOObjectRelease(node)
                return link
            }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(node)
            node = parent
        }
        IOObjectRelease(node)
        return nil
    }
}
