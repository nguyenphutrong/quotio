#!/usr/bin/env bun
/**
 * Quotio Screenshot Automation Script
 *
 * Uses CleanShot X URL scheme API to capture all screens of the Quotio app.
 * Requires CleanShot X 4.7+ to be installed.
 *
 * Usage:
 *   bun run scripts/capture-screenshots.ts              # Interactive TUI
 *   bun run scripts/capture-screenshots.ts --dark       # Dark mode only (all screens)
 *   bun run scripts/capture-screenshots.ts --light      # Light mode only (all screens)
 *   bun run scripts/capture-screenshots.ts --both       # Both modes (all screens)
 */

import * as p from "@clack/prompts";
import { $ } from "bun";
import { existsSync, mkdirSync, readdirSync, renameSync, statSync } from "fs";
import { homedir } from "os";
import { join } from "path";

// =============================================================================
// Configuration
// =============================================================================

const CONFIG = {
  appName: "Quotio",
  windowSize: { width: 1280, height: 800 },
  outputDir: join(import.meta.dir, "..", "screenshots"),
  cleanshotDir: join(homedir(), "Pictures"),
  delays: {
    afterLaunch: 2000,
    afterNavigation: 800,
    afterCapture: 1500,
    afterMenuOpen: 600,
    afterModeSwitch: 1500,
  },
  retryAttempts: 3,
  retryDelay: 500,
} as const;

// =============================================================================
// Screen Definitions
// =============================================================================

interface ScreenDef {
  id: string;
  name: string;
  sidebarIndex: number;
  isMenuBar?: boolean;
}

const SCREENS: ScreenDef[] = [
  { id: "dashboard", name: "Dashboard", sidebarIndex: 0 },
  { id: "quota", name: "Quota", sidebarIndex: 1 },
  { id: "provider", name: "Providers", sidebarIndex: 2 },
  { id: "agent_setup", name: "Agents", sidebarIndex: 4 },
  { id: "settings", name: "Settings", sidebarIndex: 7 },
  { id: "menu_bar", name: "Menu Bar", sidebarIndex: -1, isMenuBar: true },
];

type AppearanceMode = "light" | "dark";
type ThemeChoice = "light" | "dark" | "both";

interface CaptureOptions {
  themes: AppearanceMode[];
  screens: ScreenDef[];
}

// =============================================================================
// Utilities
// =============================================================================

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function runAppleScript(script: string): Promise<string> {
  try {
    const result = await $`osascript -e ${script}`.text();
    return result.trim();
  } catch (error) {
    throw new Error(`AppleScript failed: ${error}`);
  }
}

async function openURL(url: string): Promise<void> {
  await $`open ${url}`.quiet();
}

function log(message: string, type: "info" | "success" | "error" | "warn" = "info") {
  const icons = { info: "ℹ️ ", success: "✅", error: "❌", warn: "⚠️ " };
  console.log(`${icons[type]} ${message}`);
}

async function retry<T>(fn: () => Promise<T>, attempts: number, delay: number): Promise<T> {
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (error) {
      if (i === attempts - 1) throw error;
      log(`Attempt ${i + 1} failed, retrying...`, "warn");
      await sleep(delay);
    }
  }
  throw new Error("Retry exhausted");
}

// =============================================================================
// File Management
// =============================================================================

function findLatestScreenshot(dir: string, beforeTime: number): string | null {
  if (!existsSync(dir)) return null;

  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".png") || f.endsWith(".jpg"))
    .map((f) => ({
      name: f,
      path: join(dir, f),
      mtime: statSync(join(dir, f)).mtimeMs,
    }))
    .filter((f) => f.mtime > beforeTime)
    .sort((a, b) => b.mtime - a.mtime);

  return files[0]?.path ?? null;
}

function moveScreenshot(src: string, dest: string): void {
  renameSync(src, dest);
  log(`Saved: ${dest}`, "success");
}

// =============================================================================
// App Control
// =============================================================================

async function ensureCleanShotRunning(): Promise<void> {
  const result = await $`pgrep -x "CleanShot X"`.quiet().nothrow();
  if (result.exitCode !== 0) {
    log("Starting CleanShot X...");
    await $`open -a "CleanShot X"`.quiet();
    await sleep(2000);
  }
}

