#!/usr/bin/env python3
"""Inject standalone alternate icon PNGs and Info.plist declarations.

`flutter build ios --no-codesign` produces an unsigned bundle. Shipping the
alternate icons only inside Assets.car is unreliable for a fakesigned IPA:
setAlternateIconName can fail with OSStatus -54 when the catalog is not sealed
under the same signature. This script runs on the unpacked Runner.app *before*
the ad-hoc codesign in sign_ios.sh, so the icons are ordinary files in the
bundle root and the CFBundleIcons declarations point at them.
"""
import argparse
import json
import plistlib
import shutil
from pathlib import Path

ICONS = {
    f"AppIcon-{name}"
    for name in (
        "Classic",
        "Dark",
        "Neon",
        "Sunset",
        "Emerald",
        "Sakura",
        "Titanium",
        "Purple",
    )
}


def prepare(app: Path, assets: Path) -> None:
    info_path = app / "Info.plist"
    if not info_path.exists():
        raise SystemExit(f"missing Info.plist: {info_path}")
    info = plistlib.loads(info_path.read_bytes())

    # Xcode compiles the primary icon into Assets.car and does not write a
    # CFBundleIcons dictionary into the source plist. Once we add alternate
    # entries, declare the primary icon too so the bundle icon dictionary is
    # complete on both iPhone and iPad.
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        info.setdefault(key, {}).setdefault(
            "CFBundlePrimaryIcon", {"CFBundleIconName": "AppIcon"}
        )

    for name in sorted(ICONS):
        folder = assets / f"{name}.appiconset"
        contents = folder / "Contents.json"
        if not contents.exists():
            raise SystemExit(f"missing icon set: {folder}")
        entries = json.loads(contents.read_text())["images"]
        files = {"iphone": set(), "ipad": set()}
        for entry in entries:
            idiom = entry["idiom"]
            if idiom not in files:
                continue
            base = name + entry["size"]
            scale = entry["scale"]
            suffix = f"@{scale}" if scale != "1x" else ""
            filename = f"{base}{suffix}.png"
            source = folder / entry["filename"]
            if not source.exists():
                raise SystemExit(f"missing icon png: {source}")
            shutil.copyfile(source, app / filename)
            # iOS appends @2x/@3x to the CFBundleIconFiles base name itself.
            files[idiom].add(base)

        for key, idiom in (("CFBundleIcons", "iphone"), ("CFBundleIcons~ipad", "ipad")):
            icon = (
                info.setdefault(key, {})
                .setdefault("CFBundleAlternateIcons", {})
                .setdefault(name, {})
            )
            icon["CFBundleIconName"] = name
            icon["CFBundleIconFiles"] = sorted(files[idiom])

    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    print(f"prepared {len(ICONS)} alternate icons in {app}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.app, args.assets)


if __name__ == "__main__":
    main()
