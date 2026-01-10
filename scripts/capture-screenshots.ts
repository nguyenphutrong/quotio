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
import { existsSync, mkdirSync } from "fs";
import { join } from "path";

// =============================================================================
// Configuration
// =============================================================================

const CONFIG = {
  appName: "Quotio",
  windowSize: { width: 1280, height: 800 },
  outputDir: join(import.meta.dir, "..", "screenshots"),
  wallpaperCacheDir: join(import.meta.dir, "..", ".wallpaper-cache"),
  wallpapers: {
    light: "https://misc-assets.raycast.com/wallpapers/blushing-fire.png",
    dark: "https://misc-assets.raycast.com/wallpapers/loupe-mono-dark.heic",
  },
  paths: {
    localBuild: join(import.meta.dir, "..", "build", "Quotio.app"),
    installed: "/Applications/Quotio.app",
  },
  delays: {
    afterLaunch: 2000,
    afterNavigation: 800,
    afterCapture: 1500,
    afterMenuOpen: 600,
    afterModeSwitch: 1500,
    afterWallpaperChange: 2000,
  },
  retryAttempts: 3,
  retryDelay: 500,
} as const;

type AppSource = "local" | "installed";

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
  { id: "fallback", name: "Fallback", sidebarIndex: 3 },
  { id: "agent_setup", name: "Agents", sidebarIndex: 4 },
  { id: "api_keys", name: "API Keys", sidebarIndex: 5 },
  { id: "logs", name: "Logs", sidebarIndex: 6 },
  { id: "settings", name: "Settings", sidebarIndex: 7 },
  { id: "about", name: "About", sidebarIndex: 8 },
  { id: "menu_bar", name: "Menu Bar", sidebarIndex: -1, isMenuBar: true },
];

type AppearanceMode = "light" | "dark";
type ThemeChoice = "light" | "dark" | "both";

interface CaptureOptions {
  themes: AppearanceMode[];
  screens: ScreenDef[];
  appSource: AppSource;
}

// =============================================================================
// Utilities
// =============================================================================

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// =============================================================================
// App Detection
// =============================================================================

interface AppAvailability {
  local: boolean;
  installed: boolean;
  localPath: string;
  installedPath: string;
}

function detectAvailableApps(): AppAvailability {
  return {
    local: existsSync(CONFIG.paths.localBuild),
    installed: existsSync(CONFIG.paths.installed),
    localPath: CONFIG.paths.localBuild,
    installedPath: CONFIG.paths.installed,
  };
}

function getAppPath(source: AppSource): string {
  return source === "local" ? CONFIG.paths.localBuild : CONFIG.paths.installed;
}

async function selectAppSource(apps: AppAvailability): Promise<AppSource | null> {
  // Only one available - use it
  if (apps.local && !apps.installed) {
    p.log.info("Using local build (installed app not found)");
    return "local";
  }
  if (apps.installed && !apps.local) {
    p.log.info("Using installed app (local build not found)");
    return "installed";
  }
  if (!apps.local && !apps.installed) {
    p.log.error("No Quotio app found! Build locally or install to /Applications/");
    return null;
  }

  // Both available - ask user
  const choice = await p.select({
    message: "Which Quotio app to capture?",
    options: [
      { value: "local", label: "Local build", hint: "build/Quotio.app" },
      { value: "installed", label: "Installed app", hint: "/Applications/Quotio.app" },
    ],
  });

  if (p.isCancel(choice)) {
    return null;
  }

  return choice as AppSource;
}

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
// App Control
// =============================================================================