async function launchApp(): Promise<void> {
  log("Launching Quotio...");
  await $`open -a ${CONFIG.appName}`.quiet();
  await sleep(CONFIG.delays.afterLaunch);
}

async function activateApp(): Promise<void> {
  await runAppleScript(`
    tell application "${CONFIG.appName}"
      activate
    end tell
  `);
  await sleep(300);
}

async function resizeWindow(): Promise<void> {
  log(`Resizing window to ${CONFIG.windowSize.width}x${CONFIG.windowSize.height}...`);
  await runAppleScript(`
    tell application "System Events"
      tell process "${CONFIG.appName}"
        if (count of windows) > 0 then
          set frontWindow to window 1
          set position of frontWindow to {100, 100}
          set size of frontWindow to {${CONFIG.windowSize.width}, ${CONFIG.windowSize.height}}
        end if
      end tell
    end tell
  `);
  await sleep(500);
}

// =============================================================================
// Navigation
// =============================================================================

async function navigateToScreen(screenIndex: number): Promise<void> {
  // Row indices in outline: row 1 is section header, actual items start at row 2
  // Dashboard=2, Quota=3, Providers=4, Fallback=5, Agents=6, API Keys=7, Logs=8, Settings=9, About=10
  const rowIndex = screenIndex + 2;

  await runAppleScript(`
    tell application "System Events"
      tell process "${CONFIG.appName}"
        tell window 1
          tell group 1
            tell splitter group 1
              tell group 1
                tell scroll area 1
                  tell outline 1
                    select row ${rowIndex}
                    click row ${rowIndex}
                  end tell
                end tell
              end tell
            end tell
          end tell
        end tell
      end tell
    end tell
  `);
  await sleep(CONFIG.delays.afterNavigation);
}

// =============================================================================
// Appearance Mode
// =============================================================================

async function getCurrentAppearance(): Promise<AppearanceMode> {
  const result = await runAppleScript(`
    tell application "System Events"
      tell appearance preferences
        return dark mode
      end tell
    end tell
  `);
  return result === "true" ? "dark" : "light";
}

async function setAppearance(mode: AppearanceMode): Promise<void> {
  log(`Switching to ${mode} mode...`);
  const darkMode = mode === "dark" ? "true" : "false";
  await runAppleScript(`
    tell application "System Events"
      tell appearance preferences
        set dark mode to ${darkMode}
      end tell
    end tell
  `);
  await sleep(CONFIG.delays.afterModeSwitch);
}

// =============================================================================
// Screenshot Capture
// =============================================================================

async function hideDesktopIcons(): Promise<void> {
  await openURL("cleanshot://hide-desktop-icons");
  await sleep(300);
}

async function showDesktopIcons(): Promise<void> {
  await openURL("cleanshot://show-desktop-icons");
  await sleep(300);
}

async function getWindowBounds(): Promise<{ x: number; y: number; width: number; height: number }> {
  const posResult = await runAppleScript(`
    tell application "System Events"
      tell process "${CONFIG.appName}"
        if (count of windows) > 0 then
          set {x, y} to position of window 1
          return (x as text) & "," & (y as text)
        end if
      end tell
    end tell
  `);
  const sizeResult = await runAppleScript(`
    tell application "System Events"
      tell process "${CONFIG.appName}"
        if (count of windows) > 0 then
          set {w, h} to size of window 1
          return (w as text) & "," & (h as text)
        end if
      end tell
    end tell
  `);

  const posParts = posResult.split(",").map(Number);
  const sizeParts = sizeResult.split(",").map(Number);
  return {
    x: posParts[0] ?? 0,
    y: posParts[1] ?? 0,
    width: sizeParts[0] ?? 0,
    height: sizeParts[1] ?? 0,
  };
}

async function getScreenBounds(): Promise<{ width: number; height: number }> {
  const result = await runAppleScript(`
    tell application "Finder"
      get bounds of window of desktop
    end tell
  `);
  const parts = result.split(", ").map(Number);
  return {
    width: parts[2] || 1920,
    height: parts[3] || 1080,
  };
}

