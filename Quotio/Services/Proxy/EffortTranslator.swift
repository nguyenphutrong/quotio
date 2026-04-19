//
//  EffortTranslator.swift
//  Quotio - Clamp Anthropic `output_config.effort` for OpenAI compatibility
//
//  Claude Code's /effort slash command supports five levels:
//      low | medium | high | xhigh | max
//  (see https://platform.claude.com/docs/en/build-with-claude/effort)
//
//  OpenAI's reasoning_effort (for GPT-5 / Codex models) supports four levels:
//      low | medium | high | xhigh
//  (see https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide)
//
//  CLIProxyAPI already translates output_config.effort → reasoning_effort for
//  requests routed to OpenAI backends, so low/medium/high/xhigh pass through
//  without modification. The only incompatibility is Anthropic's "max" level,
//  which has no OpenAI equivalent and would be rejected upstream.
//
//  This translator clamps max → xhigh so every Claude /effort level produces
//  a valid upstream request when routed to a GPT/Codex model. Other values
//  are left untouched. Non-JSON bodies, bodies without output_config.effort,
//  and bodies whose effort is already in the allowed set are all no-ops.
//
//  The function is pure and has no dependencies beyond Foundation, making it
//  trivially testable (see scripts/test_effort_translator.swift).
//

import Foundation

nonisolated enum EffortTranslator {

    // MARK: - Types

    nonisolated struct RewriteResult: Equatable, Sendable {
        /// The (possibly rewritten) body to forward upstream.
        let newBody: String
        /// The original effort value if present, else nil.
        let originalEffort: String?
        /// The value written into the outgoing body if a rewrite occurred.
        let rewrittenEffort: String?

        var didRewrite: Bool { rewrittenEffort != nil }
    }

    // MARK: - Public API

    /// Clamp the effort value in an Anthropic-style JSON request body so it is
    /// valid for OpenAI upstream translation.
    ///
    /// Behavior:
    /// - Body is not JSON, or has no `output_config.effort`: returned unchanged.
    /// - Effort is `low | medium | high | xhigh` (or unknown): returned unchanged.
    /// - Effort is `max` (case-insensitive): rewritten to `xhigh`.
    static func clampEffort(in body: String) -> RewriteResult {
        // Fast path: skip full JSON parse if the field can't possibly be present.
        // The substring "output_config" is specific enough to avoid false positives
        // in typical prompt content.
        guard body.contains("\"output_config\"") else {
            return RewriteResult(newBody: body, originalEffort: nil, rewrittenEffort: nil)
        }

        guard
            let bodyData = body.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            var outputConfig = json["output_config"] as? [String: Any],
            let effortStr = outputConfig["effort"] as? String
        else {
            return RewriteResult(newBody: body, originalEffort: nil, rewrittenEffort: nil)
        }

        // Only "max" needs clamping. Everything else - including unknown strings -
        // is left alone so CLIProxyAPI / upstream can make its own decision.
        guard effortStr.lowercased() == "max" else {
            return RewriteResult(newBody: body, originalEffort: effortStr, rewrittenEffort: nil)
        }

        outputConfig["effort"] = "xhigh"
        json["output_config"] = outputConfig

        guard
            let newData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
            let newBody = String(data: newData, encoding: .utf8)
        else {
            // Serialization failed; pass original through rather than dropping the request.
            return RewriteResult(newBody: body, originalEffort: effortStr, rewrittenEffort: nil)
        }

        return RewriteResult(newBody: newBody, originalEffort: effortStr, rewrittenEffort: "xhigh")
    }
}
