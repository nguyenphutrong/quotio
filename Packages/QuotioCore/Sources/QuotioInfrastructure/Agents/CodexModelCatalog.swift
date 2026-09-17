import Foundation
import QuotioDomain

/// The model metadata Codex reads through `model_catalog_json`.
///
/// Codex ships metadata for OpenAI's own models and falls back to a template built for them
/// for anything else. That template declares two tools Meta's Muse Code endpoint refuses,
/// and either one fails the request before the model is even reached:
///
/// - the freeform `apply_patch` tool — `` `custom` tools are not supported on this endpoint ``
/// - the hosted web search tool — `` `tools[].search_content_types` is only supported for
///   web_search_preview tools ``
///
/// So Quotio writes the metadata itself for the models the proxy serves, declaring neither
/// tool. Codex still edits files: without `apply_patch_tool_type` it goes through the shell
/// tools it always has.
public enum CodexModelCatalog {
    /// The file Quotio owns next to Codex's own configuration.
    public static let fileName = "quotio-proxy-catalog.json"

    /// Efforts Codex offers for a proxied model, matching the ones Quotio itself writes as
    /// `model_reasoning_effort`.
    private static let reasoningLevels: [[String: String]] = [
        ["effort": "minimal", "description": "Fastest, least reasoning"],
        ["effort": "low", "description": "Light reasoning"],
        ["effort": "medium", "description": "Balanced reasoning"],
        ["effort": "high", "description": "Deep reasoning"],
        ["effort": "xhigh", "description": "Deepest reasoning"],
    ]

    public static func json(models: [String]) throws -> Data {
        let entries = models.map(entry(for:))
        return try JSONSerialization.data(
            withJSONObject: ["models": entries],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func entry(for model: String) -> [String: Any] {
        [
            "slug": model,
            "display_name": model,
            "description": "\(model) through the Quotio proxy",
            "shell_type": "unified_exec",
            "visibility": "list",
            "supported_in_api": true,
            "priority": 1,
            "base_instructions": "You are a helpful coding assistant.",
            "supports_search_tool": false,
            "input_modalities": ["text"],
            "context_window": contextWindow(for: model),
            "max_output_tokens": 32768,
            "supports_parallel_tool_calls": true,
            "supports_reasoning_summaries": false,
            "default_reasoning_summary": "none",
            "support_verbosity": false,
            "truncation_policy": ["mode": "tokens", "limit": 10000],
            "experimental_supported_tools": [],
            "supported_reasoning_levels": reasoningLevels,
            "default_reasoning_level": CodexReasoningEffort.defaultEffort.rawValue,
        ]
    }

    /// Only Muse Code's window is known here, from the model's own documentation. Everything
    /// else the proxy serves keeps Codex's own fallback, which is short rather than wrong:
    /// a window claimed larger than the model's makes Codex compact too late and the request
    /// is rejected mid-conversation.
    private static func contextWindow(for model: String) -> Int {
        model.hasPrefix("muse-") ? 1_048_576 : 128_000
    }
}
