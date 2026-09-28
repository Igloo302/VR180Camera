import Foundation
import CoreBluetooth
import CryptoKit
import CoreWLAN
import AppKit
import VR180Protocol

struct FoundCamera: Identifiable {
    let id: UUID
    var name: String
    var signal: Int
}

struct ModeChoice: Identifiable {
    let id: Int
    let title: String
    let raw: Data
}

struct MediaItem: Identifiable {
    let id: String
    let filename: String
    let size: UInt64
    let timestamp: UInt64
    let duration: UInt64
    let width: UInt64
    let height: UInt64
    var thumbnailData: Data? = nil
}

@MainActor final class CameraManager: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static var pairingService: CBUUID { CBUUID(string: "18723f72-8c4e-4dd7-8f3e-b93b9c29481f") }
    static var cameraService: CBUUID { CBUUID(string: "49eabc2a-73b0-411e-a26d-75415dd7708e") }
    static var requestUUID: CBUUID { CBUUID(string: "48f03338-852e-4dd5-aa44-cd1b32fcaeb9") }
    static var responseUUID: CBUUID { CBUUID(string: "9f14e1da-4add-4ec7-aa34-6106669e2c12") }
    static var statusUUID: CBUUID { CBUUID(string: "a03fedd3-0923-4398-854e-e2806d159a7f") }

    @Published var cameras: [FoundCamera] = []
    @Published var phase = "等待蓝牙"
    @Published var log: [String] = []
    @Published var detail = "尚未连接相机"
    @Published var paired = false
    @Published var statusReady = false
    @Published var isoText = ""
    @Published var videoModes: [ModeChoice] = []
    @Published var photoModes: [ModeChoice] = []
    @Published var liveModes: [ModeChoice] = []
    @Published var selectedVideo = 0
    @Published var selectedPhoto = 0
    @Published var selectedLive = 0
    @Published var flatColor = false
    @Published var supportsFlatColor = false
    @Published var shutterMuted = false
    @Published var supportsAudio = false
    @Published var pairingHint = "请将相机置于配对模式（长按拍照键至蓝绿灯交替闪烁），或从列表中选择已发现的设备。"
    @Published var pairingStep: PairingStep = .idle
    @Published var mediaList: [MediaItem] = []
    @Published var mediaPageStartIndex = 0
    @Published var mediaPageSize = 8
    @Published var mediaTotalCount = 0
    @Published var cameraIP = "192.168.49.1"
    @Published var cameraPort = "8443"
    @Published var downloadProgressText = ""
    @Published var wifiHotspotEnabled = false
    @Published var hotspotSSID = ""
    @Published var hotspotPassword = ""

    // Camera Capture & Status
    @Published var currentCaptureType: UInt64 = 1 // 0=Video, 1=Photo, 2=Live
    @Published var isRecording = false
    @Published var recordingDurationSeconds: Int = 0
    @Published var batteryPercentage: Int? = nil
    @Published var isCharging = false
    @Published var storageFreeBytes: UInt64? = nil
    @Published var storageTotalBytes: UInt64? = nil
    @Published var viewfinderStateText = "未启动取景"
    @Published var isCapturing = false // shutter animation
    @Published var lastCapturedThumb: Data? = nil

    private var recordingTimer: Timer?

    enum PairingStep {
        case idle
        case connecting
        case initiatingKeyExchange
        case waitingForPhysicalConfirm
        case finalizing
        case connected
        case failed(String)
    }

    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var requestCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var serviceUUID: CBUUID?
    private var chunks: [Data] = []
    private var writeWithoutResponse = false
    private var incoming = Data()
    private var pending: Pending = .none
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var salt = Data()
    var sharedKey: SymmetricKey?
    var clockSkew: Int64?
    @Published var viewfinderManager = WebRtcViewfinderManager()
    private var finalizeDeadline: Date?
    private var responseTimeout: DispatchWorkItem?
    private var switchingAfterPairing = false
    private var timeSyncAttempted = false
    private var capabilitiesFetched = false
    private var supportedISO: [UInt64] = []
    private var currentLiveMode: Data?
    private var maxAudioVolume: UInt64?
    private var operationName = "设置"
    private var reconnectingWithSavedKey = false
    private var startPairingWhenNotifying = false
    private var readStatusWhenNotifying = false
    private var fetchingThumbnailForIndex = -1
    private var peerPublicKey: Data?

    private enum Pending { case none, initiate, finalize, status, syncTime, capabilities, configure, listMedia, thumbnail, enableHotspot, startCapture, stopCapture, startViewfinder, stopViewfinder }

    override init() {
        super.init()
        if let key = PairingStore.lastKey {
            sharedKey = key
        }
        if let skew = PairingStore.lastClockSkew {
            clockSkew = skew
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }
    private func note(_ message: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard)): \(message)")
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: phase = "蓝牙可用"; scan()
        case .poweredOff: phase = "请开启蓝牙"; pairingStep = .idle
        case .unauthorized: phase = "请允许此应用访问蓝牙"; pairingStep = .idle
        default: phase = "蓝牙暂不可用"; pairingStep = .idle
        }
    }
    func scan() {
        guard central.state == .poweredOn else { return }
        cameras = []; discovered = [:]
        central.scanForPeripherals(withServices: [Self.pairingService, Self.cameraService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        if PairingStore.lastCameraID != nil {
            phase = "正在寻找已保存配对信息的相机..."
            pairingHint = "正在搜索已配对设备。如需重新配对新设备，请将新相机设为配对模式并手动点击连接。"
        } else {
            phase = "正在搜索附近的 VR180 相机..."
            pairingHint = "请确保相机已开机并处于配对模式（长按拍照键直至蓝绿灯交替闪烁）。"
        }
        note("开始搜索 VR180 服务")
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        discovered[peripheral.identifier] = peripheral
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "VR180 相机"
        let item = FoundCamera(id: peripheral.identifier, name: name, signal: RSSI.intValue)
        if let index = cameras.firstIndex(where: { $0.id == item.id }) { cameras[index] = item } else { cameras.append(item) }
        guard self.peripheral == nil else { return }
        
        let hasSavedPairing = PairingStore.hasSavedPairing
        let isDirectSavedCamera = PairingStore.lastCameraID == peripheral.identifier && PairingStore.key(for: peripheral.identifier) != nil
        
        var matchesAdvertisement = false
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            matchesAdvertisement = PairingStore.matchesAdvertisement(manufacturerData: mfgData)
        }
        
        if isDirectSavedCamera {
            note("发现已配对记录的相机，自动重连")
            connect(peripheral.identifier)
        } else if hasSavedPairing && matchesAdvertisement {
            note("广播特征匹配已配对相机的公钥 HMAC，自动重连")
            connect(peripheral.identifier)
        } else if hasSavedPairing && cameras.count == 1 {
            // 如果附近只有一台处于常规服务广播的相机且本地有保存的配对密钥，尝试自动重连
            let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            if advertisedServices.contains(Self.cameraService) {
                note("发现 VR180 常规服务广播，使用已保存密钥自动重连")
                connect(peripheral.identifier)
            }
        }
    }
    func connect(_ id: UUID) {
        guard let p = discovered[id] else { return }
        central.stopScan(); peripheral = p; p.delegate = self
        resetSession()
        pairingStep = .connecting
        if let key = PairingStore.key(for: id) ?? PairingStore.lastKey {
            sharedKey = key; reconnectingWithSavedKey = true
            phase = "正在重连已配对相机"; pairingHint = "已加载保存的配对密钥，正在进行安全校验..."
        } else {
            phase = "正在连接 \(p.name ?? "相机")"; pairingHint = "蓝牙连接已建立，准备开始密钥握手..."
        }
        central.connect(p)
    }
    private func resetSession() {
        requestCharacteristic = nil; responseCharacteristic = nil; statusCharacteristic = nil
        chunks = []; incoming = Data(); pending = .none
        sharedKey = nil; privateKey = nil; salt = Data(); clockSkew = nil
        paired = false; statusReady = false; switchingAfterPairing = false; timeSyncAttempted = false; capabilitiesFetched = false; supportedISO = []; reconnectingWithSavedKey = false
        startPairingWhenNotifying = false; readStatusWhenNotifying = false
        videoModes = []; photoModes = []; liveModes = []; supportsFlatColor = false; supportsAudio = false; currentLiveMode = nil; maxAudioVolume = nil; detail = "等待连接"
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phase = "已连接蓝牙，正在探索相机服务"; note("蓝牙连接成功")
        peripheral.discoverServices([Self.pairingService, Self.cameraService])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { fail("连接失败：\(error?.localizedDescription ?? "未知错误")") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        phase = "相机连接已断开"; statusReady = false; paired = false; pending = .none
        pairingStep = .idle
        responseTimeout?.cancel(); requestCharacteristic = nil; responseCharacteristic = nil; chunks = []
        note("相机断开：\(error?.localizedDescription ?? "正常断开")")
        self.peripheral = nil
        scan()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("读取服务失败：\(error.localizedDescription)"); return }
        let services = peripheral.services ?? []
        let chosen: CBService?
        if sharedKey != nil { chosen = services.first(where: { $0.uuid == Self.cameraService }) ?? services.first(where: { $0.uuid == Self.pairingService }) }
        else { chosen = services.first(where: { $0.uuid == Self.pairingService }) ?? services.first(where: { $0.uuid == Self.cameraService }) }
        guard let chosen else { fail("未找到 VR180 服务"); return }
        serviceUUID = chosen.uuid; note("找到服务 \(chosen.uuid.uuidString)")
        peripheral.discoverCharacteristics([Self.requestUUID, Self.responseUUID, Self.statusUUID], for: chosen)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail("读取特征值失败：\(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.requestUUID:
                requestCharacteristic = c
                note("请求特征值属性：write=\(c.properties.contains(.write)), withoutResponse=\(c.properties.contains(.writeWithoutResponse))")
                writeWithoutResponse = !c.properties.contains(.write) && c.properties.contains(.writeWithoutResponse)
            case Self.responseUUID: responseCharacteristic = c; peripheral.setNotifyValue(true, for: c)
            case Self.statusUUID: statusCharacteristic = c; peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        guard requestCharacteristic != nil, responseCharacteristic != nil else { fail("相机缺少请求或响应特征值"); return }
        if switchingAfterPairing {
            switchingAfterPairing = false; phase = "已切换至 API 服务"; note("相机 API 服务已就绪"); readStatusWhenNotifying = true
        } else if service.uuid == Self.cameraService, sharedKey != nil {
            phase = "正在验证已保存的密钥"; note("直接连接相机 API 服务，验证已保存的密钥")
            readStatusWhenNotifying = true
        } else if service.uuid == Self.pairingService {
            if sharedKey != nil { sharedKey = nil; reconnectingWithSavedKey = false; note("相机服务已变更为配对服务，切换为全新配对") }
            phase = "已就绪，正在准备配对"; pairingHint = "通讯通道建立完成，自动发起密钥交换..."
            note("配对服务已就绪，准备发起配对请求")
            startPairingWhenNotifying = true
        } else {
            phase = "协议通道已建立"; detail = "已找到通信特征值"
            note("请求和响应特征值已就绪")
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("订阅通知失败：\(error.localizedDescription)") }
        else {
            note("通知订阅已确认：\(characteristic.uuid.uuidString)")
            if characteristic.uuid == Self.responseUUID, characteristic.isNotifying {
                if startPairingWhenNotifying { startPairingWhenNotifying = false; startPairing() }
                else if readStatusWhenNotifying { readStatusWhenNotifying = false; refreshStatus() }
            }
        }
    }
    func startPairing() {
        guard requestCharacteristic != nil, responseCharacteristic != nil, pending == .none else { return }
        do {
            pairingStep = .initiatingKeyExchange
            let key = P256.KeyAgreement.PrivateKey(); privateKey = key
            salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let payload = CameraProtocol.keyExchange(publicKey: key.publicKey.x963Representation, salt: salt)
            phase = "步骤 1/3: 密钥交换中"; detail = "正在与相机交换 ECDH P-256 公钥及 Salt..."
            try send(CameraProtocol.request(type: 1, payload: payload), encrypted: false, pending: .initiate)
        } catch { fail("发起配对失败：\(error.localizedDescription)") }
    }
    func rePair() {
        PairingStore.forgetLastCamera()
        pairingStep = .idle
        pairingHint = "已清除本地密钥记录。请将相机设为配对模式后重新连接。"
        if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
        else { peripheral = nil; scan() }
    }
    func refreshStatus() {
        guard sharedKey != nil, pending == .none, peripheral?.state == .connected else { return }
        do { try send(CameraProtocol.request(type: 0, header: CameraProtocol.header()), encrypted: true, pending: .status) }
        catch { fail("读取状态失败：\(error.localizedDescription)") }
    }
    func setISO() {
        guard let iso = UInt64(isoText), iso <= 25600 else { fail("请输入有效 ISO 数值"); return }
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected, capabilitiesFetched else { fail("请先连接并读取相机能力列表"); return }
        guard supportedISO.contains(iso) else { fail("ISO \(iso) 不在相机支持列表中：\(supportedISO)"); return }
        do { try configure(CameraProtocol.isoConfig(iso, skew: skew), name: "ISO") }
        catch { fail("设置 ISO 失败：\(error.localizedDescription)") }
    }
    func setVideoMode() { setMode(videoModes, selected: selectedVideo, field: 11, name: "视频规格") }
    func setPhotoMode() { setMode(photoModes, selected: selectedPhoto, field: 12, name: "照片规格") }
    func setLiveMode() {
        guard liveModes.indices.contains(selectedLive), let original = currentLiveMode, let skew = clockSkew else { fail("直播规格或当前直播配置不可用"); return }
        do {
            let live = try PB(original)
            var updated = PB.bytes(1, liveModes[selectedLive].raw)
            for field in [2, 3] { for value in live.fields[field] ?? [] { updated.append(PB.bytes(field, value)) } }
            try configure(CameraProtocol.captureConfig(PB.bytes(13, updated), skew: skew), name: "直播规格")
        } catch { fail("设置直播规格失败：\(error.localizedDescription)") }
    }
    func setFlatColor() {
        guard supportsFlatColor, let skew = clockSkew else { fail("相机未提供平面色彩设置"); return }
        do { try configure(CameraProtocol.captureConfig(PB.number(9, flatColor ? 1 : 0), skew: skew), name: "平面色彩") }
        catch { fail("设置平面色彩失败：\(error.localizedDescription)") }
    }
    func setShutterMute() {
        guard supportsAudio, let max = maxAudioVolume, let skew = clockSkew else { fail("相机未提供声音设置"); return }
        do { try configure(CameraProtocol.audioConfig(volume: shutterMuted ? 0 : max, skew: skew), name: "快门声音") }
        catch { fail("设置快门声音失败：\(error.localizedDescription)") }
    }
    private func setMode(_ choices: [ModeChoice], selected: Int, field: Int, name: String) {
        guard choices.indices.contains(selected), let skew = clockSkew else { fail("\(name)不可用"); return }
        do { try configure(CameraProtocol.captureConfig(PB.bytes(field, choices[selected].raw), skew: skew), name: name) }
        catch { fail("设置\(name)失败：\(error.localizedDescription)") }
    }
    private func configure(_ request: Data, name: String) throws {
        guard statusReady, pending == .none, peripheral?.state == .connected else { throw WireError.malformed }
        operationName = name
        try send(request, encrypted: true, pending: .configure)
    }
    private func send(_ request: Data, encrypted: Bool, pending next: Pending) throws {
        guard let p = peripheral, let c = requestCharacteristic else { throw WireError.malformed }
        let body: Data
        if encrypted { guard let key = sharedKey else { throw WireError.crypto }; body = try CameraProtocol.encrypt(request, key: key) }
        else { body = request }
        self.pending = next
        responseTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pending != .none else { return }
            self.fail("等待相机响应超时；请检查相机蜂鸣/灯光确认提示或重新尝试配对")
            self.pending = .none
        }
        responseTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        let framed = CameraProtocol.frame(body)
        chunks = stride(from: 0, to: framed.count, by: 20).map { Data(framed[$0..<min($0+20, framed.count)]) }
        note("发送 \(request.count) 字节请求，\(chunks.count) 个蓝牙分片")
        if writeWithoutResponse { sendNextWithoutResponse() }
        else if !chunks.isEmpty { p.writeValue(chunks.removeFirst(), for: c, type: .withResponse) }
    }
    private func sendNextWithoutResponse() {
        guard let p = peripheral, let c = requestCharacteristic, !chunks.isEmpty else { return }
        guard p.canSendWriteWithoutResponse else { return }
        p.writeValue(chunks.removeFirst(), for: c, type: .withoutResponse)
        if !chunks.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.sendNextWithoutResponse() } }
        else { note("所有蓝牙分片已写入") }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { sendNextWithoutResponse() }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("蓝牙写入失败：\(error.localizedDescription)"); pending = .none; return }
        note("蓝牙分片写入确认；剩余 \(chunks.count) 片")
        if !chunks.isEmpty { peripheral.writeValue(chunks.removeFirst(), for: characteristic, type: .withResponse) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("通知读取失败：\(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Self.statusUUID { note("收到相机主动状态通知（\(value.count) 字节）"); return }
        guard characteristic.uuid == Self.responseUUID else { return }
        note("收到响应通知：\(value.count) 字节")
        incoming.append(value)
        guard incoming.suffix(2) == Data([0, 0]) else { return }
        let framed = incoming; incoming = Data()
        responseTimeout?.cancel()
        do {
            var body = try CameraProtocol.unframe(framed)
            if pending != .initiate && pending != .finalize {
                guard let key = sharedKey else { throw WireError.crypto }
                body = try CameraProtocol.decrypt(body, key: key)
            }
            try handle(PB(body))
        } catch { fail("解析相机响应失败：\(error.localizedDescription)"); pending = .none }
    }
    private func handle(_ response: PB) throws {
        let status = try PB(response.data(1)); let code = try status.uint(1)
        switch pending {
        case .initiate:
            guard code == 0, let key = privateKey else { throw WireError.malformed }
            let exchange = try PB(response.data(4)); let peer = try exchange.data(1); let peerSalt = try exchange.data(2)
            peerPublicKey = peer
            sharedKey = try CameraProtocol.deriveKey(privateKey: key, peer: peer, ownSalt: salt, peerSalt: peerSalt)
            finalizeDeadline = Date().addingTimeInterval(25)
            pairingStep = .waitingForPhysicalConfirm
            phase = "步骤 2/3: 请短按相机快门/拍照键！"
            pairingHint = "🔔 重要操作提示：请在 20 秒内短按一次相机本体上的快门/拍照按钮确认物理配对！"
            note("已派生密钥；等待用户在相机上按下快门/拍照键进行确认...")
            try sendFinalize()
        case .finalize:
            note("最终确认响应码：\(code)")
            if code == 0 {
                pending = .none; paired = true; phase = "步骤 3/3: 配对完成"; detail = "配对握手成功，正在切换至 API 通信通道"
                pairingStep = .connected
                note("相机实体物理确认成功，配对已建立")
                if let id = peripheral?.identifier, let key = sharedKey {
                    note(PairingStore.save(key, for: id, publicKey: peerPublicKey) ? "配对密钥已持久化保存；下次将自动重连" : "配对成功，但 KeyChain 保存失败")
                }
                pairingHint = "🎉 配对成功！已保存配对密钥，下次启动程序将直接重连并读取状态。"
                if let p = peripheral, let api = p.services?.first(where: { $0.uuid == Self.cameraService }) {
                    switchingAfterPairing = true; requestCharacteristic = nil; responseCharacteristic = nil
                    p.discoverCharacteristics([Self.requestUUID, Self.responseUUID, Self.statusUUID], for: api)
                } else { fail("配对完成但未找到相机 API 服务；请尝试重新连接") }
            }
            else if let deadline = finalizeDeadline, Date() < deadline {
                pending = .none
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in try? self?.sendFinalize() }
            } else {
                pending = .none
                pairingStep = .failed("超时未在相机上按键确认")
                fail("配对失败：未在 20 秒内按下相机快门键确认，已超时")
            }
        case .status:
            guard code == 0 else { pending = .none; fail("相机拒绝状态请求，状态码 \(code)"); return }
            if reconnectingWithSavedKey { reconnectingWithSavedKey = false; paired = true; pairingStep = .connected; note("已保存密钥验证通过，跳过按键配对步骤") }
            let camera = try PB(response.data(3))
            if let timestamp = camera.optionalUInt(8) {
                let skew = Int64(bitPattern: timestamp) &- Int64(Date().timeIntervalSince1970 * 1000)
                clockSkew = skew
                PairingStore.lastClockSkew = skew
                note("相机时间差：\(skew) 毫秒")
            }
            var lines: [String] = []
            if let captureData = camera.fields[5]?.first {
                let capture = try PB(captureData)
                if let iso = capture.optionalUInt(8) { isoText = String(iso); lines.append("ISO：\(iso)") }
                if let flat = capture.optionalUInt(9) { flatColor = flat == 1; lines.append("平面色彩：\(flatColor ? "开" : "关")") }
                if let raw = capture.fields[11]?.first, let index = videoModes.firstIndex(where: { $0.raw == raw }) { selectedVideo = index; lines.append("视频：\(videoModes[index].title)") }
                if let raw = capture.fields[12]?.first, let index = photoModes.firstIndex(where: { $0.raw == raw }) { selectedPhoto = index; lines.append("照片：\(photoModes[index].title)") }
                if let raw = capture.fields[13]?.first {
                    currentLiveMode = raw
                    let live = try PB(raw)
                    if let video = live.fields[1]?.first, let index = liveModes.firstIndex(where: { $0.raw == video }) { selectedLive = index; lines.append("直播：\(liveModes[index].title)") }
                }
                if let modeType = capture.optionalUInt(15) {
                    currentCaptureType = modeType
                }
            }
            // Field 2 = recording_status
            if let recData = camera.fields[2]?.first, let rec = try? PB(recData) {
                let state = rec.optionalUInt(1) ?? 0 // 0=IDLE, 1=RECORDING
                isRecording = (state == 1)
                if isRecording {
                    let startTime = rec.optionalUInt(10) ?? 0
                    if startTime > 0 {
                        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                        if nowMs > startTime {
                            recordingDurationSeconds = Int((nowMs - startTime) / 1000)
                        }
                    }
                    startRecordingTimer()
                } else {
                    stopRecordingTimer()
                }
            } else if !isRecording {
                stopRecordingTimer()
            }
            // Field 3 = battery_status
            if let batData = camera.fields[3]?.first, let bat = try? PB(batData) {
                if let charging = bat.optionalUInt(1) {
                    isCharging = (charging == 2 || charging == 5)
                }
                if let pct = bat.optionalUInt(2) {
                    batteryPercentage = Int(pct)
                }
            }
            // Field 4 = storage_status
            if let storData = camera.fields[4]?.first, let stor = try? PB(storData) {
                storageFreeBytes = stor.optionalUInt(1)
                storageTotalBytes = stor.optionalUInt(2)
            }
            if let raw = camera.fields[17]?.first {
                let audio = try PB(raw)
                if let volume = audio.optionalUInt(1), let max = audio.optionalUInt(2) {
                    supportsAudio = true; maxAudioVolume = max; shutterMuted = volume == 0
                    lines.append("快门声音：\(shutterMuted ? "静音" : "开")")
                }
            }
            note("相机状态字段 Keys: \(camera.fields.keys.sorted())")
            if let httpData = camera.fields[6]?.first, let http = try? PB(httpData) {
                note("Field 6 (HttpServerStatus) 子字段 Keys: \(http.fields.keys.sorted())")
                if let hostData = http.fields[2]?.first, let host = String(data: hostData, encoding: .utf8), !host.isEmpty {
                    cameraIP = host
                    note("从相机获取到 IP: \(host)")
                }
                if let port = http.optionalUInt(3) {
                    cameraPort = String(port)
                    note("从相机获取到端口: \(port)")
                }
            }
            if let apData = camera.fields[11]?.first {
                if let ap = try? PB(apData) {
                    note("Field 11 子字段 Keys: \(ap.fields.keys.sorted())")
                    if let sData = ap.fields[1]?.first, let s = String(data: sData, encoding: .utf8) {
                        hotspotSSID = s
                    }
                    if let pData = ap.fields[2]?.first, let p = String(data: pData, encoding: .utf8) {
                        hotspotPassword = p
                    }
                }
            }
            if !hotspotSSID.isEmpty || !hotspotPassword.isEmpty {
                note("🔑 解析到相机 Wi-Fi 热点 SSID: [\(hotspotSSID)], 密码: [\(hotspotPassword)]")
            }
            detail = lines.joined(separator: " · "); pending = .none
            note("状态读取成功：\(detail)")
            if let skew = clockSkew, abs(skew) > 10_000, !timeSyncAttempted {
                timeSyncAttempted = true; phase = "正在同步相机时间"
                try send(CameraProtocol.timeConfig(skew: skew), encrypted: true, pending: .syncTime)
            } else if !capabilitiesFetched, let skew = clockSkew {
                phase = "正在读取相机能力"
                try send(CameraProtocol.capabilitiesRequest(skew: skew), encrypted: true, pending: .capabilities)
            } else { statusReady = capabilitiesFetched; phase = "相机在线，控制功能已就绪" }
        case .syncTime:
            pending = .none
            guard code == 0 else { fail("相机时间同步失败，状态码 \(code)"); return }
            note("相机时间同步成功")
            clockSkew = 0
            refreshStatus()
        case .capabilities:
            pending = .none
            guard code == 0 else { fail("能力列表读取失败，状态码 \(code)"); return }
            let caps = try PB(response.data(7))
            var values = caps.integers[11] ?? []
            for packed in caps.fields[11] ?? [] { values += try Self.decodePackedVarints(packed) }
            supportedISO = Array(Set(values)).sorted(); capabilitiesFetched = true
            videoModes = try (caps.fields[4] ?? []).enumerated().map { ModeChoice(id: $0.offset, title: try Self.videoTitle($0.element), raw: $0.element) }
            photoModes = try (caps.fields[5] ?? []).enumerated().map { ModeChoice(id: $0.offset, title: try Self.photoTitle($0.element), raw: $0.element) }
            liveModes = try (caps.fields[6] ?? []).enumerated().map { ModeChoice(id: $0.offset, title: try Self.videoTitle($0.element), raw: $0.element) }
            supportsFlatColor = caps.optionalUInt(12) == 1
            statusReady = true; phase = "相机控制已准备就绪"
            detail += " · 支持 ISO：\(supportedISO.map(String.init).joined(separator: ", "))"
            note("相机能力：视频 \(videoModes.count) 种、照片 \(photoModes.count) 种、直播 \(liveModes.count) 种；平面色彩 \(supportsFlatColor ? "支持" : "不支持")；ISO \(supportedISO)")
            refreshStatus()
        case .configure:
            pending = .none
            if code == 0 { phase = "\(operationName)设置成功"; note("相机确认\(operationName)设置；正在回读状态"); refreshStatus() }
            else { fail("相机拒绝\(operationName)设置，状态码 \(code)"); refreshStatus() }
        case .listMedia:
            pending = .none
            guard code == 0 else { fail("读取媒体列表失败，状态码 \(code)"); return }
            let mediaResp = try PB(response.data(8))
            var items: [MediaItem] = []
            for mediaData in mediaResp.fields[3] ?? [] {
                let m = try PB(mediaData)
                let name = (try? m.data(1)).flatMap { String(data: $0, encoding: .utf8) } ?? "未知文件"
                let size = m.optionalUInt(2) ?? 0
                let timestamp = m.optionalUInt(3) ?? 0
                let duration = m.optionalUInt(4) ?? 0
                let width = m.optionalUInt(7) ?? 0
                let height = m.optionalUInt(8) ?? 0
                items.append(MediaItem(id: name, filename: name, size: size, timestamp: timestamp, duration: duration, width: width, height: height))
            }
            mediaTotalCount = Int(mediaResp.optionalUInt(2) ?? UInt64(items.count))
            mediaList = items
            phase = "媒体列表已读取（本页 \(items.count) 个，共 \(mediaTotalCount) 个）"
            note("获取到第 \(mediaPageStartIndex + 1)~\(mediaPageStartIndex + items.count) 个媒体文件（总计 \(mediaTotalCount) 个）")
            fetchNextThumbnail()
        case .thumbnail:
            pending = .none
            if code == 0, fetchingThumbnailForIndex >= 0, fetchingThumbnailForIndex < mediaList.count {
                var thumbData: Data? = nil
                if let data9 = try? response.data(9), let thumbResp = try? PB(data9) {
                    thumbData = (try? thumbResp.data(1)) ?? thumbResp.fields[1]?.first
                }
                if thumbData == nil {
                    thumbData = response.fields[9]?.first ?? response.fields[1]?.first
                }
                if let validData = thumbData, !validData.isEmpty {
                    mediaList[fetchingThumbnailForIndex].thumbnailData = validData
                    if fetchingThumbnailForIndex == 0 {
                        lastCapturedThumb = validData
                    }
                    note("缩略图已成功获取：\(mediaList[fetchingThumbnailForIndex].filename) (\(validData.count) 字节)")
                } else {
                    note("缩略图数据解析为空：\(mediaList[fetchingThumbnailForIndex].filename)")
                }
            } else {
                note("缩略图请求返回非 0 状态码: \(code)")
            }
            fetchNextThumbnail()
        case .enableHotspot:
            pending = .none
            if code == 0 {
                wifiHotspotEnabled = true
                phase = "相机 Wi-Fi 热点已成功开启！正在读取热点 SSID 和密码..."
                note("相机 Wi-Fi 热点开启成功，向相机请求最新状态以获取 Wi-Fi 密码。")
                refreshStatus()
            } else {
                fail("开启相机 Wi-Fi 热点失败，状态码 \(code)")
            }
        case .startCapture:
            pending = .none
            isCapturing = false
            if code == 0 {
                if currentCaptureType == 1 {
                    phase = "📸 拍照成功！正在保存..."
                    note("拍照指令执行成功")
                    // Flash / Shutter feedback and refresh status & media
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.refreshStatus()
                        self?.listMediaPage(startIndex: 0)
                    }
                } else {
                    isRecording = true
                    phase = "🔴 录像已开始"
                    note("开始录像指令执行成功")
                    recordingDurationSeconds = 0
                    startRecordingTimer()
                    refreshStatus()
                }
            } else {
                fail("触发快门失败，状态码 \(code)")
            }
        case .stopCapture:
            pending = .none
            isCapturing = false
            if code == 0 {
                isRecording = false
                stopRecordingTimer()
                phase = "⏹ 录像已停止，文件已写入 SD 卡"
                note("停止录像指令执行成功")
                refreshStatus()
            } else {
                fail("停止录像失败，状态码 \(code)")
            }
        case .startViewfinder:
            pending = .none
            if code == 0 {
                viewfinderStateText = "取景会话已建立 (WebRTC 应答已收到)"
                note("实时取景会话创建成功")
            } else {
                viewfinderStateText = "取景开启失败：状态码 \(code)"
                note("实时取景请求被相机拒绝：\(code)")
            }
        case .stopViewfinder:
            pending = .none
            viewfinderStateText = "实时取景已停止"
            note("实时取景已停止")
        case .none: note("收到非预期响应，状态码 \(code)")
        }
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDurationSeconds += 1
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    func setCaptureModeType(_ type: UInt64) {
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected else {
            fail("请先连接相机")
            return
        }
        currentCaptureType = type
        let modeName = (type == 1) ? "拍照" : (type == 0 ? "视频" : "直播")
        phase = "正在切换相机模式至【\(modeName)】..."
        note("设置拍摄模式：\(modeName) (type=\(type))")
        do {
            try send(CameraProtocol.setCaptureTypeConfig(type, skew: skew), encrypted: true, pending: .configure)
        } catch {
            fail("切换拍摄模式失败：\(error.localizedDescription)")
        }
    }

    func triggerShutter() {
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected else {
            fail("相机未连接或当前正处于其他操作中")
            return
        }
        isCapturing = true
        if isRecording {
            phase = "正在停止录像..."
            note("发送停止录像指令 (STOP_CAPTURE)")
            do {
                try send(CameraProtocol.stopCaptureRequest(skew: skew), encrypted: true, pending: .stopCapture)
            } catch {
                isCapturing = false
                fail("发送停止录像指令失败：\(error.localizedDescription)")
            }
        } else {
            let actionName = (currentCaptureType == 1) ? "拍照" : "录像"
            phase = "正在触发相机\(actionName)..."
            note("发送触发快门指令 (START_CAPTURE)，当前模式：\(actionName)")
            do {
                try send(CameraProtocol.startCaptureRequest(skew: skew), encrypted: true, pending: .startCapture)
            } catch {
                isCapturing = false
                fail("发送触发快门指令失败：\(error.localizedDescription)")
            }
        }
    }

    func enableHotspot() {
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected else { fail("请先建立蓝牙连接"); return }
        do {
            phase = "正在指令相机开启 Wi-Fi 热点..."
            note("发送开启 Wi-Fi 热点指令 (ENABLE_HOTSPOT)")
            try send(CameraProtocol.wifiHotspotConfig(enable: true, skew: skew), encrypted: true, pending: .enableHotspot)
        } catch { fail("开启相机 Wi-Fi 热点指令发送失败：\(error.localizedDescription)") }
    }

    func connectWifi() {
        guard !hotspotSSID.isEmpty, !hotspotPassword.isEmpty else {
            fail("未获取到相机的 Wi-Fi 热点名称和密码，请先点击【开启相机 Wi-Fi 热点】")
            return
        }
        phase = "正在尝试自动连接 Wi-Fi 热点 \(hotspotSSID)..."
        note("使用 macOS 系统服务发起自动 Wi-Fi 连接：SSID=\(hotspotSSID)")

        let ssid = hotspotSSID
        let pwd = hotspotPassword
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            task.arguments = ["-setairportnetwork", "en0", ssid, pwd]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                Task { @MainActor in
                    if task.terminationStatus == 0 {
                        self.phase = "🎉 已成功自动加入 Wi-Fi 热点 \(self.hotspotSSID)！"
                        self.note("系统网络已联通相机热点 (en0)")
                    } else {
                        self.phase = "自动连接提示：\(output.isEmpty ? "连接失败" : output)"
                        self.note("networksetup 输出：\(output)。已同时复制密码到剪贴板，可手动连接。")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(self.hotspotPassword, forType: .string)
                    }
                }
            } catch {
                Task { @MainActor in
                    self.phase = "自动 Wi-Fi 连接指令执行失败：\(error.localizedDescription)"
                    self.note("执行 networksetup 异常：\(error.localizedDescription)")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.hotspotPassword, forType: .string)
                }
            }
        }
    }

    func listMedia() {
        listMediaPage(startIndex: 0)
    }

    func listMediaPage(startIndex: Int) {
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected else { fail("请先建立安全蓝牙连接并校准时间"); return }
        mediaPageStartIndex = max(0, startIndex)
        do {
            phase = "正在读取媒体列表（第 \(mediaPageStartIndex + 1) 项起，获取 \(mediaPageSize) 项）..."
            try send(CameraProtocol.listMediaRequest(startIndex: mediaPageStartIndex, count: mediaPageSize, skew: skew), encrypted: true, pending: .listMedia)
        } catch { fail("发送媒体列表请求失败：\(error.localizedDescription)") }
    }

    func nextPage() {
        if mediaPageStartIndex + mediaPageSize < mediaTotalCount || (mediaTotalCount == 0 && !mediaList.isEmpty) {
            listMediaPage(startIndex: mediaPageStartIndex + mediaPageSize)
        }
    }

    func prevPage() {
        if mediaPageStartIndex > 0 {
            listMediaPage(startIndex: max(0, mediaPageStartIndex - mediaPageSize))
        }
    }

    private func fetchNextThumbnail() {
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected else { return }
        if let idx = mediaList.firstIndex(where: { $0.thumbnailData == nil }) {
            fetchingThumbnailForIndex = idx
            let item = mediaList[idx]
            do {
                try send(CameraProtocol.thumbnailRequest(filename: item.filename, width: 320, height: 240, skew: skew), encrypted: true, pending: .thumbnail)
            } catch { note("请求缩略图失败：\(item.filename)") }
        }
    }

    func downloadMedia(_ item: MediaItem) {
        guard let key = sharedKey else { fail("缺少共享加密密钥"); return }
        
        // Strict match to Android HttpMediaClient.java:
        // String strConcat = "/media/" + filename;
        // String url = baseUrl + strConcat;
        let cleanItemPath = item.filename.hasPrefix("/") ? String(item.filename.dropFirst()) : item.filename
        let requestPath = "/media/" + cleanItemPath
        let authHeader = CameraProtocol.computeAuthorizationHeader(method: "GET", path: requestPath, body: nil, key: key)
        let urlString = "https://\(cameraIP):\(cameraPort)\(requestPath)"
        guard let url = URL(string: urlString) else { fail("无效的 HTTPS URL: \(urlString)"); return }

        downloadProgressText = "正在从 HTTPS 通道下载 \(cleanItemPath)..."
        note("开始通过 HTTPS 通道下载媒体: \(urlString)")
        note("Auth Header: \(authHeader)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30.0
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 300.0

        let session = URLSession(configuration: config, delegate: TrustSelfSignedDelegate(), delegateQueue: .main)
        let task = session.downloadTask(with: request) { [weak self] localURL, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.downloadProgressText = "下载失败：\(error.localizedDescription)"
                    self.note("HTTPS 下载失败：\(error.localizedDescription)")
                    return
                }
                if let httpResp = response as? HTTPURLResponse {
                    self.note("HTTPS 响应状态码: \(httpResp.statusCode)")
                    if httpResp.statusCode != 200 {
                        self.downloadProgressText = "下载失败：HTTP \(httpResp.statusCode)"
                        return
                    }
                }
                guard let localURL else {
                    self.downloadProgressText = "下载失败：缺少本地文件"
                    return
                }
                do {
                    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    let fileName = (cleanItemPath as NSString).lastPathComponent
                    let targetURL = downloads.appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.moveItem(at: localURL, to: targetURL)
                    self.downloadProgressText = "✅ 已成功下载至 Downloads: \(fileName)"
                    self.note("媒体下载成功保存至: \(targetURL.path)")
                } catch {
                    self.downloadProgressText = "保存文件失败：\(error.localizedDescription)"
                    self.note("保存媒体文件失败：\(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }
    private static func frameTitle(_ raw: Data) throws -> String {
        let size = try PB(raw)
        return "\(size.optionalUInt(1) ?? 0)×\(size.optionalUInt(2) ?? 0)"
    }
    private static func videoTitle(_ raw: Data) throws -> String {
        let mode = try PB(raw)
        let dimensions = try mode.fields[1].flatMap { $0.first }.map(frameTitle) ?? "未知分辨率"
        let fps = mode.fixed64[2]?.first.map { " @ \(Double(bitPattern: $0).formatted(.number.precision(.fractionLength(0...2)))) fps" } ?? ""
        return dimensions + fps
    }
    private static func photoTitle(_ raw: Data) throws -> String {
        let mode = try PB(raw)
        return try mode.fields[1].flatMap { $0.first }.map(frameTitle) ?? "未知分辨率"
    }
    private static func decodePackedVarints(_ data: Data) throws -> [UInt64] {
        let bytes = Array(data); var index = 0; var result: [UInt64] = []
        while index < bytes.count {
            var value: UInt64 = 0; var complete = false
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw WireError.malformed }
                let byte = bytes[index]; index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { complete = true; break }
            }
            guard complete else { throw WireError.malformed }
            result.append(value)
        }
        return result
    }
    private func sendFinalize() throws {
        guard let key = privateKey else { throw WireError.crypto }
        let payload = CameraProtocol.keyExchange(publicKey: key.publicKey.x963Representation, salt: salt)
        try send(CameraProtocol.request(type: 2, payload: payload), encrypted: false, pending: .finalize)
    }
    private func fail(_ message: String) {
        phase = message
        note(message)
        if case .waitingForPhysicalConfirm = pairingStep { pairingStep = .failed(message) }
    }

}

final class TrustSelfSignedDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
