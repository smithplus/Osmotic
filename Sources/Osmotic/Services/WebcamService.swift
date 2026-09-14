import AVFoundation
import SwiftUI

/// The camera as a USB webcam. A Pocket 3 plugged in by USB-C, with Webcam chosen on its screen, is a
/// standard UVC camera: every app on the Mac can use it. This finds it, follows it being plugged and
/// unplugged, and shows its picture in the Webcam tab.
@Observable
final class WebcamService {
    enum Access { case unknown, granted, denied }

    private(set) var device: AVCaptureDevice?
    private(set) var access: Access = .unknown
    /// Width / height of the camera's active format.
    private(set) var aspect: CGFloat = 16 / 9
    private(set) var resolution: String?
    @ObservationIgnored private(set) var session: AVCaptureSession?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var active = false

    init() {
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
        refresh()
    }

    /// DJI cameras announce themselves by name ("OsmoPocket3", "DJI Osmo Action…").
    static func isDJI(_ d: AVCaptureDevice) -> Bool {
        let n = d.localizedName.lowercased()
        return n.contains("osmo") || n.contains("pocket") || n.contains("dji")
    }

    func refresh() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first(where: Self.isDJI)
        guard found?.uniqueID != device?.uniqueID else { return }
        log("webcam: \(found.map { "found \($0.localizedName)" } ?? "no DJI camera on USB")")
        stopSession()
        device = found
        if let found {
            let d = CMVideoFormatDescriptionGetDimensions(found.activeFormat.formatDescription)
            if d.height > 0 { aspect = CGFloat(d.width) / CGFloat(d.height) }
            resolution = d.height > 0 ? "\(min(d.width, d.height))P" : nil
        }
        if active { Task { await start() } }
    }

    /// The tab is showing: ask for camera access if needed, then run the preview.
    func start() async {
        active = true
        // Only ask for camera access once there is a camera to show — never on an empty tab.
        guard device != nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = .granted
        case .notDetermined: access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: access = .denied
        }
        guard access == .granted, let device, session == nil, active else { return }
        let s = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else {
            log("webcam: couldn't open \(device.localizedName)")
            return
        }
        s.addInput(input)
        session = s
        let running = SessionBox(s)
        Task.detached { running.session.startRunning() }  // blocking call: keep it off the main thread
        log("webcam: preview running")
    }

    /// The tab went away: release the camera so other apps get it cleanly.
    func stop() {
        active = false
        stopSession()
    }

    private func stopSession() {
        guard let s = session else { return }
        session = nil
        let box = SessionBox(s)
        Task.detached { box.session.stopRunning() }
    }
}

/// `AVCaptureSession` is documented thread-safe for start/stop; this only carries it off the main actor.
nonisolated private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ s: AVCaptureSession) { session = s }
}

/// Hosts an `AVCaptureVideoPreviewLayer` for the webcam's picture.
struct WebcamPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}
