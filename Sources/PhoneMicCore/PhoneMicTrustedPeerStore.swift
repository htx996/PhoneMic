import Foundation
import Security

public enum PhoneMicTrustedPeerStoreError: Error {
    case cannotEncode
    case cannotDecode
    case keychain(OSStatus)
}

public struct PhoneMicTrustedPeerStore {
    private let service: String
    private let account: String
    private let userDefaultsKey: String

    public init(service: String, account: String, userDefaultsKey: String) {
        self.service = service
        self.account = account
        self.userDefaultsKey = userDefaultsKey
    }

    public func load() -> [String: PhoneMicTrustedPeer] {
        if let peers = try? loadFromKeychain() {
            return peers
        }

        let peers = loadFromUserDefaults()
        if !peers.isEmpty {
            try? save(peers)
        }
        return peers
    }

    public func save(_ peersByID: [String: PhoneMicTrustedPeer]) throws {
        let peers = peersByID.values.sorted { $0.name < $1.name }
        guard let data = try? JSONEncoder().encode(peers) else {
            throw PhoneMicTrustedPeerStoreError.cannotEncode
        }

        var query = baseQuery()
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PhoneMicTrustedPeerStoreError.keychain(status)
        }

        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    public func removeAll() {
        SecItemDelete(baseQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    private func loadFromKeychain() throws -> [String: PhoneMicTrustedPeer] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return [:] }
        guard status == errSecSuccess else {
            throw PhoneMicTrustedPeerStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let peers = try? JSONDecoder().decode([PhoneMicTrustedPeer].self, from: data) else {
            throw PhoneMicTrustedPeerStoreError.cannotDecode
        }
        return Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0) })
    }

    private func loadFromUserDefaults() -> [String: PhoneMicTrustedPeer] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let peers = try? JSONDecoder().decode([PhoneMicTrustedPeer].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0) })
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
