import Foundation
import Security

struct CredentialStore {
    let service: String

    init(service: String = "app.reelclip.ios.credentials") {
        self.service = service
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(addStatus)
        }
    }

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(status)
        }

        guard let data = item as? Data else {
            throw CredentialStoreError.invalidStoredData
        }

        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum CredentialStoreError: LocalizedError, Equatable {
    case invalidStoredData
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredData:
            return "The stored credential could not be read."
        case .keychainFailure(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
