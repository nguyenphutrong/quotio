import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class WarpTokenScreenModel {
    public private(set) var tokens: [WarpToken] = []
    public private(set) var errorMessage: String?

    private let repository: any WarpTokenRepository

    public init(repository: any WarpTokenRepository) {
        self.repository = repository
    }

    public func load() async {
        do {
            tokens = try await repository.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func add(name: String, token: String) async {
        tokens.append(WarpToken(name: name, token: token))
        await persistTokens()
    }

    public func update(_ token: WarpToken) async {
        guard let index = tokens.firstIndex(where: { $0.id == token.id }) else { return }
        tokens[index] = token
        await persistTokens()
    }

    public func delete(id: UUID) async {
        tokens.removeAll { $0.id == id }
        await persistTokens()
    }

    public func toggle(id: UUID) async {
        guard let index = tokens.firstIndex(where: { $0.id == id }) else { return }
        tokens[index].isEnabled.toggle()
        await persistTokens()
    }

    private func persistTokens() async {
        do {
            try await repository.save(tokens)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
