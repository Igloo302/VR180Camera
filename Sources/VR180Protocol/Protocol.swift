import Foundation
import CryptoKit

public enum WireError: Error, LocalizedError {
    case malformed, missingField(Int), crypto
    public var errorDescription: String? {
        switch self {
        case .malformed: return "Protobuf 数据格式不正确"
        case .missingField(let n): return "响应缺少字段 \(n)"
        case .crypto: return "加密或解密失败"
        }
    }
}

public struct PB {
    public private(set) var fields: [Int: [Data]] = [:]
    public private(set) var integers: [Int: [UInt64]] = [:]
    public private(set) var fixed64: [Int: [UInt64]] = [:]
    public init(_ data: Data) throws {
        let bytes = Array(data); var i = 0
        while i < bytes.count {
            let tag = try Self.readVarint(bytes, &i)
            let number = Int(tag >> 3); guard number > 0 else { throw WireError.malformed }
            switch tag & 7 {
            case 0: integers[number, default: []].append(try Self.readVarint(bytes, &i))
            case 1:
                guard i + 8 <= bytes.count else { throw WireError.malformed }
                var value: UInt64 = 0
                for shift in 0..<8 { value |= UInt64(bytes[i + shift]) << (shift * 8) }
                fixed64[number, default: []].append(value); i += 8
            case 2:
                let length = try Self.readVarint(bytes, &i)
                guard length <= UInt64(bytes.count - i) else { throw WireError.malformed }
                fields[number, default: []].append(Data(bytes[i..<i+Int(length)])); i += Int(length)
            case 5: guard i + 4 <= bytes.count else { throw WireError.malformed }; i += 4
            default: throw WireError.malformed
            }
        }
    }
    public func data(_ n: Int) throws -> Data { guard let value = fields[n]?.first else { throw WireError.missingField(n) }; return value }
    public func uint(_ n: Int) throws -> UInt64 { guard let value = integers[n]?.first else { throw WireError.missingField(n) }; return value }
    public func optionalUInt(_ n: Int) -> UInt64? { integers[n]?.first }
    public static func varint(_ value: UInt64) -> Data {
        var v = value; var result = Data()
        while v >= 0x80 { result.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        result.append(UInt8(v)); return result
    }
    public static func number(_ field: Int, _ value: UInt64) -> Data { var d = varint(UInt64(field << 3)); d.append(varint(value)); return d }
    public static func bytes(_ field: Int, _ value: Data) -> Data { var d = varint(UInt64((field << 3) | 2)); d.append(varint(UInt64(value.count))); d.append(value); return d }
    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < bytes.count else { throw WireError.malformed }
            let byte = bytes[index]; index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
        }
        throw WireError.malformed
    }
}