async function captureWindow(outputPath: string): Promise<void> {
  const beforeTime = Date.now();

  await activateApp();
  await sleep(200);

  const bounds = await getWindowBounds();
  const clickX = Math.round(bounds.x + bounds.width / 2);
  const clickY = Math.round(bounds.y + bounds.height / 2);

  await openURL("cleanshot://capture-window?action=save");
  await sleep(500);

  await $`cliclick c:${clickX},${clickY}`.quiet();

  await sleep(CONFIG.delays.afterCapture);

  const captured = findLatestScreenshot(CONFIG.cleanshotDir, beforeTime);
  if (captured) {
    moveScreenshot(captured, outputPath);
  } else {
    log(`Warning: Could not find captured screenshot for ${outputPath}`, "warn");
  }
}

async function hideAllWindows(includeQuotio = false): Promise<void> {
  log("Hiding all other windows...");
  const excludeApps = includeQuotio
    ? `name is not "Finder" and name is not "CleanShot X"`
    : `name is not "${CONFIG.appName}" and name is not "Finder" and name is not "CleanShot X"`;

  await runAppleScript(`
    tell application "System Events"
      set allProcesses to every process whose visible is true and ${excludeApps}
      repeat with proc in allProcesses
        try
          set visible of proc to false
        end try
      end repeat
    end tell
  `);
  await sleep(300);
}

async function captureMenuBarDropdown(outputPath: string): Promise<void> {
  log("Capturing menu bar dropdown with sub-menu...");

  await hideAllWindows(true);

  const menuItemInfo = await runAppleScript(`
    tell application "System Events"
      tell process "${CONFIG.appName}"
        if (count of menu bar items of menu bar 2) > 0 then
          set menuItem to menu bar item 1 of menu bar 2
          click menuItem
          set itemPos to position of menuItem
          set itemSize to size of menuItem
          return (item 1 of itemPos as text) & "," & (item 2 of itemPos as text) & "," & (item 1 of itemSize as text) & "," & (item 2 of itemSize as text)
        end if
      end tell
    end tell
  `);

  await sleep(CONFIG.delays.afterMenuOpen + 500);

  const [menuX, , menuWidth] = menuItemInfo.split(",").map(Number);

  const menuRightEdge = (menuX || 1400) + (menuWidth || 100);
  const firstAccountY = 340;
  const hoverX = menuRightEdge - 180;

  await $`cliclick m:${hoverX},${firstAccountY}`.quiet();
  await sleep(800);

  const screen = await getScreenBounds();
  const captureWidth = 900;
  const captureHeight = 1100;
  const captureX = screen.width - captureWidth;
  const captureY = 0;

  await $`screencapture -x -R ${captureX},${captureY},${captureWidth},${captureHeight} ${outputPath}`.quiet();

  await runAppleScript(`
    tell application "System Events"
      key code 53
    end tell
  `);

  log(`Saved: ${outputPath}`, "success");
  await sleep(300);
}

// =============================================================================
// Main Capture Flow
// =============================================================================

async function captureScreen(screen: ScreenDef, mode: AppearanceMode, outputDir: string): Promise<void> {
  const suffix = mode === "dark" ? "_dark" : "";

  if (screen.isMenuBar) {
    await retry(
      async () => {
        await captureMenuBarDropdown(join(outputDir, `${screen.id}${suffix}.png`));
      },
      CONFIG.retryAttempts,
      CONFIG.retryDelay
    );
  } else {
    log(`Navigating to ${screen.name}...`);
    await retry(
      async () => {
        await navigateToScreen(screen.sidebarIndex);
        await captureWindow(join(outputDir, `${screen.id}${suffix}.png`));
      },
      CONFIG.retryAttempts,
      CONFIG.retryDelay
    );
  }
}

async function captureSelectedScreens(options: CaptureOptions, outputDir: string): Promise<void> {
  for (const mode of options.themes) {
    log(`\n📸 Capturing in ${mode} mode...`);
    await setAppearance(mode);
    await activateApp();
    await resizeWindow();

    for (const screen of options.screens) {
      await captureScreen(screen, mode, outputDir);
    }
  }
}