async function launchApp(appPath: string): Promise<void> {
  log(`Launching Quotio from ${appPath}...`);
  await $`open ${appPath}`.quiet();
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
// Wallpaper Management
// =============================================================================

async function downloadWallpaper(url: string, filename: string): Promise<string> {
  const cacheDir = CONFIG.wallpaperCacheDir;
  if (!existsSync(cacheDir)) {
    mkdirSync(cacheDir, { recursive: true });
  }

  const filePath = join(cacheDir, filename);
  if (existsSync(filePath)) {
    return filePath;
  }

  log(`Downloading wallpaper: ${filename}...`);
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to download wallpaper: ${response.statusText}`);
  }
  const buffer = await response.arrayBuffer();
  await Bun.write(filePath, buffer);
  return filePath;
}

async function ensureWallpapers(): Promise<{ light: string; dark: string }> {
  const [light, dark] = await Promise.all([
    downloadWallpaper(CONFIG.wallpapers.light, "light-wallpaper.png"),
    downloadWallpaper(CONFIG.wallpapers.dark, "dark-wallpaper.heic"),
  ]);
  return { light, dark };
}

async function getCurrentWallpaper(): Promise<string> {
  const result = await runAppleScript(`
    tell application "System Events"
      tell every desktop
        get picture as text
      end tell
    end tell
  `);
  return result.split(",")[0]?.trim() || "";
}

async function setWallpaper(imagePath: string): Promise<void> {
  log(`Setting wallpaper: ${imagePath.split("/").pop()}...`);
  await runAppleScript(`
    tell application "Finder"
      set desktop picture to POSIX file "${imagePath}"
    end tell
  `);
  await sleep(CONFIG.delays.afterWallpaperChange);
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

async function getWindowId(): Promise<number | null> {
  const swiftCode = `
import Cocoa
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for window in windowList {
    if let ownerName = window[kCGWindowOwnerName as String] as? String,
       ownerName == "${CONFIG.appName}",
       let windowNumber = window[kCGWindowNumber as String] as? Int {
        print(windowNumber)
        exit(0)
    }
}
exit(1)
`;
  const result = await $`swift -e ${swiftCode}`.quiet().nothrow();
  if (result.exitCode !== 0) return null;
  const id = parseInt(result.text().trim(), 10);
  return isNaN(id) ? null : id;
}

async function captureWindow(outputPath: string, wallpaperPath: string): Promise<void> {
  await activateApp();
  await sleep(200);

  const windowId = await getWindowId();
  if (!windowId) {
    log(`Warning: Could not get window ID for ${outputPath}`, "warn");
    return;
  }

  const tempPath = outputPath.replace(".png", "_temp.png");
  await $`screencapture -l ${windowId} ${tempPath}`.quiet();
  await compositeOnWallpaper(tempPath, wallpaperPath, outputPath, 100);
  await $`rm ${tempPath}`.quiet();

  log(`Saved: ${outputPath}`, "success");
}

async function compositeOnWallpaper(
  windowImagePath: string,
  wallpaperPath: string,
  outputPath: string,
  padding: number
): Promise<void> {
  const sipsInfo = await $`sips -g pixelWidth -g pixelHeight ${windowImagePath}`.text();
  const widthMatch = sipsInfo.match(/pixelWidth:\s*(\d+)/);
  const heightMatch = sipsInfo.match(/pixelHeight:\s*(\d+)/);
  const windowWidth = parseInt(widthMatch?.[1] || "1920");
  const windowHeight = parseInt(heightMatch?.[1] || "1080");

  const canvasWidth = windowWidth + padding * 2;
  const canvasHeight = windowHeight + padding * 2;

  await $`magick ${wallpaperPath} -resize ${canvasWidth}x${canvasHeight}^ -gravity center -extent ${canvasWidth}x${canvasHeight} ${windowImagePath} -gravity center -composite ${outputPath}`.quiet();
  await compressPng(outputPath);
}

async function compressPng(imagePath: string): Promise<void> {
  await $`pngquant --force --quality=80-95 --output ${imagePath} ${imagePath}`.quiet();
}

async function hideAllWindows(includeQuotio = false): Promise<void> {
  log("Hiding all other windows...");
  const excludeApps = includeQuotio
    ? `name is not "CleanShot X"`
    : `name is not "${CONFIG.appName}" and name is not "CleanShot X"`;

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
  
  await runAppleScript(`
    tell application "Finder"
      close every window
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
  await compressPng(outputPath);

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

async function captureScreen(
  screen: ScreenDef,
  mode: AppearanceMode,
  outputDir: string,
  wallpaperPath: string
): Promise<void> {
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
        await captureWindow(join(outputDir, `${screen.id}${suffix}.png`), wallpaperPath);
      },
      CONFIG.retryAttempts,
      CONFIG.retryDelay
    );
  }
}

async function captureSelectedScreens(
  options: CaptureOptions,
  outputDir: string,
  wallpapers: { light: string; dark: string }
): Promise<void> {
  for (const mode of options.themes) {
    log(`\n📸 Capturing in ${mode} mode...`);
    await setAppearance(mode);
    const wallpaperPath = wallpapers[mode];
    await setWallpaper(wallpaperPath);
    await activateApp();
    await resizeWindow();

    for (const screen of options.screens) {
      await captureScreen(screen, mode, outputDir, wallpaperPath);
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

  // App source selection
  const apps = detectAvailableApps();
  const appSource = await selectAppSource(apps);
  if (!appSource) {
    p.cancel("Operation cancelled.");
    return null;
  }

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
  p.log.info(`App: ${appSource === "local" ? "Local build" : "Installed"}`);

  return {
    themes,
    screens: selectedScreens,
    appSource,
  };
}

function parseCliArgs(): CaptureOptions | "interactive" {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    return "interactive";
  }

  const hasLight = args.includes("--light");
  const hasDark = args.includes("--dark");
  const hasBoth = args.includes("--both");
  const hasLocal = args.includes("--local");

  let themes: AppearanceMode[];
  if (hasBoth || (hasLight && hasDark)) {
    themes = ["light", "dark"];
  } else if (hasDark) {
    themes = ["dark"];
  } else if (hasLight) {
    themes = ["light"];
  } else {
    themes = ["light", "dark"];
  }

  const appSource: AppSource = hasLocal ? "local" : "installed";

  return {
    themes,
    screens: SCREENS,
    appSource,
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

  const originalMode = await getCurrentAppearance();
  log(`Current appearance: ${originalMode}`);

  const originalWallpaper = await getCurrentWallpaper();
  log(`Current wallpaper: ${originalWallpaper.split("/").pop()}`);

  const spinner = p.spinner();
  spinner.start("Preparing capture environment...");

  const appPath = getAppPath(options.appSource);
  const wallpapers = await ensureWallpapers();

  try {
    await hideDesktopIcons();
    await launchApp(appPath);
    spinner.stop("Environment ready");

    await captureSelectedScreens(options, outputDir, wallpapers);
  } finally {
    await setAppearance(originalMode);
    if (originalWallpaper) {
      await setWallpaper(originalWallpaper);
    }
    await showDesktopIcons();
  }

  p.outro(`✅ Captured ${options.screens.length} screens × ${options.themes.length} themes`);
  log(`📁 Output: ${outputDir}`);
  
  await $`open ${outputDir}`.quiet();
}

main().catch((error) => {
  console.error("❌ Fatal error:", error);
  process.exit(1);
});
