import AVFoundation
import SwiftUI

/// The Webcam tab: the camera plugged in by USB, as every other app on the Mac sees it — or, until it
/// is, the three steps to get there.
struct WebcamView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cam = model.webcam
        VStack(alignment: .leading, spacing: Theme.s3) {
            LCDGlass {
                HStack(spacing: Theme.s4) {
                    LCDText(
                        text: (cam.device?.localizedName ?? String(localized: "No USB camera")).uppercased(),
                        size: 12.5, weight: .medium, color: cam.device == nil ? Theme.lcdText.opacity(0.75) : Theme.lcdText)
                    if cam.device != nil {
                        LCDPair(label: "Link", value: "USB")
                        if let res = cam.resolution { LCDPair(label: "Picture", value: res) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.s3 + 2)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if cam.device != nil {
                monitor(cam)
                Text("Pick it as the camera in Zoom, Meet, FaceTime, OBS or any other app — Osmotic doesn’t need to stay open.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                steps
            }
        }
        .padding(.horizontal, Theme.s3)
        .padding(.bottom, Theme.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.webcam.show() }
        .onDisappear { model.webcam.hide() }
        .onChange(of: AppVisibility.shared.visible) { _, visible in
            if visible { Task { await model.webcam.show() } } else { model.webcam.hide() }
        }
    }

    private func monitor(_ cam: WebcamService) -> some View {
        ZStack {
            if let session = cam.session {
                WebcamPreview(session: session)
            } else if cam.access == .denied {
                VStack(spacing: Theme.s3) {
                    LCDText(
                        text: String(localized: "No camera access").uppercased(), size: 12, weight: .medium, color: Theme.warning)
                    CassetteKeyBank {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.primaryKey)
                    }
                }
            }
        }
        .aspectRatio(cam.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        .modifier(Pocket(fill: .black, radius: Theme.radiusM, deep: true))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Webcam picture")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            step(1, "Plug the camera into this Mac with a USB-C cable.")
            step(2, "On the camera, choose Webcam when it asks how to connect.")
            step(3, "It shows up here, and as a camera in Zoom, Meet, FaceTime or OBS.")
            EngravedRule().padding(.vertical, Theme.s1)
            Text(
                "As a webcam the picture goes over the cable in full quality and the camera charges. The Live tab works without the cable, over Wi-Fi, at preview quality."
            )
            .font(.callout)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.s4)
        .frame(maxWidth: 620, alignment: .leading)
        .raisedPanel(screws: true)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.s4)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            Text(String(format: "%02ld", n))
                .font(Theme.readout(13, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
