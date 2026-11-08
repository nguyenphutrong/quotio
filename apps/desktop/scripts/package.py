#!/usr/bin/env python3
"""Build local desktop packages. Never publish, upload feeds, or change tags."""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
from urllib.parse import urlparse
import zipfile

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "apps/desktop"


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def macos(args, binary, output):
    if sys.platform != "darwin":
        raise ValueError("macOS packaging requires a Mac")
    for arch in ("x86_64", "arm64"):
        run("lipo", binary, "-verify_arch", arch)
    build = subprocess.check_output(["vtool", "-show-build", str(binary)], text=True)
    minimums = re.findall(r"\bminos\s+(\S+)", build)
    if len(minimums) != 2 or any(version not in ("14.0", "14.0.0") for version in minimums):
        raise ValueError("Both binary slices must target macOS 14.0; rebuild with MACOSX_DEPLOYMENT_TARGET=14.0")
    if not args.sparkle_framework or not args.feed_url or not args.public_key or not args.build_number:
        raise ValueError("macOS requires --sparkle-framework, --feed-url, --public-key and --build-number")
    if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        raise ValueError("Build number must be a positive integer, greater than the last installed Swift build")
    if len(base64.b64decode(args.public_key, validate=True)) != 32:
        raise ValueError("Sparkle requires a 32-byte base64 Ed25519 public key")
    feed = urlparse(args.feed_url)
    local_feed = args.allow_local_feed and args.bundle_id.endswith(".preview") and feed.scheme == "http" and feed.hostname in ("localhost", "127.0.0.1", "::1")
    if not (feed.scheme == "https" and feed.hostname and not feed.username and not feed.password) and not local_feed:
        raise ValueError("Use an HTTPS feed, or explicitly allow a loopback test feed for a .preview bundle")
    framework = args.sparkle_framework.resolve()
    with (framework / "Resources/Info.plist").open("rb") as file:
        if plistlib.load(file).get("CFBundleShortVersionString") != "2.8.1":
            raise ValueError("Use the verified Sparkle 2.8.1 framework")
    run("codesign", "--verify", "--deep", "--strict", framework)
    bundle = output / f"{args.name}.app"
    contents = bundle / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    shutil.copy2(binary, contents / "MacOS/quotio-desktop")
    shutil.copytree(framework, contents / "Frameworks/Sparkle.framework", symlinks=True)
    info = {
        "CFBundleIdentifier": args.bundle_id, "CFBundleName": args.name,
        "CFBundleDisplayName": args.name, "CFBundleExecutable": "quotio-desktop",
        "CFBundlePackageType": "APPL", "CFBundleIconFile": "AppIcon",
        "CFBundleShortVersionString": args.version, "CFBundleVersion": args.build_number,
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "NSHighResolutionCapable": True, "LSApplicationCategoryType": "public.app-category.developer-tools",
        "NSLocalNetworkUsageDescription": "Share quota with devices you pair on your local network.",
        "CFBundleURLTypes": [{"CFBundleURLName": args.bundle_id, "CFBundleURLSchemes": [args.url_scheme]}],
        "SUFeedURL": args.feed_url, "SUPublicEDKey": args.public_key,
        "QuotioUpdateChannel": args.update_channel,
        "SUEnableAutomaticChecks": False, "SUScheduledCheckInterval": 86400,
    }
    if local_feed:
        info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    with tempfile.TemporaryDirectory(prefix="quotio-icon-") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                run("sips", "-z", size * scale, size * scale, APP / "assets/app-icon.png", "--out", iconset / f"icon_{size}x{size}{suffix}.png", stdout=subprocess.DEVNULL)
        run("iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns")
    machos = []
    for path in contents.rglob("*"):
        if path.is_file() and not path.is_symlink() and path != contents / "MacOS/quotio-desktop":
            if "Mach-O" in subprocess.check_output(["file", str(path)], text=True):
                for arch in ("x86_64", "arm64"):
                    run("lipo", path, "-verify_arch", arch)
                machos.append(path)
    if args.sign_identity:
        flags = ["--force", "--sign", args.sign_identity, "--options", "runtime", "--timestamp"]
        for path in machos:
            run("codesign", *flags, "--preserve-metadata=identifier,entitlements", path)
        nested = [path for path in contents.rglob("*") if path.is_dir() and not path.is_symlink() and path.suffix in (".framework", ".xpc", ".app", ".appex")]
        for path in sorted(nested, key=lambda path: len(path.parts), reverse=True):
            run("codesign", *flags, "--preserve-metadata=identifier,entitlements", path)
        run("codesign", *flags, "--identifier", "dev.quotio.cli", bundle)
    else:
        run("codesign", "--force", "--deep", "--sign", "-", bundle)
    run("codesign", "--verify", "--deep", "--strict", bundle)

    def notarize(path, kind):
        if args.notary_profile:
            run("xcrun", "notarytool", "submit", path, "--keychain-profile", args.notary_profile, "--wait")
        else:
            run("asc", "notarization", "submit", "--file", path, "--wait")
        run("xcrun", "stapler", "staple", kind)
        run("xcrun", "stapler", "validate", kind)

    stem = f"QuotioDesktop-{args.version}-macos-universal"
    archive = output / f"{stem}.zip"
    if args.notary_profile or args.notarize_asc:
        with tempfile.TemporaryDirectory(prefix="quotio-notary-") as temporary:
            submission = Path(temporary) / "submission.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, submission)
            notarize(submission, bundle)
        run("spctl", "--assess", "--type", "execute", "--verbose=2", bundle)
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, archive)
    dmg = output / f"{stem}.dmg"
    with tempfile.TemporaryDirectory(prefix="quotio-dmg-") as temporary:
        staging = Path(temporary)
        run("ditto", bundle, staging / bundle.name)
        (staging / "Applications").symlink_to("/Applications")
        run("hdiutil", "create", "-volname", args.name, "-srcfolder", staging, "-format", "UDZO", dmg)
    if args.sign_identity:
        run("codesign", "--force", "--sign", args.sign_identity, "--timestamp", dmg)
        run("codesign", "--verify", "--strict", dmg)
    if args.notary_profile or args.notarize_asc:
        notarize(dmg, dmg)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg)


