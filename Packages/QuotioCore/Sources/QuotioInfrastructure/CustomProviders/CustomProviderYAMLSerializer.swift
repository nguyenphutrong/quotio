import Foundation
import QuotioDomain

public enum CustomProviderYAMLSerializer {
    static let sectionKeys = Set(CustomProviderType.allCases.map(sectionKey))

    public static func sections(for providers: [CustomProvider]) -> String {
        let enabled = providers.filter(\.isEnabled)
        let order: [CustomProviderType] = [
            .openaiCompatibility,
            .claudeCompatibility,
            .geminiCompatibility,
            .codexCompatibility,
            .glmCompatibility,
        ]
        var result = ""
        for type in order {
            let matchingProviders = type == .openaiCompatibility
                ? enabled.filter { $0.type == type || $0.type == .clinePass }
                : enabled.filter { $0.type == type }
            guard !matchingProviders.isEmpty else { continue }
            result += "\n\(sectionKey(for: type)):\n"
                + matchingProviders.map(block(for:)).joined()
        }
        return result
    }

    public static func block(for provider: CustomProvider) -> String {
        switch provider.type {
        case .openaiCompatibility, .clinePass:
            openAIBlock(for: provider)
        case .claudeCompatibility:
            keyBlock(for: provider, includeModels: true, alwaysBaseURL: false)
        case .geminiCompatibility, .glmCompatibility:
            keyBlock(for: provider, includeModels: false, alwaysBaseURL: false)
        case .codexCompatibility:
            keyBlock(for: provider, includeModels: false, alwaysBaseURL: true)
        }
    }

    public static func escapedString(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\u{00}": result += "\\0"
            case "\u{07}": result += "\\a"
            case "\u{08}": result += "\\b"
            case "\u{09}": result += "\\t"
            case "\u{0A}": result += "\\n"
            case "\u{0B}": result += "\\v"
            case "\u{0C}": result += "\\f"
            case "\u{0D}": result += "\\r"
            case "\u{1B}": result += "\\e"
            case "\u{85}": result += "\\N"
            case "\u{A0}": result += "\\_"
            case "\u{2028}": result += "\\L"
            case "\u{2029}": result += "\\P"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f
                    || (0x80...0x9f).contains(scalar.value) {
                    result += String(format: "\\x%02X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    private static func sectionKey(for type: CustomProviderType) -> String {
        type == .clinePass ? CustomProviderType.openaiCompatibility.rawValue : type.rawValue
    }

    private static func headers(for provider: CustomProvider, indent: Int) -> String {
        guard !provider.effectiveHeaders.isEmpty else { return "" }
        let pad = String(repeating: " ", count: indent)
        return "\(pad)headers:\n" + provider.effectiveHeaders.map {
            "\(pad)  \"\(escapedString($0.key))\": \"\(escapedString($0.value))\"\n"
        }.joined()
    }

    private static func openAIBlock(for provider: CustomProvider) -> String {
        var yaml = "  - name: \"\(escapedString(provider.name))\"\n"
            + "    base-url: \"\(provider.baseURL)\"\n"
        if let prefix = provider.prefix, !prefix.isEmpty {
            yaml += "    prefix: \"\(prefix)\"\n"
        }
        yaml += headers(for: provider, indent: 4)
        if !provider.apiKeys.isEmpty {
            yaml += "    api-key-entries:\n"
            for key in provider.apiKeys {
                yaml += "      - api-key: \"\(key.apiKey)\"\n"
                if let proxy = key.proxyURL, !proxy.isEmpty {
                    yaml += "        proxy-url: \"\(proxy)\"\n"
                }
            }
        }
        if !provider.models.isEmpty {
            yaml += "    models:\n"
            for model in provider.models {
                yaml += "      - name: \"\(model.name)\"\n"
                    + "        alias: \"\(model.effectiveAlias)\"\n"
            }
        }
        return yaml
    }

    private static func keyBlock(
        for provider: CustomProvider,
        includeModels: Bool,
        alwaysBaseURL: Bool
    ) -> String {
        var yaml = ""
        for key in provider.apiKeys {
            yaml += "  - api-key: \"\(key.apiKey)\"\n"
            if alwaysBaseURL
                || (!provider.baseURL.isEmpty && provider.baseURL != provider.type.defaultBaseURL) {
                yaml += "    base-url: \"\(provider.baseURL)\"\n"
            }
            if let prefix = provider.prefix, !prefix.isEmpty {
                yaml += "    prefix: \"\(prefix)\"\n"
            }
            yaml += headers(for: provider, indent: 4)
            if let proxy = key.proxyURL, !proxy.isEmpty {
                yaml += "    proxy-url: \"\(proxy)\"\n"
            }
            if includeModels && !provider.models.isEmpty {
                yaml += "    models:\n"
                for model in provider.models {
                    yaml += "      - name: \"\(model.name)\"\n"
                        + "        alias: \"\(model.effectiveAlias)\"\n"
                }
            }
        }
        return yaml
    }
}
