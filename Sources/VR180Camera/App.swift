import SwiftUI

@main struct VR180CameraApp: App {
    @StateObject private var camera = CameraManager()
    var body: some Scene {
        WindowGroup("VR180 Camera") {
            ContentView()
                .environmentObject(camera)
                .frame(minWidth: 700, idealWidth: 800, minHeight: 500, idealHeight: 700)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var camera: CameraManager
    @State private var showViewfinderSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VR180 Camera Controller (macOS)").font(.title2.bold())
                    Text(camera.phase).font(.headline).foregroundStyle(.blue)
                }
                Spacer()

                // Big iOS Camera Viewfinder Entry
                Button(action: { showViewfinderSheet = true }) {
                    Label("Live Viewfinder Mode", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(!camera.paired)

                Button("Scan / Refresh") { camera.scan() }
            }
            .sheet(isPresented: $showViewfinderSheet) {
                CameraViewfinderSheet()
                    .environmentObject(camera)
            }
            
            GroupBox("1. Camera Discovery & Selection") {
                VStack(alignment: .leading, spacing: 8) {
                    if camera.cameras.isEmpty {
                        Text("Scanning for cameras... Ensure Bluetooth is enabled or set camera to pairing mode (hold Shutter until LED blinks blue/green).")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(camera.cameras) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name).font(.body.weight(.medium))
                                    Text(item.id.uuidString).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(item.signal) dBm").font(.caption).monospacedDigit()
                                Button("Connect") { camera.connect(item.id) }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(6)
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            
            GroupBox("2. Pairing & Secure Channel Setup") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        StepBadge(step: 1, title: "1. BLE Connect", active: isStepActive(1), completed: isStepCompleted(1))
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        StepBadge(step: 2, title: "2. Key Exchange", active: isStepActive(2), completed: isStepCompleted(2))
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        StepBadge(step: 3, title: "3. Confirm Button", active: isStepActive(3), completed: isStepCompleted(3))
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        StepBadge(step: 4, title: "4. Channel Ready", active: isStepActive(4), completed: isStepCompleted(4))
                    }
                    .padding(.vertical, 4)

                    Divider()

                    Text(camera.pairingHint)
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hintBackgroundColor)
                        .cornerRadius(8)

                    HStack {
                        Button("Forget Paired Key (Pair Again)") { camera.rePair() }
                        Button("Refresh Status") { camera.refreshStatus() }.disabled(!camera.paired)
                        Spacer()
                    }
                }
                .padding(4)
            }
            
