import Foundation
import QuotioApplication
import QuotioDomain

public actor FileAccountMetadataRepository: AccountMetadataRepository {
    private struct Payload: Codable {
        var accounts: [Account] = []
        var disabledAccountIDs: Set<String> = []
    }

    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Quotio/Monitor/accounts-v1.json")
    }

    public func accounts() -> [Account] {
        load().accounts
    }

    public func disabledAccountIDs() -> Set<String> {
        load().disabledAccountIDs
    }

    public func saveAccount(_ account: Account) throws {
        var payload = load()
        payload.accounts.removeAll { $0.id == account.id }
        payload.accounts.append(account)
        try save(payload)
    }

    public func deleteAccount(_ accountID: String) throws {
        var payload = load()
        payload.accounts.removeAll { $0.id == accountID }
        payload.disabledAccountIDs.remove(accountID)
        try save(payload)
    }

    public func setDisabled(_ disabled: Bool, accountID: String) throws {
        var payload = load()
        if disabled {
            payload.disabledAccountIDs.insert(accountID)
        } else {
            payload.disabledAccountIDs.remove(accountID)
        }
        try save(payload)
    }

    private func load() -> Payload {
        guard let data = try? Data(contentsOf: url) else { return Payload() }
        if var payload = try? JSONDecoder().decode(Payload.self, from: data) {
            let removedIDs = Set(
                payload.accounts
                    .filter { $0.providerID.rawValue == "gemini-cli" }
                    .map(\.id)
            )
            guard !removedIDs.isEmpty else { return payload }
            payload.accounts.removeAll { removedIDs.contains($0.id) }
            payload.disabledAccountIDs.subtract(removedIDs)
            try? save(payload)
            return payload
        }

        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else { return Payload() }
        let removedIDs = Set(accounts.compactMap { account in
            account["provider"] as? String == "gemini-cli" ? account["id"] as? String : nil
        })
        guard !removedIDs.isEmpty else { return Payload() }

        object["accounts"] = accounts.filter { $0["provider"] as? String != "gemini-cli" }
        if let disabledIDs = object["disabledAccountIDs"] as? [String] {
            object["disabledAccountIDs"] = disabledIDs.filter { !removedIDs.contains($0) }
        }
        guard let migratedData = try? JSONSerialization.data(withJSONObject: object),
              let payload = try? JSONDecoder().decode(Payload.self, from: migratedData) else {
            return Payload()
        }
        try? save(payload)
        return payload
    }

    private func save(_ payload: Payload) throws {
        try SecureAtomicFileWriter.write(try JSONEncoder().encode(payload), to: url)
    }
}
