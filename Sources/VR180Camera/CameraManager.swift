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
    @Published var phase = "Waiting for Bluetooth"
    @Published var log: [String] = []
    @Published var detail = "No camera connected"
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
    @Published var pairingHint = "Set camera to pairing mode (hold shutter button until LED flashes blue/green), or select a discovered camera."
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
    @Published var viewfinderStateText = "Viewfinder Idle"
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
    private var operationName = "Setting"
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
        case .poweredOn: phase = "Bluetooth Powered On"; scan()
        case .poweredOff: phase = "Please enable Bluetooth"; pairingStep = .idle
        case .unauthorized: phase = "Please allow Bluetooth permission for this app"; pairingStep = .idle
        default: phase = "Bluetooth unavailable"; pairingStep = .idle
        }
    }
    func scan() {
        guard central.state == .poweredOn else { return }
        cameras = []; discovered = [:]
        central.scanForPeripherals(withServices: [Self.pairingService, Self.cameraService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        if PairingStore.lastCameraID != nil {
            phase = "Searching for previously paired camera..."
            pairingHint = "Searching for paired camera. To pair a new device, put it in pairing mode and tap Connect."
        } else {
            phase = "Scanning for nearby VR180 cameras..."
            pairingHint = "Ensure camera is powered on and in pairing mode (hold shutter button until LED blinks blue/green)."
        }
        note("Started scanning for VR180 services")
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "VR180 Camera"
        let id = peripheral.identifier
        discovered[id] = peripheral
        let signal = RSSI.intValue
        if let index = cameras.firstIndex(where: { $0.id == id }) {
            cameras[index].name = name; cameras[index].signal = signal
        } else {
            cameras.append(FoundCamera(id: id, name: name, signal: signal))
            cameras.sort { $0.signal > $1.signal }
        }
        note("Discovered device: \(name) (\(id.uuidString)) signal: \(signal) dBm")

        let isPairingService = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(Self.pairingService) ?? false
        let isCameraService = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(Self.cameraService) ?? false

        if self.peripheral == nil {
            if let lastID = PairingStore.lastCameraID, lastID == id {
                note("Matched saved camera identifier: \(id.uuidString). Reconnecting...")
                connect(id)
            } else if let savedKey = PairingStore.lastKey, isCameraService, !isPairingService {
                note("Discovered active VR180 Camera API service. Reconnecting with saved key: \(id.uuidString)")
                sharedKey = savedKey
                reconnectingWithSavedKey = true
                connect(id)
            } else if let savedKey = PairingStore.lastKey, let lastPub = PairingStore.savedPublicKey, !lastPub.isEmpty {
                for (_, serviceData) in (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]) {
                    if serviceData.count >= 8 && lastPub.prefix(8) == serviceData.prefix(8) {
                        note("Service data matched saved camera public key prefix! Reconnecting: \(id.uuidString)")
                        sharedKey = savedKey
                        reconnectingWithSavedKey = true
                        connect(id)
                        break
                    }
                }
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
            phase = "Reconnecting to paired camera..."; pairingHint = "Loaded saved pairing key, verifying secure channel..."
        } else {
            phase = "Connecting to \(p.name ?? "Camera")..."; pairingHint = "BLE connection established, preparing key handshake..."
        }
        central.connect(p)
    }
    private func resetSession() {
        requestCharacteristic = nil; responseCharacteristic = nil; statusCharacteristic = nil
        chunks = []; incoming = Data(); pending = .none
        sharedKey = nil; privateKey = nil; salt = Data(); clockSkew = nil
        paired = false; statusReady = false; switchingAfterPairing = false; timeSyncAttempted = false; capabilitiesFetched = false; supportedISO = []; reconnectingWithSavedKey = false
        startPairingWhenNotifying = false; readStatusWhenNotifying = false
        videoModes = []; photoModes = []; liveModes = []; supportsFlatColor = false; supportsAudio = false; currentLiveMode = nil; maxAudioVolume = nil; detail = "Waiting for connection"
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phase = "Connected to BLE, discovering services..."; note("BLE connected successfully")
        peripheral.discoverServices([Self.pairingService, Self.cameraService])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { fail("Connection failed: \(error?.localizedDescription ?? "Unknown error")") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        phase = "Camera disconnected"; statusReady = false; paired = false; pending = .none
        pairingStep = .idle
        responseTimeout?.cancel(); requestCharacteristic = nil; responseCharacteristic = nil; chunks = []
        note("Camera disconnected: \(error?.localizedDescription ?? "Clean disconnect")")
        self.peripheral = nil
        scan()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("Failed to discover services: \(error.localizedDescription)"); return }
        let services = peripheral.services ?? []
        let chosen: CBService?
        if sharedKey != nil { chosen = services.first(where: { $0.uuid == Self.cameraService }) ?? services.first(where: { $0.uuid == Self.pairingService }) }
        else { chosen = services.first(where: { $0.uuid == Self.pairingService }) ?? services.first(where: { $0.uuid == Self.cameraService }) }
        guard let chosen else { fail("VR180 service not found"); return }
        serviceUUID = chosen.uuid; note("Found service \(chosen.uuid.uuidString)")
        peripheral.discoverCharacteristics([Self.requestUUID, Self.responseUUID, Self.statusUUID], for: chosen)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail("Failed to discover characteristics: \(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.requestUUID:
                requestCharacteristic = c
                note("Request characteristic properties: write=\(c.properties.contains(.write)), withoutResponse=\(c.properties.contains(.writeWithoutResponse))")
                writeWithoutResponse = !c.properties.contains(.write) && c.properties.contains(.writeWithoutResponse)
            case Self.responseUUID: responseCharacteristic = c; peripheral.setNotifyValue(true, for: c)
            case Self.statusUUID: statusCharacteristic = c; peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        guard requestCharacteristic != nil, responseCharacteristic != nil else { fail("Missing request or response characteristic"); return }
        if switchingAfterPairing {
            switchingAfterPairing = false; phase = "Switched to API service"; note("Camera API service ready"); readStatusWhenNotifying = true
        } else if service.uuid == Self.cameraService, sharedKey != nil {
            phase = "Verifying saved key..."; note("Connected directly to Camera API service, verifying saved key")
            readStatusWhenNotifying = true
        } else if service.uuid == Self.pairingService {
            if sharedKey != nil { sharedKey = nil; reconnectingWithSavedKey = false; note("Switched to pairing service, initiating fresh pair") }
            phase = "Ready, initiating pairing..."; pairingHint = "Communication channel ready, automatically initiating key exchange..."
            note("Pairing service ready, preparing pairing request")
            startPairingWhenNotifying = true
        } else {
            phase = "Protocol channel established"; detail = "Characteristics discovered"
            note("Request and response characteristics ready")
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("Failed to subscribe to notifications: \(error.localizedDescription)") }
        else {
            note("Notification subscription confirmed: \(characteristic.uuid.uuidString)")
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
            phase = "Step 1/3: Exchanging keys..."; detail = "Exchanging ECDH P-256 public key and salt..."
            try send(CameraProtocol.request(type: 1, payload: payload), encrypted: false, pending: .initiate)
        } catch { fail("Failed to initiate pairing: \(error.localizedDescription)") }
    }
    func rePair() {
        PairingStore.forgetLastCamera()
        pairingStep = .idle
        pairingHint = "Cleared saved key. Please set camera to pairing mode and reconnect."
        if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
        else { peripheral = nil; scan() }
    }
    func refreshStatus() {
        guard sharedKey != nil, pending == .none, peripheral?.state == .connected else { return }
        do { try send(CameraProtocol.request(type: 0, header: CameraProtocol.header()), encrypted: true, pending: .status) }
        catch { fail("Failed to read status: \(error.localizedDescription)") }
    }
    func setISO() {
        guard let iso = UInt64(isoText), iso <= 25600 else { fail("Please enter a valid ISO value"); return }
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected, capabilitiesFetched else { fail("Please connect and fetch capabilities first"); return }
        guard supportedISO.contains(iso) else { fail("ISO \(iso) is not in supported list: \(supportedISO)"); return }
        do { try configure(CameraProtocol.isoConfig(iso, skew: skew), name: "ISO") }
        catch { fail("Failed to set ISO: \(error.localizedDescription)") }
    }
    func setVideoMode() { setMode(videoModes, selected: selectedVideo, field: 11, name: "Video Mode") }
    func setPhotoMode() { setMode(photoModes, selected: selectedPhoto, field: 12, name: "Photo Mode") }
    func setLiveMode() {
        guard liveModes.indices.contains(selectedLive), let original = currentLiveMode, let skew = clockSkew else { fail("Live mode configuration unavailable"); return }
        do {
            let live = try PB(original)
            var updated = PB.bytes(1, liveModes[selectedLive].raw)
            for field in [2, 3] { for value in live.fields[field] ?? [] { updated.append(PB.bytes(field, value)) } }
            try configure(CameraProtocol.captureConfig(PB.bytes(13, updated), skew: skew), name: "Live Mode")
        } catch { fail("Failed to set live mode: \(error.localizedDescription)") }
    }
    func setFlatColor() {
        guard supportsFlatColor, let skew = clockSkew else { fail("Camera does not support flat color profile"); return }
        do { try configure(CameraProtocol.captureConfig(PB.number(9, flatColor ? 1 : 0), skew: skew), name: "Flat Color") }
        catch { fail("Failed to set flat color: \(error.localizedDescription)") }
    }
    func setShutterMute() {
        guard supportsAudio, let max = maxAudioVolume, let skew = clockSkew else { fail("Camera does not support audio configuration"); return }
        do { try configure(CameraProtocol.audioConfig(volume: shutterMuted ? 0 : max, skew: skew), name: "Shutter Sound") }
        catch { fail("Failed to set shutter sound: \(error.localizedDescription)") }
    }
    private func setMode(_ choices: [ModeChoice], selected: Int, field: Int, name: String) {
        guard choices.indices.contains(selected), let skew = clockSkew else { fail("\(name) unavailable"); return }
        do { try configure(CameraProtocol.captureConfig(PB.bytes(field, choices[selected].raw), skew: skew), name: name) }
        catch { fail("Failed to set \(name): \(error.localizedDescription)") }
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
            self.fail("Timeout waiting for camera response; please check camera confirmation or retry pairing")
            self.pending = .none
        }
        responseTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        let framed = CameraProtocol.frame(body)
        chunks = stride(from: 0, to: framed.count, by: 20).map { Data(framed[$0..<min($0+20, framed.count)]) }
        note("Sending \(request.count) byte request across \(chunks.count) BLE chunks")
        if writeWithoutResponse { sendNextWithoutResponse() }
        else if !chunks.isEmpty { p.writeValue(chunks.removeFirst(), for: c, type: .withResponse) }
    }
    private func sendNextWithoutResponse() {
        guard let p = peripheral, let c = requestCharacteristic, !chunks.isEmpty else { return }
        guard p.canSendWriteWithoutResponse else { return }
        p.writeValue(chunks.removeFirst(), for: c, type: .withoutResponse)
        if !chunks.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.sendNextWithoutResponse() } }
        else { note("All BLE chunks written") }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { sendNextWithoutResponse() }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("BLE write failed: \(error.localizedDescription)"); pending = .none; return }
        note("BLE chunk written; \(chunks.count) remaining")
        if !chunks.isEmpty { peripheral.writeValue(chunks.removeFirst(), for: characteristic, type: .withResponse) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("Notification read failed: \(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Self.statusUUID { note("Received status notification (\(value.count) bytes)"); return }
        guard characteristic.uuid == Self.responseUUID else { return }
        note("Received response notification: \(value.count) bytes")
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
        } catch { fail("Failed to parse camera response: \(error.localizedDescription)"); pending = .none }
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
            phase = "Step 2/3: Press the camera shutter button!"
            pairingHint = "🔔 Action Required: Press the physical shutter button on the camera within 20 seconds to confirm pairing!"
            note("Derived key; waiting for user confirmation on physical camera...")
            try sendFinalize()
        case .finalize:
            note("Finalize response code: \(code)")
            if code == 0 {
                pending = .none; paired = true; phase = "Step 3/3: Pairing Complete"; detail = "Pairing handshake successful, switching to API channel"
                pairingStep = .connected
                note("Physical button confirmed on camera; pairing established")
                if let id = peripheral?.identifier, let key = sharedKey {
                    note(PairingStore.save(key, for: id, publicKey: peerPublicKey) ? "Pairing key persisted to Keychain; will auto-reconnect" : "Pairing succeeded, but Keychain save failed")
                }
                pairingHint = "🎉 Pairing successful! Key saved to Keychain for automatic reconnection."
                if let p = peripheral, let api = p.services?.first(where: { $0.uuid == Self.cameraService }) {
                    switchingAfterPairing = true; requestCharacteristic = nil; responseCharacteristic = nil
                    p.discoverCharacteristics([Self.requestUUID, Self.responseUUID, Self.statusUUID], for: api)
                } else { fail("Pairing complete but Camera API service not found; please reconnect") }
            }
            else if let deadline = finalizeDeadline, Date() < deadline {
                pending = .none
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in try? self?.sendFinalize() }
            } else {
                pending = .none
                pairingStep = .failed("Timed out waiting for physical button confirmation")
                fail("Pairing failed: Camera shutter button was not pressed within 20 seconds")
            }
        case .status:
            guard code == 0 else { pending = .none; fail("Camera rejected status request, code \(code)"); return }
            if reconnectingWithSavedKey { reconnectingWithSavedKey = false; paired = true; pairingStep = .connected; note("Saved key verified, skipping button confirmation") }
            let camera = try PB(response.data(3))
            if let timestamp = camera.optionalUInt(8) {
                let skew = Int64(bitPattern: timestamp) &- Int64(Date().timeIntervalSince1970 * 1000)
                clockSkew = skew
                PairingStore.lastClockSkew = skew
                note("Camera clock skew: \(skew) ms")
            }
            var lines: [String] = []
            if let captureData = camera.fields[5]?.first {
                let capture = try PB(captureData)
                if let iso = capture.optionalUInt(8) { isoText = String(iso); lines.append("ISO: \(iso)") }
                if let flat = capture.optionalUInt(9) { flatColor = flat == 1; lines.append("Flat Color: \(flatColor ? "On" : "Off")") }
                if let raw = capture.fields[11]?.first, let index = videoModes.firstIndex(where: { $0.raw == raw }) { selectedVideo = index; lines.append("Video: \(videoModes[index].title)") }
                if let raw = capture.fields[12]?.first, let index = photoModes.firstIndex(where: { $0.raw == raw }) { selectedPhoto = index; lines.append("Photo: \(photoModes[index].title)") }
                if let raw = capture.fields[13]?.first {
                    currentLiveMode = raw
                    let live = try PB(raw)
                    if let video = live.fields[1]?.first, let index = liveModes.firstIndex(where: { $0.raw == video }) { selectedLive = index; lines.append("Live: \(liveModes[index].title)") }
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
                    lines.append("Shutter Sound: \(shutterMuted ? "Muted" : "On")")
                }
            }
            note("Camera status field keys: \(camera.fields.keys.sorted())")
            if let httpData = camera.fields[6]?.first, let http = try? PB(httpData) {
                note("Field 6 (HttpServerStatus) subfields: \(http.fields.keys.sorted())")
                if let hostData = http.fields[2]?.first, let host = String(data: hostData, encoding: .utf8), !host.isEmpty {
                    cameraIP = host
                    note("Obtained IP from camera: \(host)")
                }
                if let port = http.optionalUInt(3) {
                    cameraPort = String(port)
                    note("Obtained port from camera: \(port)")
                }
            }
            if let apData = camera.fields[11]?.first {
                if let ap = try? PB(apData) {
                    note("Field 11 subfields: \(ap.fields.keys.sorted())")
                    if let sData = ap.fields[1]?.first, let s = String(data: sData, encoding: .utf8) {
                        hotspotSSID = s
                    }
                    if let pData = ap.fields[2]?.first, let p = String(data: pData, encoding: .utf8) {
                        hotspotPassword = p
                    }
                }
            }
            if !hotspotSSID.isEmpty || !hotspotPassword.isEmpty {
                note("🔑 Camera Wi-Fi Hotspot SSID: [\(hotspotSSID)], Password: [\(hotspotPassword)]")
            }
            detail = lines.joined(separator: " · "); pending = .none
            note("Status refreshed: \(detail)")
            if let skew = clockSkew, abs(skew) > 10_000, !timeSyncAttempted {
                timeSyncAttempted = true; phase = "Synchronizing camera clock..."
                try send(CameraProtocol.timeConfig(skew: skew), encrypted: true, pending: .syncTime)
            } else if !capabilitiesFetched, let skew = clockSkew {
                phase = "Fetching camera capabilities..."
                try send(CameraProtocol.capabilitiesRequest(skew: skew), encrypted: true, pending: .capabilities)
            } else { statusReady = capabilitiesFetched; phase = "Camera online, ready for controls" }
        case .syncTime:
            pending = .none
            guard code == 0 else { fail("Camera time sync failed, code \(code)"); return }
            note("Camera clock synchronized successfully")
            clockSkew = 0
            refreshStatus()
        case .capabilities:
            pending = .none
            guard code == 0 else { fail("Failed to read camera capabilities, code \(code)"); return }
            let caps = try PB(response.data(7))
            var values = caps.integers[11] ?? []
            for packed in caps.fields[11] ?? [] { values += try Self.decodePackedVarints(packed) }
            supportedISO = Array(Set(values)).sorted(); capabilitiesFetched = true
            videoModes = try (caps.fields[4] ?? []).enumerated().map { ModeChoice(id: $0.offset, title: try Self.videoTitle($0.element), raw: $0.element) }
            photoModes = try (caps.fields[5] ?? []).enumerated().map { ModeChoice(id: $0.offset, title: try Self.photoTitle($0.element), raw: $0.element) }
            liveModes = try (caps.fields[6] ?? []).enumerated().map { ModeChoice(id: $0.offset, title: try Self.videoTitle($0.element), raw: $0.element) }
            supportsFlatColor = caps.optionalUInt(12) == 1
            statusReady = true; phase = "Camera controls ready"
            detail += " · Supported ISO: \(supportedISO.map(String.init).joined(separator: ", "))"
            note("Camera capabilities: \(videoModes.count) video, \(photoModes.count) photo, \(liveModes.count) live modes; flat color \(supportsFlatColor ? "supported" : "unsupported"); ISO \(supportedISO)")
            refreshStatus()
        case .configure:
            pending = .none
            if code == 0 { phase = "\(operationName) applied successfully"; note("Camera confirmed \(operationName); refreshing status"); refreshStatus() }
            else { fail("Camera rejected \(operationName) setting, code \(code)"); refreshStatus() }
        case .listMedia:
            pending = .none
            guard code == 0 else { fail("Failed to fetch media list, code \(code)"); return }
            let mediaResp = try PB(response.data(8))
            var items: [MediaItem] = []
            for mediaData in mediaResp.fields[3] ?? [] {
                let m = try PB(mediaData)
                let name = (try? m.data(1)).flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown file"
                let size = m.optionalUInt(2) ?? 0
                let timestamp = m.optionalUInt(3) ?? 0
                let duration = m.optionalUInt(4) ?? 0
                let width = m.optionalUInt(7) ?? 0
                let height = m.optionalUInt(8) ?? 0
                items.append(MediaItem(id: name, filename: name, size: size, timestamp: timestamp, duration: duration, width: width, height: height))
            }
            mediaTotalCount = Int(mediaResp.optionalUInt(2) ?? UInt64(items.count))
            mediaList = items
            phase = "Media list fetched (\(items.count) on this page, \(mediaTotalCount) total)"
            note("Loaded items \(mediaPageStartIndex + 1)~\(mediaPageStartIndex + items.count) of \(mediaTotalCount)")
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
                    note("Thumbnail loaded: \(mediaList[fetchingThumbnailForIndex].filename) (\(validData.count) bytes)")
                } else {
                    note("Thumbnail payload was empty: \(mediaList[fetchingThumbnailForIndex].filename)")
                }
            } else {
                note("Thumbnail request returned non-zero code: \(code)")
            }
            fetchNextThumbnail()
        case .enableHotspot:
            pending = .none
            if code == 0 {
                wifiHotspotEnabled = true
                phase = "Camera Wi-Fi hotspot enabled! Reading SSID and password..."
                note("Camera Wi-Fi hotspot enabled successfully; querying latest status for credentials.")
                refreshStatus()
            } else {
                fail("Failed to enable camera Wi-Fi hotspot, code \(code)")
            }
        case .startCapture:
            pending = .none
            isCapturing = false
            if code == 0 {
                if currentCaptureType == 1 {
                    phase = "📸 Photo captured! Saving..."
                    note("Photo capture command succeeded")
                    // Flash / Shutter feedback and refresh status & media
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.refreshStatus()
                        self?.listMediaPage(startIndex: 0)
                    }
                } else {
                    isRecording = true
                    phase = "🔴 Recording started"
                    note("Start recording command succeeded")
                    recordingDurationSeconds = 0
                    startRecordingTimer()
                    refreshStatus()
                }
            } else {
                fail("Shutter trigger failed, code \(code)")
            }
        case .stopCapture:
            pending = .none
            isCapturing = false
            if code == 0 {
                isRecording = false
                stopRecordingTimer()
                phase = "⏹ Recording stopped, file written to SD card"
                note("Stop recording command succeeded")
                refreshStatus()
            } else {
                fail("Stop recording failed, code \(code)")
            }
        case .startViewfinder:
            pending = .none
            if code == 0 {
                viewfinderStateText = "Viewfinder session established (WebRTC Answer received)"
                note("Realtime viewfinder session created successfully")
            } else {
                viewfinderStateText = "Failed to start viewfinder: code \(code)"
                note("Realtime viewfinder request rejected by camera: \(code)")
            }
        case .stopViewfinder:
            pending = .none
            viewfinderStateText = "Live viewfinder stopped"
            note("Live viewfinder stopped")
        case .none: note("Unexpected response received, code \(code)")
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
            fail("Please connect camera first")
            return
        }
        currentCaptureType = type
        let modeName = (type == 1) ? "Photo" : (type == 0 ? "Video" : "Live")
        phase = "Switching camera mode to [\(modeName)]..."
        note("Set capture mode: \(modeName) (type=\(type))")
        do {
            try send(CameraProtocol.setCaptureTypeConfig(type, skew: skew), encrypted: true, pending: .configure)
        } catch {
            fail("Failed to switch capture mode: \(error.localizedDescription)")
        }
    }

    func triggerShutter() {
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected else {
            fail("Camera is not connected or another operation is in progress")
            return
        }
        isCapturing = true
        if isRecording {
            phase = "Stopping recording..."
            note("Sending STOP_CAPTURE command")
            do {
                try send(CameraProtocol.stopCaptureRequest(skew: skew), encrypted: true, pending: .stopCapture)
            } catch {
                isCapturing = false
                fail("Failed to send stop recording command: \(error.localizedDescription)")
            }
        } else {
            let actionName = (currentCaptureType == 1) ? "Photo" : "Recording"
            phase = "Triggering camera \(actionName)..."
            note("Sending START_CAPTURE command, current mode: \(actionName)")
            do {
                try send(CameraProtocol.startCaptureRequest(skew: skew), encrypted: true, pending: .startCapture)
            } catch {
                isCapturing = false
                fail("Failed to trigger shutter: \(error.localizedDescription)")
            }
        }
    }

    func enableHotspot() {
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected else { fail("Please establish BLE connection first"); return }
        do {
            phase = "Commanding camera to enable Wi-Fi hotspot..."
            note("Sending ENABLE_HOTSPOT command")
            try send(CameraProtocol.wifiHotspotConfig(enable: true, skew: skew), encrypted: true, pending: .enableHotspot)
        } catch { fail("Failed to send enable hotspot command: \(error.localizedDescription)") }
    }

    func connectWifi() {
        guard !hotspotSSID.isEmpty, !hotspotPassword.isEmpty else {
            fail("Camera Wi-Fi credentials not found. Please click 'Enable Camera Wi-Fi Hotspot' first.")
            return
        }
        phase = "Attempting to auto-connect to Wi-Fi hotspot \(hotspotSSID)..."
        note("Initiating auto Wi-Fi connection via macOS service: SSID=\(hotspotSSID)")

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
                        self.phase = "🎉 Successfully joined Wi-Fi hotspot \(self.hotspotSSID)!"
                        self.note("Connected to camera Wi-Fi network (en0)")
                    } else {
                        self.phase = "Wi-Fi connection result: \(output.isEmpty ? "Connection failed" : output)"
                        self.note("networksetup output: \(output). Password copied to clipboard for manual join.")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(self.hotspotPassword, forType: .string)
                    }
                }
            } catch {
                Task { @MainActor in
                    self.phase = "Wi-Fi connection command error: \(error.localizedDescription)"
                    self.note("Failed to run networksetup: \(error.localizedDescription)")
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
        guard let skew = clockSkew, pending == .none, peripheral?.state == .connected else { fail("Please establish BLE connection and sync clock first"); return }
        mediaPageStartIndex = max(0, startIndex)
        do {
            phase = "Fetching media list (starting from item \(mediaPageStartIndex + 1), count \(mediaPageSize))..."
            try send(CameraProtocol.listMediaRequest(startIndex: mediaPageStartIndex, count: mediaPageSize, skew: skew), encrypted: true, pending: .listMedia)
        } catch { fail("Failed to send list media request: \(error.localizedDescription)") }
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
            } catch { note("Failed to request thumbnail: \(item.filename)") }
        }
    }

    func downloadMedia(_ item: MediaItem) {
        guard let key = sharedKey else { fail("Missing shared encryption key"); return }
        
        let cleanItemPath = item.filename.hasPrefix("/") ? String(item.filename.dropFirst()) : item.filename
        let requestPath = "/media/" + cleanItemPath
        let authHeader = CameraProtocol.computeAuthorizationHeader(method: "GET", path: requestPath, body: nil, key: key)
        let urlString = "https://\(cameraIP):\(cameraPort)\(requestPath)"
        guard let url = URL(string: urlString) else { fail("Invalid HTTPS URL: \(urlString)"); return }

        downloadProgressText = "Downloading \(cleanItemPath) via HTTPS..."
        note("Initiated HTTPS download: \(urlString)")
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
                    self.downloadProgressText = "Download failed: \(error.localizedDescription)"
                    self.note("HTTPS download failed: \(error.localizedDescription)")
                    return
                }
                if let httpResp = response as? HTTPURLResponse {
                    self.note("HTTPS status code: \(httpResp.statusCode)")
                    if httpResp.statusCode != 200 {
                        self.downloadProgressText = "Download failed: HTTP \(httpResp.statusCode)"
                        return
                    }
                }
                guard let localURL else {
                    self.downloadProgressText = "Download failed: Missing local file"
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
                    self.downloadProgressText = "✅ Successfully saved to Downloads: \(fileName)"
                    self.note("Media file saved to: \(targetURL.path)")
                } catch {
                    self.downloadProgressText = "Failed to save file: \(error.localizedDescription)"
                    self.note("Failed to save media file: \(error.localizedDescription)")
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
        let dimensions = try mode.fields[1].flatMap { $0.first }.map(frameTitle) ?? "Unknown resolution"
        let fps = mode.fixed64[2]?.first.map { " @ \(Double(bitPattern: $0).formatted(.number.precision(.fractionLength(0...2)))) fps" } ?? ""
        return dimensions + fps
    }
    private static func photoTitle(_ raw: Data) throws -> String {
        let mode = try PB(raw)
        return try mode.fields[1].flatMap { $0.first }.map(frameTitle) ?? "Unknown resolution"
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