function ensureOutputDir(dir: string): void {
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}

// =============================================================================
// Interactive TUI
// =============================================================================

async function showInteractiveTUI(): Promise<CaptureOptions | null> {
  p.intro("📸 Quotio Screenshot Automation");

  // Theme selection
  const themeChoice = await p.select({
    message: "Select appearance mode:",
    options: [
      { value: "both", label: "Both (Light & Dark)", hint: "recommended for README" },
      { value: "light", label: "Light mode only" },
      { value: "dark", label: "Dark mode only" },
    ],
  });

  if (p.isCancel(themeChoice)) {
    p.cancel("Operation cancelled.");
    return null;
  }

  // Screen selection
  const screenChoices = await p.multiselect({
    message: "Select screens to capture:",
    options: SCREENS.map((s) => ({
      value: s.id,
      label: s.name,
      hint: s.isMenuBar ? "menu bar dropdown" : undefined,
    })),
    initialValues: SCREENS.map((s) => s.id), // All selected by default
    required: true,
  });

  if (p.isCancel(screenChoices)) {
    p.cancel("Operation cancelled.");
    return null;
  }

  // Confirm
  const selectedScreens = SCREENS.filter((s) => (screenChoices as string[]).includes(s.id));
  const themes: AppearanceMode[] =
    themeChoice === "both" ? ["light", "dark"] : [themeChoice as AppearanceMode];

  const themesLabel = themes.join(" & ");
  const screensLabel = selectedScreens.map((s) => s.name).join(", ");

  const confirmed = await p.confirm({
    message: `Capture ${selectedScreens.length} screens in ${themesLabel} mode?`,
    initialValue: true,
  });

  if (p.isCancel(confirmed) || !confirmed) {
    p.cancel("Operation cancelled.");
    return null;
  }

  p.log.info(`Themes: ${themesLabel}`);
  p.log.info(`Screens: ${screensLabel}`);

  return {
    themes,
    screens: selectedScreens,
  };
}

function parseCliArgs(): CaptureOptions | "interactive" {
  const args = process.argv.slice(2);

  // No args = interactive mode
  if (args.length === 0) {
    return "interactive";
  }

  // Parse CLI flags
  const hasLight = args.includes("--light");
  const hasDark = args.includes("--dark");
  const hasBoth = args.includes("--both");

  let themes: AppearanceMode[];
  if (hasBoth || (hasLight && hasDark)) {
    themes = ["light", "dark"];
  } else if (hasDark) {
    themes = ["dark"];
  } else if (hasLight) {
    themes = ["light"];
  } else {
    themes = ["light", "dark"]; // default
  }

  return {
    themes,
    screens: SCREENS, // CLI mode captures all screens
  };
}

// =============================================================================
// CLI Entry Point
// =============================================================================

async function main() {
  const cliResult = parseCliArgs();

  let options: CaptureOptions;

  if (cliResult === "interactive") {
    const tuiResult = await showInteractiveTUI();
    if (!tuiResult) {
      process.exit(0);
    }
    options = tuiResult;
  } else {
    console.log(`
╔══════════════════════════════════════════════════════════════╗
║           Quotio Screenshot Automation                       ║
║           Using CleanShot X URL Scheme API                   ║
╚══════════════════════════════════════════════════════════════╝
`);
    options = cliResult;
  }

  const outputDir = CONFIG.outputDir;
  ensureOutputDir(outputDir);
  log(`Output directory: ${outputDir}`);

  // Save current appearance to restore later
  const originalMode = await getCurrentAppearance();
  log(`Current appearance: ${originalMode}`);

  const spinner = p.spinner();
  spinner.start("Preparing capture environment...");

  try {
    await ensureCleanShotRunning();
    await hideDesktopIcons();
    await launchApp();
    spinner.stop("Environment ready");

    await captureSelectedScreens(options, outputDir);
  } finally {
    await setAppearance(originalMode);
    await showDesktopIcons();
  }

  p.outro(`✅ Captured ${options.screens.length} screens × ${options.themes.length} themes`);
  log(`📁 Output: ${outputDir}`);
}

main().catch((error) => {
  console.error("❌ Fatal error:", error);
  process.exit(1);
});
