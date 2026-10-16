import Foundation
import Network
import Observation
import Security
import SonoraCore

/// Only this application's proxy credential is read or changed.
struct MetadataTokenStore {
    let service: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "proxy-token"]
    }
    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw CredentialError(status: status) }
        return value
    }
    func save(_ token: String) throws {
        if token.isEmpty { try remove(); return }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError(status: status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status: status) }
    }
    private struct CredentialError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "No se pudo acceder al token en el llavero. Inténtalo con el iPhone desbloqueado." }
    }
}

@MainActor @Observable final class MetadataAssistantSettings {
    static let shared = MetadataAssistantSettings(
        defaults: .standard, tokens: MetadataTokenStore(service: "com.tonyredondo.Sonora.metadata"),
        cache: MetadataLookupCache(directory: supportDirectory.appendingPathComponent("MetadataCache", isDirectory: true)))

    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Sonora", isDirectory: true)
    }
    private(set) var endpoint: String
    private(set) var hasToken: Bool
    var offline: Bool { didSet { defaults.set(offline, forKey: "metadata.offline") } }
    private(set) var networkAvailable = true
    private(set) var configurationRevision = 0
    private(set) var configurationIssue: String?
    var effectiveOffline: Bool { offline || !networkAvailable }
    let cache: MetadataLookupCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: MetadataTokenStore
    @ObservationIgnored private var monitor: NWPathMonitor?

    init(defaults: UserDefaults, tokens: MetadataTokenStore, cache: MetadataLookupCache) {
        self.defaults = defaults; self.tokens = tokens; self.cache = cache
        endpoint = defaults.string(forKey: "metadata.endpoint") ?? ""
        offline = defaults.bool(forKey: "metadata.offline")
        hasToken = (try? tokens.read()) != nil
    }

    func savedToken() throws -> String { try tokens.read() ?? "" }

    func save(endpoint: String, token: String) throws {
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try MetadataProxyConnection(endpoint: address, token: token)
        try tokens.save(token)
        defaults.set(address, forKey: "metadata.endpoint")
        self.endpoint = address; hasToken = !token.isEmpty
        configurationIssue = nil; configurationRevision += 1
    }

    func client() throws -> MetadataLookupClient {
        MetadataLookupClient(connection: try MetadataProxyConnection(endpoint: endpoint, token: savedToken()), cache: cache)
    }

    /// A provisioning file lives only in the app's private container and is consumed once.
    func importConnection(from file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 4096 else { throw MetadataLookupError.invalidConnection }
        struct ConnectionFile: Decodable { let endpoint: String; let token: String }
        let input = try JSONDecoder().decode(ConnectionFile.self, from: Data(contentsOf: file))
        try save(endpoint: input.endpoint, token: input.token)
        try FileManager.default.removeItem(at: file)
    }

    func start() {
        guard monitor == nil else { return }
        let file = Self.supportDirectory.appendingPathComponent("ProxyConnection.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { try importConnection(from: file) }
            catch { configurationIssue = "No se pudo importar la conexión. Revisa los ajustes del asistente." }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkAvailable = available }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "Sonora.MetadataConnectivity"))
    }
}
