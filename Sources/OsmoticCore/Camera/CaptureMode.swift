import Foundation

/// A capture mode, as the camera numbers it in `0x02/0xE1` (set) and byte 57 of the `0x02/0x80`
/// status push (read). Codes from the Pocket 3 as documented by Kaze-for-DJI (MIT) and
/// OpenPocketCine (Apache-2.0); see `docs/CONTROL.md`.
public enum CaptureMode: UInt8, CaseIterable, Sendable, Identifiable {
    case slowMotion = 0x00
    case video = 0x01
    case timelapse = 0x02
    case photo = 0x05
    case hyperlapse = 0x0A
    case panorama = 0x0C
    case motionlapse = 0x18
    case lowLight = 0x28

    public var id: UInt8 { rawValue }

    /// Modes where the shutter records a clip (start/stop) rather than taking one picture.
    public var records: Bool {
        switch self {
        case .photo, .panorama: false
        default: true
        }
    }

    /// The modes offered on the control deck: the ones whose shutter command is known (record for
    /// clips, one shot for photo). Timelapse/Hyperlapse may start with `0x02/0x01` rather than
    /// `0x02/0x02` on a Pocket 3 (unverified), so they stay off the deck until tried on hardware.
    public static let deck: [CaptureMode] = [.video, .photo, .slowMotion, .lowLight]
}
