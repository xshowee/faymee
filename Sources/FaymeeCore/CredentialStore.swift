import Foundation
import Security

/// 在线服务商的 API Key 存储槽位。同平台跨能力（如阿里云百炼、OpenAI）共用槽位，自定义槽位按能力隔离
public enum CredentialSlot: String, CaseIterable, Hashable, Sendable {
    case dashScope = "dashscope"
    case openAI = "openai"
    case groq = "groq"
    case deepSeek = "deepseek"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case customTranscription = "custom-transcription"
    case customMinutes = "custom-minutes"
}

/// 在线凭据存储抽象。正式环境接 macOS Keychain，测试注入内存实现
public protocol CredentialStore: Sendable {
    func string(for slot: CredentialSlot) -> String
    func setString(_ value: String, for slot: CredentialSlot) throws
}

public enum CredentialStoreError: LocalizedError, Equatable, Sendable {
    case keychainStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychainStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "钥匙串读写失败（\(status)）：\(message)"
            }
            return "钥匙串读写失败（\(status)）"
        }
    }
}

/// 基于 macOS Keychain 的凭据存储，写入空字符串时自动删除对应条目
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public let service: String
    private let lock = NSLock()

    public init(service: String = "com.faymee.online-credentials") {
        self.service = service
    }

    public func string(for slot: CredentialSlot) -> String {
        lock.withLock {
            var query = baseQuery(for: slot)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { return "" }
            return value
        }
    }

    public func setString(_ value: String, for slot: CredentialSlot) throws {
        try lock.withLock {
            let query = baseQuery(for: slot)
            if value.isEmpty {
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    throw CredentialStoreError.keychainStatus(status)
                }
                return
            }
            let data = Data(value.utf8)
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if updateStatus == errSecSuccess { return }
            if updateStatus != errSecItemNotFound {
                throw CredentialStoreError.keychainStatus(updateStatus)
            }
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw CredentialStoreError.keychainStatus(addStatus)
            }
        }
    }

    private func baseQuery(for slot: CredentialSlot) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: slot.rawValue,
        ]
    }
}

/// 内存凭据存储，供单元测试隔离 Keychain
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CredentialSlot: String]

    public init(_ initial: [CredentialSlot: String] = [:]) {
        self.storage = initial
    }

    public func string(for slot: CredentialSlot) -> String {
        lock.withLock { storage[slot] ?? "" }
    }

    public func setString(_ value: String, for slot: CredentialSlot) throws {
        lock.withLock {
            if value.isEmpty {
                storage.removeValue(forKey: slot)
            } else {
                storage[slot] = value
            }
        }
    }
}