            GroupBox("3. Camera Status & Capture Controls") {
                VStack(alignment: .leading, spacing: 14) {
                    // Quick Remote Shutter Control Bar
                    HStack(spacing: 16) {
                        Picker("Mode", selection: $camera.currentCaptureType) {
                            Text("📹 Video").tag(UInt64(0))
                            Text("📷 Photo").tag(UInt64(1))
                            Text("📡 Live").tag(UInt64(2))
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .onChange(of: camera.currentCaptureType) { newType in
                            camera.setCaptureModeType(newType)
                        }

                        Button(action: { camera.triggerShutter() }) {
                            if camera.isRecording {
                                Label("Stop Recording (\(camera.recordingDurationSeconds)s)", systemImage: "stop.circle.fill")
                                    .font(.headline)
                            } else if camera.currentCaptureType == 1 {
                                Label("Take Photo", systemImage: "camera.circle.fill")
                                    .font(.headline)
                            } else {
                                Label("Start Recording", systemImage: "record.circle")
                                    .font(.headline)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(camera.isRecording ? .red : (camera.currentCaptureType == 1 ? .blue : .red))
                        .disabled(!camera.statusReady || camera.isCapturing)

                        Button(action: { showViewfinderSheet = true }) {
                            Label("Open Viewfinder", systemImage: "viewfinder")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!camera.paired)

                        Spacer()

                        if let battery = camera.batteryPercentage {
                            HStack(spacing: 4) {
                                Image(systemName: camera.isCharging ? "battery.100.bolt" : "battery.100")
                                    .foregroundStyle(battery > 20 ? .green : .red)
                                Text("\(battery)%").font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)

                    Text(camera.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Text("ISO Setting")
                        TextField("e.g. 100", text: $camera.isoText).frame(width: 100)
                        Button("Apply ISO") { camera.setISO() }.disabled(!camera.statusReady)
                        Spacer()
                    }
                    if !camera.videoModes.isEmpty {
                        HStack {
                            Text("Video Mode").frame(width: 90, alignment: .leading)
                            Picker("", selection: $camera.selectedVideo) { ForEach(camera.videoModes) { Text($0.title).tag($0.id) } }.labelsHidden().frame(maxWidth: 240)
                            Button("Apply") { camera.setVideoMode() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                    if !camera.photoModes.isEmpty {
                        HStack {
                            Text("Photo Mode").frame(width: 90, alignment: .leading)
                            Picker("", selection: $camera.selectedPhoto) { ForEach(camera.photoModes) { Text($0.title).tag($0.id) } }.labelsHidden().frame(maxWidth: 240)
                            Button("Apply") { camera.setPhotoMode() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                    if !camera.liveModes.isEmpty {
                        HStack {
                            Text("Live Mode").frame(width: 90, alignment: .leading)
                            Picker("", selection: $camera.selectedLive) { ForEach(camera.liveModes) { Text($0.title).tag($0.id) } }.labelsHidden().frame(maxWidth: 240)
                            Button("Apply") { camera.setLiveMode() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                    if camera.supportsFlatColor {
                        HStack {
                            Toggle("Flat Color", isOn: $camera.flatColor).frame(width: 150)
                            Button("Apply") { camera.setFlatColor() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                    if camera.supportsAudio {
                        HStack {
                            Toggle("Mute Shutter", isOn: $camera.shutterMuted).frame(width: 150)
                            Button("Apply") { camera.setShutterMute() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                }.padding(8)
            }
            
            GroupBox("4. Media Browser & HTTPS File Transfer") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("📶 Enable Camera Wi-Fi Hotspot") { camera.enableHotspot() }.disabled(!camera.paired).buttonStyle(.borderedProminent)
                        Spacer()
                        Text("Camera IP: ")
                        TextField("IP", text: $camera.cameraIP).frame(width: 110)
                        Text("Port: ")
                        TextField("Port", text: $camera.cameraPort).frame(width: 50)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("🔑 Camera Wi-Fi Hotspot Details:").font(.subheadline.bold())
                                HStack {
                                    Text("SSID:").font(.caption)
                                    TextField("SSID", text: $camera.hotspotSSID).font(.caption.bold()).frame(width: 150)
                                    Text("Password:").font(.caption)
                                    TextField("Password", text: $camera.hotspotPassword).font(.caption.bold().monospaced()).frame(width: 120)
                                }
                            }
                            Spacer()
                            Button("⚡️ Connect Wi-Fi Automatically") {
                                camera.connectWifi()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(camera.hotspotSSID.isEmpty || camera.hotspotPassword.isEmpty)

                            Button("Copy Password") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(camera.hotspotPassword, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .disabled(camera.hotspotPassword.isEmpty)
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }

                    Text("Tip: Click 'Enable Camera Wi-Fi Hotspot' to broadcast the camera's AP. Connect your Mac to this Wi-Fi network using the password shown above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)

                    HStack {
                        Button("Fetch Media List") { camera.listMedia() }.disabled(!camera.paired).buttonStyle(.borderedProminent)
                        
                        Divider().frame(height: 16)
                        
                        Button("◀ Prev") {
                            camera.prevPage()
                        }
                        .disabled(!camera.paired || camera.mediaPageStartIndex == 0)

                        if camera.mediaTotalCount > 0 || !camera.mediaList.isEmpty {
                            Text("Items \(camera.mediaPageStartIndex + 1) ~ \(camera.mediaPageStartIndex + camera.mediaList.count) of \(camera.mediaTotalCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Button("Next ▶") {
                            camera.nextPage()
                        }
                        .disabled(!camera.paired || (camera.mediaTotalCount > 0 && camera.mediaPageStartIndex + camera.mediaPageSize >= camera.mediaTotalCount))

                        Spacer()
                        
                        Text("Per Page:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $camera.mediaPageSize) {
                            Text("4").tag(4)
                            Text("8").tag(8)
                            Text("12").tag(12)
                            Text("20").tag(20)
                        }
                        .labelsHidden()
                        .frame(width: 60)
                        .onChange(of: camera.mediaPageSize) { _ in
                            camera.listMediaPage(startIndex: camera.mediaPageStartIndex)
                        }
                    }
                    if !camera.downloadProgressText.isEmpty {
                        Text(camera.downloadProgressText)
                            .font(.callout)
                            .foregroundStyle(.blue)
                    }
                    if camera.mediaList.isEmpty {
                        Text("Click 'Fetch Media List' to view photo and video files on the SD card.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(spacing: 12) {
                                ForEach(camera.mediaList) { item in
                                    VStack(alignment: .leading, spacing: 6) {
                                        if let data = item.thumbnailData, let nsImage = NSImage(data: data) {
                                            Image(nsImage: nsImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 140, height: 90)
                                                .clipped()
                                                .cornerRadius(6)
                                        } else {
                                            Rectangle()
                                                .fill(Color.secondary.opacity(0.15))
                                                .frame(width: 140, height: 90)
                                                .overlay(
                                                    Image(systemName: "photo")
                                                        .foregroundStyle(.secondary)
                                                )
                                                .cornerRadius(6)
                                        }
                                        Text(item.filename)
                                            .font(.caption.bold())
                                            .lineLimit(1)
                                            .frame(width: 140, alignment: .leading)
                                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Button("Download") {
                                            camera.downloadMedia(item)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.06))
                                    .cornerRadius(8)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }.padding(8)
            }
            
            GroupBox("Operation & Communication Logs") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(camera.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(8)
                }
                .frame(height: 150)
            }
        }
        .padding(20)
        }
    }

    private var hintBackgroundColor: Color {
        switch camera.pairingStep {
        case .waitingForPhysicalConfirm: return Color.orange.opacity(0.15)
        case .connected: return Color.green.opacity(0.15)
        case .failed: return Color.red.opacity(0.15)
        default: return Color.blue.opacity(0.1)
        }
    }

    private func isStepActive(_ step: Int) -> Bool {
        switch (step, camera.pairingStep) {
        case (1, .connecting): return true
        case (2, .initiatingKeyExchange): return true
        case (3, .waitingForPhysicalConfirm), (3, .finalizing): return true
        case (4, .connected): return true
        default: return false
        }
    }

    private func isStepCompleted(_ step: Int) -> Bool {
        switch camera.pairingStep {
        case .initiatingKeyExchange: return step < 2
        case .waitingForPhysicalConfirm, .finalizing: return step < 3
        case .connected: return step <= 4
        default: return false
        }
    }
}

struct StepBadge: View {
    let step: Int
    let title: String
    let active: Bool
    let completed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: completed ? "checkmark.circle.fill" : (active ? "ellipsis.circle.fill" : "circle"))
                .foregroundStyle(completed ? .green : (active ? .orange : .secondary))
            Text(title)
                .font(.subheadline)
                .fontWeight(active || completed ? .semibold : .regular)
                .foregroundStyle(completed ? Color.primary : (active ? Color.orange : Color.secondary))
        }
    }
}
