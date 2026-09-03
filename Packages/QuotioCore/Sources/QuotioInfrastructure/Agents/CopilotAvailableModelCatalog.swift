import Foundation

public actor CopilotAvailableModelCatalog {
    private let authDirectory: URL
    private let session: any QuotaHTTPSession
    private let now: @Sendable () -> Date
    private var cache: [String: (models: [Model], expiry: Date)] = [:]

    public init(
        homeDirectory: String = NSHomeDirectory(),
        session: any QuotaHTTPSession = URLSession(
            configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)
        ),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        authDirectory = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".cli-proxy-api")
        self.session = session
        self.now = now
    }

    public func availableModelIDs() async -> Set<String> {
        let files = (
            try? FileManager.default.contentsOfDirectory(
                at: authDirectory,
                includingPropertiesForKeys: nil
            )
        ) ?? []
        for file in files where file.lastPathComponent.hasPrefix("github-copilot-")
            && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
                  !auth.accessToken.isEmpty else {
                continue
            }
            let models = await models(accessToken: auth.accessToken)
            if !models.isEmpty {
                return Set(models.filter { $0.modelPickerEnabled == true }.map(\.id))
            }
        }
        return []
    }

    private func models(accessToken: String) async -> [Model] {
        if let cached = cache[accessToken], cached.expiry > now() {
            return cached.models
        }
        guard let apiToken = await apiToken(accessToken: accessToken),
              let models = await fetchModels(apiToken: apiToken) else {
            return []
        }
        cache[accessToken] = (models, now().addingTimeInterval(300))
        return models
    }

    private func apiToken(accessToken: String) async -> String? {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/copilot_internal/v2/token")!
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ 200...299 ~= $0.statusCode }) == true else {
            return nil
        }
        return try? JSONDecoder().decode(APIToken.self, from: data).token
    }

    private func fetchModels(apiToken: String) async -> [Model]? {
        var request = URLRequest(url: URL(string: "https://api.githubcopilot.com/models")!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GithubCopilot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.100.0", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot/1.300.0", forHTTPHeaderField: "Editor-Plugin-Version")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ 200...299 ~= $0.statusCode }) == true else {
            return nil
        }
        return try? JSONDecoder().decode(ModelResponse.self, from: data).data
    }
}

private extension CopilotAvailableModelCatalog {
    struct AuthFile: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    struct APIToken: Decodable {
        let token: String
    }

    struct ModelResponse: Decodable {
        let data: [Model]
    }

    struct Model: Decodable {
        let id: String
        let modelPickerEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case modelPickerEnabled = "model_picker_enabled"
        }
    }
}
