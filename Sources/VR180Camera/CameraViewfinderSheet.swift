import SwiftUI
import AppKit

struct CameraViewfinderSheet: View {
    @EnvironmentObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var shutterScale: CGFloat = 1.0
    @State private var showFlash: Bool = false
    @State private var selectedTab: UInt64 = 1 // 0=Video, 1=Photo

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar
                topControlBar
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                // Viewfinder / Center Canvas Area
                ZStack {
                    // Camera Preview Frame
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(white: 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .overlay(
                            viewfinderCanvas
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 24)

                    // Flash feedback overlay on capture
                    if showFlash {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white)
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }

                    // Recording indicator overlay
                    if camera.isRecording {
                        VStack {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 10, height: 10)
                                    .opacity(blinkOpacity)
                                Text(formatSeconds(camera.recordingDurationSeconds))
                                    .font(.system(.headline, design: .monospaced))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.65)))
                            .padding(.top, 20)

                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom Camera Control Bar (iOS Style)
                bottomControls
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 640, idealHeight: 720)
        .onAppear {
            selectedTab = camera.currentCaptureType
            if let key = camera.sharedKey, !camera.viewfinderManager.isStreaming {
                camera.viewfinderManager.startViewfinder(
                    cameraIP: camera.cameraIP,
                    cameraPort: camera.cameraPort,
                    key: key,
                    clockSkew: camera.clockSkew ?? 0
                )
            }
        }
        .onDisappear {
            camera.viewfinderManager.stopViewfinder()
        }
        .onChange(of: camera.currentCaptureType) { newType in
            selectedTab = newType
        }
    }

    // MARK: - Top Control Bar
    private var topControlBar: some View {
        HStack {
            // Close Button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)

            Spacer()

            // Status Badges (Battery, SD Card, Wi-Fi / BLE)
            HStack(spacing: 16) {
                // Connection indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(camera.paired ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(camera.paired ? "相机已连接" : "未连接")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.12)))

                // Battery Status
                if let battery = camera.batteryPercentage {
                    HStack(spacing: 5) {
                        Image(systemName: camera.isCharging ? "battery.100.bolt" : batteryIconName(for: battery))
                            .font(.subheadline)
                            .foregroundStyle(batteryColor(for: battery))
                        Text("\(battery)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }

                // Storage Status
                if let free = camera.storageFreeBytes, let total = camera.storageTotalBytes, total > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "sdcard.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                        Text(formatStorage(free: free, total: total))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
            }

            Spacer()

            // Refresh Status Button
            Button(action: { camera.refreshStatus() }) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("刷新相机状态")
        }
    }

    // MARK: - Viewfinder Canvas
    private var viewfinderCanvas: some View {
        ZStack {
            if let track = camera.viewfinderManager.remoteVideoTrack {
                // Live WebRTC Video View
                WebRTCVideoView(videoTrack: track)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                // Placeholder & Connection guide
                VStack(spacing: 16) {
                    Image(systemName: "video.badge.waveform")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))

                    VStack(spacing: 6) {
                        Text("VR180 双目实时取景")
                            .font(.title3.bold())
                            .foregroundStyle(.white)

                        Text(camera.viewfinderManager.statusMessage)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))

                        if !camera.hotspotSSID.isEmpty {
                            Text("Wi-Fi 热点: \(camera.hotspotSSID) · 相机地址: \(camera.cameraIP):\(camera.cameraPort)")
                                .font(.caption)
                                .foregroundStyle(.green.opacity(0.9))
                        } else {
                            Text("当前相机地址: \(camera.cameraIP):\(camera.cameraPort)（若未连接请确保 Mac 已加入相机 Wi-Fi）")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            if let key = camera.sharedKey {
                                camera.viewfinderManager.startViewfinder(
                                    cameraIP: camera.cameraIP,
                                    cameraPort: camera.cameraPort,
                                    key: key,
                                    clockSkew: camera.clockSkew ?? 0
                                )
                            }
                        }) {
                            Label(camera.viewfinderManager.isStreaming ? "取景运行中" : "启动 / 重启 WebRTC 取景", systemImage: "play.circle.fill")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(camera.sharedKey == nil)

                        if camera.hotspotSSID.isEmpty {
                            Button(action: { camera.enableHotspot() }) {
                                Label("获取相机热点", systemImage: "wifi")
                                    .font(.callout.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding()
            }

            // Dual lens VR180 crosshair guides (like iOS camera reticle)
            HStack(spacing: 80) {
                LensReticle(label: "LEFT (左眼)")
                LensReticle(label: "RIGHT (右眼)")
            }
            .opacity(camera.viewfinderManager.remoteVideoTrack != nil ? 0.35 : 0.2)
        }
    }

    // MARK: - Bottom Controls
    private var bottomControls: some View {
        VStack(spacing: 20) {
            // Mode Selector (视频 | 照片 | 直播)
            HStack(spacing: 32) {
                ModeTabButton(title: "视频", isSelected: selectedTab == 0) {
                    guard selectedTab != 0 else { return }
                    selectedTab = 0
                    camera.setCaptureModeType(0)
                }

                ModeTabButton(title: "照片", isSelected: selectedTab == 1) {
                    guard selectedTab != 1 else { return }
                    selectedTab = 1
                    camera.setCaptureModeType(1)
                }

                ModeTabButton(title: "全景直播", isSelected: selectedTab == 2) {
                    guard selectedTab != 2 else { return }
                    selectedTab = 2
                    camera.setCaptureModeType(2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))

            // Shutter & Controls Row
            HStack(spacing: 0) {
                // Left: Quick Thumbnail Preview / Album Access
                HStack {
                    if let thumb = camera.lastCapturedThumb, let nsImage = NSImage(data: thumb) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white, lineWidth: 2)
                            )
                    } else if let firstMedia = camera.mediaList.first, let thumb = firstMedia.thumbnailData, let nsImage = NSImage(data: thumb) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white, lineWidth: 2)
                            )
                    } else {
                        Button(action: {
                            camera.listMediaPage(startIndex: 0)
                        }) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Image(systemName: "photo.on.rectangle")
                                        .font(.title3)
                                        .foregroundStyle(.white.opacity(0.7))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("读取媒体库")
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // Center: Big Shutter Button
                ZStack {
                    // Outer Ring
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 78, height: 78)

                    // Inner Shutter Button
                    Button(action: {
                        triggerShutterWithAnimation()
                    }) {
                        if selectedTab == 0 {
                            // Video Shutter: Red square when recording, red circle when idle
                            RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 32)
                                .fill(Color.red)
                                .frame(width: camera.isRecording ? 32 : 64, height: camera.isRecording ? 32 : 64)
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: camera.isRecording)
                        } else {
                            // Photo Shutter: Big white circle
                            Circle()
                                .fill(Color.white)
                                .frame(width: 64, height: 64)
                                .scaleEffect(shutterScale)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!camera.paired || camera.isCapturing)
                }

                // Right: Quick Settings / Mode Config
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        if !camera.photoModes.isEmpty && selectedTab == 1 {
                            Text(camera.photoModes.indices.contains(camera.selectedPhoto) ? camera.photoModes[camera.selectedPhoto].title : "")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.8))
                        } else if !camera.videoModes.isEmpty && selectedTab == 0 {
                            Text(camera.videoModes.indices.contains(camera.selectedVideo) ? camera.videoModes[camera.selectedVideo].title : "")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        if !camera.isoText.isEmpty {
                            Text("ISO \(camera.isoText)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.yellow.opacity(0.9))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Actions & Helpers
    private func triggerShutterWithAnimation() {
        if selectedTab == 1 {
            // Photo shutter animation
            withAnimation(.easeInOut(duration: 0.1)) {
                shutterScale = 0.85
                showFlash = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeOut(duration: 0.15)) {
                    shutterScale = 1.0
                    showFlash = false
                }
            }
        }
        camera.triggerShutter()
    }

    private var blinkOpacity: Double {
        return (camera.recordingDurationSeconds % 2 == 0) ? 1.0 : 0.2
    }

    private func formatSeconds(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func batteryIconName(for pct: Int) -> String {
        if pct > 80 { return "battery.100" }
        if pct > 60 { return "battery.75" }
        if pct > 40 { return "battery.50" }
        if pct > 20 { return "battery.25" }
        return "battery.0"
    }

    private func batteryColor(for pct: Int) -> Color {
        if pct > 40 { return .green }
        if pct > 20 { return .yellow }
        return .red
    }

    private func formatStorage(free: UInt64, total: UInt64) -> String {
        let freeGB = Double(free) / 1_073_741_824.0
        return String(format: "%.1f GB 可用", freeGB)
    }
}

// MARK: - Supporting Subviews
struct ModeTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.yellow : Color.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct LensReticle: View {
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: 90, height: 90)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 20, height: 1.5)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1.5, height: 20)
            }
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
        }
    }
}
