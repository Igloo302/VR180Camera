import Foundation
import CryptoKit
import Security

enum PairingStore {
    private static let service = "dev.local.vr180macprobe.pairing-key"
    private static let lastCameraKey = "lastPairedCameraUUID"
    private static let lastPublicKeyKey = "lastPairedCameraPublicKey"

    static var lastCameraID: UUID? {
        UserDefaults.standard.string(forKey: lastCameraKey).flatMap(UUID.init(uuidString:))
    }

    static var savedPublicKey: Data? {
        UserDefaults.standard.data(forKey: lastPublicKeyKey)
    }

    static var hasSavedPairing: Bool {
        return lastKey != nil
    }

    private static let lastClockSkewKey = "lastCameraClockSkew"
    static var lastClockSkew: Int64? {
        get {
            guard UserDefaults.standard.object(forKey: lastClockSkewKey) != nil else { return nil }
            return Int64(UserDefaults.standard.integer(forKey: lastClockSkewKey))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue), forKey: lastClockSkewKey)
            }
        }
    }

    static var lastKey: SymmetricKey? {
        guard let id = lastCameraID else { return nil }
        return key(for: id)
    }

    static func key(for cameraID: UUID) -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: cameraID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data, bytes.count == 32 else { return nil }
        query.removeAll()
        return SymmetricKey(data: bytes)
    }

    @discardableResult static func save(_ key: SymmetricKey, for cameraID: UUID, publicKey: Data? = nil) -> Bool {
        let bytes = key.withUnsafeBytes { Data($0) }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: cameraID.uuidString
        ]
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        let status: OSStatus
        if update == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = bytes
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        } else { status = update }
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(cameraID.uuidString, forKey: lastCameraKey)
        if let publicKey {
            UserDefaults.standard.set(publicKey, forKey: lastPublicKeyKey)
        }
        return true
    }

    static func matchesAdvertisement(manufacturerData: Data) -> Bool {
        guard let pubKey = savedPublicKey else { return false }
        // Android WifiNoopPolicy.matchesPreviouslyPairedCamera:
        // if bArr.length != 6 return false
        // return MessageDigest.isEqual(Arrays.copyOfRange(bArr, 3, 6), Arrays.copyOf(generateHMAC(bArr2, Arrays.copyOf(bArr, 3)), 3))
        // Note: in CoreBluetooth, manufacturerData includes 2 bytes company ID prefix.
        // If data is 8 bytes, payload is 6 bytes.
        let bytes: Data
        if manufacturerData.count == 8 {
            bytes = manufacturerData.dropFirst(2)
        } else if manufacturerData.count == 6 {
            bytes = manufacturerData
        } else {
            return false
        }
        
        let prefix = bytes.prefix(3)
        let expectedSuffix = bytes.suffix(3)
        
        // HMAC-SHA256 with key = camera public key, message = prefix (3 bytes)
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: pubKey))
        hmac.update(data: prefix)
        let computed = Data(hmac.finalize()).prefix(3)
        return computed == expectedSuffix
    }

    static func forgetLastCamera() {
        if let cameraID = lastCameraID {
            let identity: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: cameraID.uuidString
            ]
            SecItemDelete(identity as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: lastCameraKey)
        UserDefaults.standard.removeObject(forKey: lastPublicKeyKey)
    }
}