public enum CameraProtocol {
    public static func request(type: UInt64, header: Data? = nil, payload: Data? = nil) -> Data {
        var d = PB.number(1, type)
        if let header { d.append(PB.bytes(2, header)) }
        if let payload { d.append(PB.bytes(type == 3 ? 4 : 3, payload)) }
        return d
    }
    public static func header(clockSkew: Int64? = nil) -> Data {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var d = PB.number(2, UInt64(now))
        if let clockSkew { d.append(PB.number(1, UInt64(now + 60_000 + clockSkew))) }
        return d
    }
    public static func keyExchange(publicKey: Data, salt: Data) -> Data {
        var d = PB.bytes(1, publicKey); d.append(PB.bytes(2, salt)); return d
    }
    public static func timeConfig(skew: Int64) -> Data {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var time = PB.number(1, UInt64(now))
        time.append(PB.bytes(2, Data(TimeZone.current.identifier.utf8)))
        return request(type: 3, header: header(clockSkew: skew), payload: PB.bytes(5, time))
    }
    public static func capabilitiesRequest(skew: Int64) -> Data {
        request(type: 6, header: header(clockSkew: skew))
    }
    public static func isoConfig(_ iso: UInt64, skew: Int64) -> Data {
        captureConfig(PB.number(8, iso), skew: skew)
    }
    public static func captureConfig(_ capture: Data, skew: Int64) -> Data {
        request(type: 3, header: header(clockSkew: skew), payload: PB.bytes(1, capture))
    }
    public static func audioConfig(volume: UInt64, skew: Int64) -> Data {
        request(type: 3, header: header(clockSkew: skew), payload: PB.bytes(9, PB.number(1, volume)))
    }
    public static func frame(_ bytes: Data) -> Data {
        var result = Data(); var previous: UInt8? = nil
        for byte in bytes {
            if previous == 0 && (byte == 0 || byte == 1) { result.append(1) }
            result.append(byte); previous = byte
        }
        if result.last == 0 { result.append(1) }
        result.append(contentsOf: [0, 0]); return result
    }
    public static func unframe(_ bytes: Data) throws -> Data {
        guard bytes.count >= 2, bytes.suffix(2) == Data([0, 0]) else { throw WireError.malformed }
        let raw = Array(bytes.dropLast(2)); var output = Data(); var i = 0
        while i < raw.count { output.append(raw[i]); if raw[i] == 0 && i + 1 < raw.count && raw[i+1] == 1 { i += 1 }; i += 1 }
        return output
    }
    public static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw WireError.crypto }
        var result = Data([1]); result.append(combined); return result
    }
    public static func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        guard ciphertext.first == 1 else { throw WireError.crypto }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext.dropFirst()), using: key)
    }
    public static func deriveKey(privateKey: P256.KeyAgreement.PrivateKey, peer: Data, ownSalt: Data, peerSalt: Data) throws -> SymmetricKey {
        guard ownSalt.count == peerSalt.count else { throw WireError.crypto }
        let cameraPublic = try P256.KeyAgreement.PublicKey(x963Representation: peer)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: cameraPublic)
        let salt = Data(zip(ownSalt, peerSalt).map { $0 ^ $1 })
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("ENCRYPTION".utf8), outputByteCount: 32)
    }
    public static func listMediaRequest(startIndex: Int = 0, count: Int = 20, skew: Int64) -> Data {
        var req = PB.number(1, UInt64(startIndex))
        req.append(PB.number(2, UInt64(count)))
        var d = PB.number(1, 8) // RequestType.LIST_MEDIA = 8
        d.append(PB.bytes(2, header(clockSkew: skew)))
        d.append(PB.bytes(6, req)) // field 6 = list_media_request
        return d
    }
    public static func wifiHotspotConfig(enable: Bool, skew: Int64) -> Data {
        var channelPref = PB.number(1, 1) // client_supports_5ghz = true
        channelPref.append(PB.number(2, 1)) // client_prefers_5ghz = true
        channelPref.append(PB.number(3, 0)) // client_preferred_channel = 0
        var hotspot = PB.number(1, enable ? 1 : 0)
        hotspot.append(PB.bytes(2, channelPref))
        let config = PB.bytes(7, hotspot) // field 7 = wifi_hotspot_configuration
        return request(type: 3, header: header(clockSkew: skew), payload: config)
    }
    public static func thumbnailRequest(filename: String, width: Int = 320, height: Int = 240, skew: Int64) -> Data {
        var req = PB.bytes(1, Data(filename.utf8))
        req.append(PB.number(2, UInt64(width)))
        req.append(PB.number(3, UInt64(height)))
        var d = PB.number(1, 9) // RequestType.GET_THUMBNAIL = 9
        d.append(PB.bytes(2, header(clockSkew: skew)))
        d.append(PB.bytes(7, req)) // field 7 = thumbnail_request (CameraApiRequest field 7)
        return d
    }
    public static func startCaptureRequest(skew: Int64) -> Data {
        request(type: 11, header: header(clockSkew: skew)) // RequestType.START_CAPTURE = 11
    }
    public static func stopCaptureRequest(skew: Int64) -> Data {
        request(type: 12, header: header(clockSkew: skew)) // RequestType.STOP_CAPTURE = 12
    }
    public static func setCaptureTypeConfig(_ captureType: UInt64, skew: Int64) -> Data {
        // CaptureMode (field 5 in ConfigurationRequest, RequestType.CONFIGURE = 3)
        // CaptureMode.active_capture_type is field 15 (value: 0=VIDEO, 1=PHOTO, 2=LIVE)
        let captureMode = PB.number(15, captureType)
        let configReq = PB.bytes(5, captureMode)
        return request(type: 3, header: header(clockSkew: skew), payload: configReq)
    }
    public static func startWebRtcRequest(sessionName: String, sdpOffer: String, iceCandidates: [(mid: String, mline: Int, sdp: String)], skew: Int64) -> Data {
        var sdpDesc = PB.bytes(1, Data(sdpOffer.utf8))
        for cand in iceCandidates {
            var candPB = PB.bytes(1, Data(cand.mid.utf8))
            candPB.append(PB.number(2, UInt64(cand.mline)))
            candPB.append(PB.bytes(3, Data(cand.sdp.utf8)))
            sdpDesc.append(PB.bytes(2, candPB))
        }
        var webrtcReq = PB.bytes(1, Data(sessionName.utf8))
        webrtcReq.append(PB.bytes(2, sdpDesc))
        
        var d = PB.number(1, 15) // RequestType.START_VIEWFINDER_WEBRTC = 15
        d.append(PB.bytes(2, header(clockSkew: skew)))
        d.append(PB.bytes(8, webrtcReq)) // field 8 = webrtc_request (in CameraApiRequest)
        return d
    }
    public static func stopWebRtcRequest(sessionName: String, skew: Int64) -> Data {
        let webrtcReq = PB.bytes(1, Data(sessionName.utf8))
        var d = PB.number(1, 16) // RequestType.STOP_VIEWFINDER_WEBRTC = 16
        d.append(PB.bytes(2, header(clockSkew: skew)))
        d.append(PB.bytes(8, webrtcReq)) // field 8 = webrtc_request (in CameraApiRequest)
        return d
    }
    public static func computeAuthorizationHeader(method: String, path: String, body: Data?, key: SymmetricKey) -> String {
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Data(method.utf8))
        hmac.update(data: Data(path.utf8))
        if let body { hmac.update(data: body) }
        let macBytes = Data(hmac.finalize())
        let b64 = macBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "daydreamcamera " + b64
    }
}