def portable(args, binary, output):
    windows = args.target == "x86_64-pc-windows-msvc"
    with binary.open("rb") as file:
        if not file.read(4).startswith(b"MZ" if windows else b"\x7fELF"):
            raise ValueError("Input binary does not match the selected platform")
    asset = f"quotio-desktop-{args.target}" + (".exe" if windows else "")
    shutil.copy2(binary, output / asset)
    with tempfile.TemporaryDirectory(prefix="quotio-portable-") as temporary:
        package = Path(temporary) / f"quotio-desktop-{args.version}"
        package.mkdir()
        exe = package / ("quotio-desktop.exe" if windows else "quotio-desktop")
        shutil.copy2(binary, exe)
        exe.chmod(0o755)
        shutil.copy2(ROOT / "LICENSE", package / "LICENSE")
        shutil.copy2(APP / "assets/app-icon.png", package / "app.quotio.Quotio.png")
        notes = "Quotio Desktop preview\n\nExtract to a user-writable folder. Run quotio-desktop" + (".exe" if windows else "") + ".\n"
        notes += "No administrator access, service, proxy or sharing listener is installed.\nThe in-app updater verifies Ed25519 signatures; it needs write access beside the executable.\n"
        if windows:
            notes += "Windows x64. This portable build has no Authenticode signature; Windows may show SmartScreen warnings.\n"
        else:
            notes += "Linux x64, Ubuntu 24.04 or compatible glibc 2.39+. Requires Vulkan with a working GPU driver, X11/Wayland, fontconfig, FreeType and xkbcommon.\nOptionally install the binary in ~/.local/bin, the PNG in ~/.local/share/icons/hicolor/512x512/apps, and the desktop file in ~/.local/share/applications.\n"
            (package / "app.quotio.Quotio.desktop").write_text("[Desktop Entry]\nType=Application\nName=Quotio\nExec=quotio-desktop\nIcon=app.quotio.Quotio\nTerminal=false\nCategories=Utility;\nStartupWMClass=app.quotio.Quotio\n")
        (package / "README.txt").write_text(notes)
        if windows:
            with zipfile.ZipFile(output / f"{asset[:-4]}.zip", "w", zipfile.ZIP_DEFLATED) as archive:
                for path in package.iterdir():
                    archive.write(path, f"{package.name}/{path.name}")
        else:
            with tarfile.open(output / f"{asset}.tar.gz", "w:gz") as archive:
                archive.add(package, arcname=package.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, choices=["universal-apple-darwin", "x86_64-unknown-linux-gnu", "x86_64-pc-windows-msvc"])
    parser.add_argument("--output", type=Path, required=True, help="New output directory; never overwritten")
    parser.add_argument("--binary", type=Path, help="Use an already built binary instead of building")
    parser.add_argument("--name", default="Quotio Desktop Preview")
    parser.add_argument("--bundle-id", default="app.bytrong.quotio.preview")
    parser.add_argument("--url-scheme", default="quotio-gpui-preview")
    parser.add_argument("--version", default=tomllib.loads((APP / "Cargo.toml").read_text())["package"]["version"])
    parser.add_argument("--build-number")
    parser.add_argument("--sparkle-framework", type=Path, help="Locally verified Sparkle 2.8.1; no implicit download")
    parser.add_argument("--feed-url")
    parser.add_argument("--public-key", help="Sparkle public key, never the private signing key")
    parser.add_argument("--update-channel", choices=["stable", "beta"], default="stable")
    parser.add_argument("--sign-identity", help="Developer ID Application signing identity")
    parser.add_argument("--allow-local-feed", action="store_true")
    notary = parser.add_mutually_exclusive_group()
    notary.add_argument("--notary-profile")
    notary.add_argument("--notarize-asc", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}", args.name) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", args.version):
        parser.error("Invalid name or version")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_id) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9+.-]*", args.url_scheme):
        parser.error("Invalid bundle ID or URL scheme")
    if (args.notary_profile or args.notarize_asc) and (not args.sign_identity or args.target != "universal-apple-darwin"):
        parser.error("Notarization requires a signed macOS bundle")
    if args.bundle_id == "app.bytrong.quotio.beta" and args.update_channel != "beta":
        parser.error("The beta bundle requires --update-channel beta")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    target_dir = Path(os.environ.get("CARGO_TARGET_DIR", APP / "target")).resolve()
    binary = args.binary.resolve() if args.binary else None
    if not binary:
        targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"] if args.target == "universal-apple-darwin" else [args.target]
        for target in targets:
            run("cargo", "build", "--manifest-path", APP / "Cargo.toml", "--locked", "--release", "--target", target, env={**os.environ, "MACOSX_DEPLOYMENT_TARGET": "14.0", "CARGO_TARGET_DIR": str(target_dir)})
        if len(targets) == 2:
            binary = output / ".quotio-universal"
            run("lipo", "-create", *(target_dir / target / "release/quotio-desktop" for target in targets), "-output", binary)
        else:
            binary = target_dir / targets[0] / "release" / ("quotio-desktop.exe" if args.target.endswith("windows-msvc") else "quotio-desktop")
    if args.target == "universal-apple-darwin":
        macos(args, binary, output)
    else:
        portable(args, binary, output)
    if binary == output / ".quotio-universal":
        binary.unlink()
    sums = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in sorted(output.iterdir()) if path.is_file()]
    (output / f"quotio-desktop-{args.target}.SHA256SUMS").write_text("".join(sums))
    print(f"Local packages: {output}. Nothing published; update archives still need their release signatures.")


if __name__ == "__main__":
    main()
