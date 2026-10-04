import Foundation
import Synchronization
import Testing
import QuotioMobile
import QuotioHostClient
@testable import QuotioIOS

@Test func embeddedWidgetIncludesConfigurationMetadata() throws {
    let metadataURL = Bundle.main.bundleURL
        .appendingPathComponent("PlugIns/QuotioWidgets.appex/Metadata.appintents/extract.actionsdata")
    let metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
    let actions = try #require(metadata["actions"] as? [String: Any])
    let intent = try #require(actions["QuotaIntent"] as? [String: Any])
    let parameters = try #require(intent["parameters"] as? [[String: Any]])
    #expect(parameters.compactMap { $0["name"] as? String } == ["quota", "showUsed"])
    let entities = try #require(metadata["entities"] as? [String: Any])
    #expect(entities["QuotaChoice"] != nil)
    let queries = try #require(metadata["queries"] as? [String: Any])
    #expect(queries["QuotaQuery"] != nil)
}

private final class HostProtocol: URLProtocol, @unchecked Sendable {
    static let replies = Mutex<[String: (Int, Data)]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.replies.withLock { $0[request.url!.path] ?? (404, Data()) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HeldHostProtocol: URLProtocol, @unchecked Sendable {
    static let started = Mutex<Set<String>>([])
    static let replies = Mutex<[String: Data]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        guard let data = Self.replies.withLock({ $0[host] }) else {
            Self.started.withLock { $0.insert(host) }
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func waitForRequest(host: String) async throws {
        for _ in 0..<300 {
            if started.withLock({ $0.contains(host) }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
}

@Test(arguments: [true, false])
@MainActor func removingHostDuringRefreshAllowsNextRefresh(removeSelected: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage = MobileStorage(directory: directory)
    let group = try #require(Bundle.main.object(forInfoDictionaryKey: "QuotioKeychainGroup") as? String)
    let keychain = MobileKeychain(accessGroup: group, service: "app.quotio.ios.tests.\(UUID().uuidString)")
    let clientID = String(repeating: "a", count: 43)
    let token = "qclient.\(clientID).\(String(repeating: "b", count: 43))"
    var state = MobileState()
    state.hosts = ["old", "other"].map {
        HostProfile(id: $0, name: $0, origin: URL(string: "https://\(UUID().uuidString).example.test")!,
                    clientID: clientID, expiresAt: nil, snapshot: nil)
    }
    state.selectedHostID = "old"
    try storage.save(state)
    defer {
        for host in state.hosts {
            try? keychain.delete(host.id)
            HeldHostProtocol.started.withLock { $0.remove(host.origin.host!) }
            HeldHostProtocol.replies.withLock { $0.removeValue(forKey: host.origin.host!) }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    for host in state.hosts { try keychain.save(token, host: host.id) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HeldHostProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let store = HostStore(storage: storage, keychain: keychain, makeClient: { QuotioHostHTTPClient(connection: $0, session: session) })
    let oldRefresh = Task { await store.refresh() }
    defer { oldRefresh.cancel() }
    let oldHost = state.hosts[0].origin.host!
    try await HeldHostProtocol.waitForRequest(host: oldHost)
    #expect(store.refreshing)
    store.remove(removeSelected ? "old" : "other")
    try #require(!store.refreshing)
    let selected = try #require(store.selected)
    #expect(selected.id == (removeSelected ? "other" : "old"))
    let selectedHost = selected.origin.host!
    HeldHostProtocol.started.withLock { $0.remove(selectedHost) }
    let nextRefresh = Task { await store.refresh() }
    defer { nextRefresh.cancel() }
    try await HeldHostProtocol.waitForRequest(host: selectedHost)
    oldRefresh.cancel()
    await oldRefresh.value
    #expect(store.refreshing)
    #expect(store.selected?.needsPairing == false)
    #expect(store.issue == nil)
    nextRefresh.cancel()
    await nextRefresh.value
    #expect(!store.refreshing)
    let fixtureURL = try #require(Bundle.main.url(forResource: "demo-snapshot", withExtension: "json"))
    var snapshot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
    var host = try #require(snapshot["host"] as? [String: Any])
    host["id"] = selected.id
    snapshot["host"] = host
    snapshot["revision"] = 44
    let data = try JSONSerialization.data(withJSONObject: snapshot)
    HeldHostProtocol.replies.withLock { $0[selectedHost] = data }
    await store.refresh()
    #expect(!store.refreshing)
    #expect(store.issue == nil)
    #expect(store.selected?.snapshot?.revision == 44)
    #expect(try storage.load().hosts.first?.snapshot?.revision == 44)
    #expect(try keychain.read(removeSelected ? "old" : "other") == nil)
}

@Test @MainActor func pairingPersistsInKeychainAndRevocationClearsSensitiveCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage = MobileStorage(directory: directory)
    let group = try #require(Bundle.main.object(forInfoDictionaryKey: "QuotioKeychainGroup") as? String)
    let keychain = MobileKeychain(accessGroup: group, service: "app.quotio.ios.tests.\(UUID().uuidString)")
    let fixtureURL = try #require(Bundle.main.url(forResource: "demo-snapshot", withExtension: "json"))
    let fixture = try Data(contentsOf: fixtureURL)
    let hostID = try QuotioHostSnapshot.decode(fixture).host.id
    defer { try? keychain.delete(hostID); try? FileManager.default.removeItem(at: directory) }
    let clientID = String(repeating: "a", count: 43)
    let token = "qclient.\(clientID).\(String(repeating: "b", count: 43))"
    let status = try JSONSerialization.data(withJSONObject: ["schema_version":2,"api_version":2,"client_id":clientID,"access_mode":"read_only","ready":true,"refreshing":false])
    HostProtocol.replies.withLock { $0 = ["/v2/status":(200,status),"/v2/snapshot":(200,fixture),"/v2/providers":(200,Data(#"{"schema_version":2,"providers":[]}"#.utf8))] }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HostProtocol.self]
    let session = URLSession(configuration: configuration)
    let certificate = Data([1, 2, 3])
    let pairingJSON = try JSONSerialization.data(withJSONObject: ["pairing_version": 2, "origin": "https://host.example.test", "host_name": "Synthetic Mac", "host_id": hostID,
        "client_id": clientID, "token": token, "expires_at": "2030-01-01T00:00:00Z", "certificate": certificate.base64EncodedString()])
    let pairing = try Pairing.decode(pairingJSON)
    let store = HostStore(storage: storage, keychain: keychain, makeClient: { connection in
        #expect(connection.trustedCertificate == certificate)
        return QuotioHostHTTPClient(connection: connection, session: session)
    })
    try await store.pair(name: "Synthetic host", origin: "https://host.example.test", token: token, pairing: pairing)
    #expect(store.selected?.id == hostID)
    #expect(try storage.load().hosts.first?.certificate == certificate)
    #expect(try keychain.read(hostID) == token)
    #expect(try storage.load().hosts.first?.snapshot != nil)
    let persisted = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
    #expect(!persisted.contains(token))
    HostProtocol.replies.withLock { $0["/v2/snapshot"] = (401,Data(#"{"error":"unauthorized"}"#.utf8)) }
    await store.refresh()
    #expect(store.selected?.needsPairing == true)
    #expect(store.selected?.snapshot == nil)
    #expect(try storage.load().hosts.first?.snapshot == nil)
    store.remove(hostID)
    #expect(try keychain.read(hostID) == nil)
    #expect(try storage.load().hosts.isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["QUOTIO_TLS_SMOKE_FILE"] != nil))
@MainActor func liveRustTLSUsesPairedTrustWithAppTransportSecurity() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["QUOTIO_TLS_SMOKE_FILE"])
    struct Fixture: Decodable { let origin: URL; let token: String; let certificate: Data }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let client = QuotioHostHTTPClient(connection: .init(baseURL: fixture.origin, token: fixture.token, trustedCertificate: fixture.certificate))
    let status = try await client.status()
    #expect(status.accessMode == "read_only")
    let unpaired = QuotioHostHTTPClient(connection: .init(baseURL: fixture.origin, token: fixture.token))
    await #expect(throws: (any Error).self) { try await unpaired.status() }
}

@Test @MainActor func sharedContainerStorageChangesOnlyOwnedFileMetadata() throws {
    let group = try #require(Bundle.main.object(forInfoDictionaryKey: "QuotioAppGroup") as? String)
    let root = try #require(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group))
    let directory = root.appendingPathComponent("quotio-storage-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keys: Set<URLResourceKey> = [.isExcludedFromBackupKey]
    let original = try directory.resourceValues(forKeys: keys).isExcludedFromBackup
    let storage = MobileStorage(directory: directory)
    try storage.save(MobileState())
    #expect(try directory.resourceValues(forKeys: keys).isExcludedFromBackup == original)
    #expect(try directory.appendingPathComponent("state.json").resourceValues(forKeys: keys).isExcludedFromBackup == true)
    #expect(try storage.load().hosts.isEmpty)
    #expect(HostStore.message(CocoaError(.fileWriteNoPermission)) == String(localized: "Changes could not be saved. Try again."))
}
