import Foundation

/// The people whose work Osmotic is built on — shown in Settings › Credits and in About.
enum Credits {
    struct Entry: Identifiable {
        let name: String
        let work: String
        let url: URL
        var id: String { url.absoluteString }
    }

    static let code: [Entry] = [
        Entry(
            name: "Konrad Iturbe", work: "Osmosis for Android — the protocol and file-list decoder this app is ported from (MIT)",
            url: URL(string: "https://github.com/KonradIT/osmosis")!),
        Entry(
            name: "Brian Merchant", work: "Kaze for DJI — capture control and live view, adapted (MIT)",
            url: URL(string: "https://github.com/brianmerchant/Kaze-for-DJI")!),
        Entry(
            name: "erik-sutton95", work: "OpenPocketCine — live-view and control notes (Apache-2.0)",
            url: URL(string: "https://github.com/erik-sutton95/OpenPocketCine")!),
    ]

    static let research: [Entry] = [
        Entry(
            name: "DJI OGs", work: "The original reverse engineering of DJI's DUML protocol",
            url: URL(string: "https://github.com/o-gs")!),
        Entry(name: "dimadesu", work: "dji-remote — DUML CRC", url: URL(string: "https://github.com/dimadesu/dji-remote")!),
        Entry(name: "SemiConscious", work: "osmo-download", url: URL(string: "https://github.com/SemiConscious/osmo-download")!),
        Entry(
            name: "sniffingpickles", work: "DJI-Wifi-Connect",
            url: URL(string: "https://github.com/sniffingpickles/DJI-Wifi-Connect")!),
        Entry(name: "yigitkonur", work: "lib-osmo-ble", url: URL(string: "https://github.com/yigitkonur/lib-osmo-ble")!),
        Entry(name: "samuelsadok", work: "dji_protocol", url: URL(string: "https://github.com/samuelsadok/dji_protocol")!),
        Entry(
            name: "xaionaro", work: "reverse-engineering-dji",
            url: URL(string: "https://github.com/xaionaro/reverse-engineering-dji")!),
    ]

    /// Osmosis' testers, credited there for the cameras its author doesn't own.
    static let testers: [Entry] = [
        Entry(name: "Rhoenschrat", work: "Osmosis testing", url: URL(string: "https://www.rhoenschrat.de/")!),
        Entry(name: "Juan Irache", work: "Osmosis testing", url: URL(string: "https://github.com/JuanIrache")!),
        Entry(name: "GetHypoxic", work: "Osmosis testing", url: URL(string: "https://gethypoxic.com/")!),
        Entry(name: "Ave (aveao)", work: "Osmosis: Action 4 verified on hardware", url: URL(string: "https://github.com/aveao")!),
    ]
}
