import SwiftUI

@main struct VR180CameraApp: App {
    @StateObject private var camera = CameraManager()
    var body: some Scene {
        WindowGroup("VR180 相机") {
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
                    Text("VR180 相机控制端 (macOS)").font(.title2.bold())
                    Text(camera.phase).font(.headline).foregroundStyle(.blue)
                }
                Spacer()

                // Big iOS Camera Viewfinder Entry
                Button(action: { showViewfinderSheet = true }) {
                    Label("进入实时相机取景模式", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(!camera.paired)

                Button("刷新 / 重新搜索") { camera.scan() }
            }
            .sheet(isPresented: $showViewfinderSheet) {
                CameraViewfinderSheet()
                    .environmentObject(camera)
            }
            
            GroupBox("1. 相机发现与选择") {
                VStack(alignment: .leading, spacing: 8) {
                    if camera.cameras.isEmpty {
                        Text("正在搜索... 请开启相机蓝牙或将相机切换至配对模式（长按拍照键直至蓝绿灯交替闪烁）。")
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
                                Button("连接设备") { camera.connect(item.id) }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(6)
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            
            GroupBox("2. 配对与安全连接流程") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        StepBadge(step: 1, title: "1. 蓝牙连接", active: isStepActive(1), completed: isStepCompleted(1))
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        StepBadge(step: 2, title: "2. 密钥交换", active: isStepActive(2), completed: isStepCompleted(2))
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        StepBadge(step: 3, title: "3. 相机按键确认", active: isStepActive(3), completed: isStepCompleted(3))
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        StepBadge(step: 4, title: "4. 通道建立完成", active: isStepActive(4), completed: isStepCompleted(4))
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
                        Button("清除本地配对记录（重新配对）") { camera.rePair() }
                        Button("主动读取状态") { camera.refreshStatus() }.disabled(!camera.paired)
                        Spacer()
                    }
                }
                .padding(4)
            }
            
            GroupBox("3. 相机状态与拍摄控制") {
                VStack(alignment: .leading, spacing: 14) {
                    // Quick Remote Shutter Control Bar
                    HStack(spacing: 16) {
                        Picker("模式", selection: $camera.currentCaptureType) {
                            Text("📹 视频").tag(UInt64(0))
                            Text("📷 照片").tag(UInt64(1))
                            Text("📡 直播").tag(UInt64(2))
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .onChange(of: camera.currentCaptureType) { newType in
                            camera.setCaptureModeType(newType)
                        }

                        Button(action: { camera.triggerShutter() }) {
                            if camera.isRecording {
                                Label("停止录像 (\(camera.recordingDurationSeconds)s)", systemImage: "stop.circle.fill")
                                    .font(.headline)
                            } else if camera.currentCaptureType == 1 {
                                Label("远程拍照", systemImage: "camera.circle.fill")
                                    .font(.headline)
                            } else {
                                Label("开始录像", systemImage: "record.circle")
                                    .font(.headline)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(camera.isRecording ? .red : (camera.currentCaptureType == 1 ? .blue : .red))
                        .disabled(!camera.statusReady || camera.isCapturing)

                        Button(action: { showViewfinderSheet = true }) {
                            Label("全屏取景", systemImage: "viewfinder")
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
                        Text("ISO 步进")
                        TextField("例如 100", text: $camera.isoText).frame(width: 100)
                        Button("应用 ISO") { camera.setISO() }.disabled(!camera.statusReady)
                        Spacer()
                    }
                    if !camera.videoModes.isEmpty {
                        HStack {
                            Text("视频规格").frame(width: 80, alignment: .leading)
                            Picker("", selection: $camera.selectedVideo) { ForEach(camera.videoModes) { Text($0.title).tag($0.id) } }.labelsHidden().frame(maxWidth: 240)
                            Button("应用") { camera.setVideoMode() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                    if !camera.photoModes.isEmpty {
                        HStack {
                            Text("照片规格").frame(width: 80, alignment: .leading)
                            Picker("", selection: $camera.selectedPhoto) { ForEach(camera.photoModes) { Text($0.title).tag($0.id) } }.labelsHidden().frame(maxWidth: 240)
                            Button("应用") { camera.setPhotoMode() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                    if !camera.liveModes.isEmpty {
                        HStack {
                            Text("直播规格").frame(width: 80, alignment: .leading)
                            Picker("", selection: $camera.selectedLive) { ForEach(camera.liveModes) { Text($0.title).tag($0.id) } }.labelsHidden().frame(maxWidth: 240)
                            Button("应用") { camera.setLiveMode() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                    if camera.supportsFlatColor {
                        HStack {
                            Toggle("平面色彩", isOn: $camera.flatColor).frame(width: 150)
                            Button("应用") { camera.setFlatColor() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                    if camera.supportsAudio {
                        HStack {
                            Toggle("快门静音", isOn: $camera.shutterMuted).frame(width: 150)
                            Button("应用") { camera.setShutterMute() }.disabled(!camera.statusReady)
                            Spacer()
                        }
                    }
                }.padding(8)
            }
            
            GroupBox("4. 媒体浏览与 HTTPS 文件下载") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("📶 开启相机 Wi-Fi 热点") { camera.enableHotspot() }.disabled(!camera.paired).buttonStyle(.borderedProminent)
                        Spacer()
                        Text("相机 IP: ")
                        TextField("IP", text: $camera.cameraIP).frame(width: 110)
                        Text("端口: ")
                        TextField("Port", text: $camera.cameraPort).frame(width: 50)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("🔑 相机 Wi-Fi 热点信息：").font(.subheadline.bold())
                                HStack {
                                    Text("SSID:").font(.caption)
                                    TextField("SSID", text: $camera.hotspotSSID).font(.caption.bold()).frame(width: 150)
                                    Text("密码:").font(.caption)
                                    TextField("Password", text: $camera.hotspotPassword).font(.caption.bold().monospaced()).frame(width: 120)
                                }
                            }
                            Spacer()
                            Button("⚡️ 自动连接此 Wi-Fi") {
                                camera.connectWifi()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(camera.hotspotSSID.isEmpty || camera.hotspotPassword.isEmpty)

                            Button("复制密码") {
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

                    Text("提示：点击【开启相机 Wi-Fi 热点】后，相机会广播热点。在 Mac 顶部菜单栏连接此热点并输入上方显示的密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)

                    HStack {
                        Button("读取相机媒体文件列表") { camera.listMedia() }.disabled(!camera.paired).buttonStyle(.borderedProminent)
                        
                        Divider().frame(height: 16)
                        
                        Button("◀ 上一页") {
                            camera.prevPage()
                        }
                        .disabled(!camera.paired || camera.mediaPageStartIndex == 0)

                        if camera.mediaTotalCount > 0 || !camera.mediaList.isEmpty {
                            Text("第 \(camera.mediaPageStartIndex + 1) ~ \(camera.mediaPageStartIndex + camera.mediaList.count) 项 / 共 \(camera.mediaTotalCount) 项")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Button("下一页 ▶") {
                            camera.nextPage()
                        }
                        .disabled(!camera.paired || (camera.mediaTotalCount > 0 && camera.mediaPageStartIndex + camera.mediaPageSize >= camera.mediaTotalCount))

                        Spacer()
                        
                        Text("每页数量:")
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
                        Text("点击“读取相机媒体文件列表”获取相片和视频清单。")
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
                                        Button("下载此文件") {
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
            
            GroupBox("运行与通信日志") {
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

