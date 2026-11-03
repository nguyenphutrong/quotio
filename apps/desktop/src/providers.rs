//! Provider names and logos. Logo files mirror `apps/macos/Quotio/Assets.xcassets/ProviderIcons`.
use gpui_kit::{Hsla, rgb};

use crate::assets::AppFiles;

pub fn display_name(provider_id: &str) -> String {
    let name = match provider_id {
        "claude" => "Claude",
        "codex" => "Codex",
        "gemini" => "Gemini",
        "antigravity" => "Antigravity",
        "copilot" => "GitHub Copilot",
        "cursor" => "Cursor",
        "amp" => "Amp",
        "factory" => "Factory",
        "openrouter" => "OpenRouter",
        "zai" | "glm" => "Z.ai",
        "minimax" => "MiniMax",
        "kiro" => "Kiro",
        "grok" => "Grok",
        "vertex" => "Vertex AI",
        "devin" | "devin-desktop" => "Devin",
        "synthetic" => "Synthetic",
        "mock" => "Demo",
        other => {
            let mut chars = other.chars();
            return match chars.next() {
                Some(first) => first.to_uppercase().chain(chars).collect(),
                None => String::new(),
            };
        }
    };
    name.to_owned()
}

/// Brand color for logos in group headers; `None` keeps the text color.
pub fn tint(provider_id: &str) -> Option<Hsla> {
    match provider_id {
        "claude" => Some(rgb(0xd97757).into()),
        "gemini" | "antigravity" => Some(rgb(0x335cff).into()),
        _ => None,
    }
}

/// Asset path of the provider's logo, matching the macOS `logoAssetName` mapping.
pub fn logo_path(provider_id: &str) -> Option<String> {
    let file = match provider_id {
        "alibabacodingplan" => "alibaba",
        "azureopenai" => "azureai",
        "codex" => "openai",
        "devin" | "devin-desktop" => "devin",
        "factory" => "factory-droid",
        "ibmbob" => "ibm",
        "kilo" => "kilocode",
        "opencodego" => "opencode",
        "glm" | "zai" => "zai",
        other => other,
    };
    let path = format!("providers/{file}.svg");
    AppFiles::get(&path).map(|_| path)
}
