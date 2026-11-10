#!/usr/bin/env python3
"""Validate source icon slots and, optionally, the built .app or .xcarchive."""

import json
from pathlib import Path
import plistlib
import struct
import sys


def png_info(path):
    with path.open("rb") as image:
        assert image.read(8) == b"\x89PNG\r\n\x1a\n", f"Not a PNG: {path}"
        while True:
            header = image.read(8)
            assert len(header) == 8, f"Missing PNG header: {path}"
            length, kind = struct.unpack(">I4s", header)
            data = image.read(length)
            image.read(4)  # CRC
            if kind == b"IHDR":
                width, height, depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", data)
                return width, height, depth, color_type


repo = Path(__file__).resolve().parents[1]
assets = repo / "色々変え/Assets.xcassets/AppIcon.appiconset"
contents = json.loads((assets / "Contents.json").read_text())
slots = {}
for image in contents["images"]:
    key = (image["idiom"], image["size"], image["scale"])
    assert key not in slots, f"Duplicate icon slot: {key}"
    slots[key] = image
    point_width, point_height = map(float, image["size"].split("x"))
    scale = float(image["scale"].removesuffix("x"))
    path = assets / image["filename"]
    width, height, depth, color_type = png_info(path)
    assert (width, height) == (round(point_width * scale), round(point_height * scale)), f"Wrong dimensions: {path}"
    assert depth == 8 and color_type == 2, f"Icon must be opaque 8-bit RGB without alpha: {path}"

required_slots = (
    [("iphone", f"{size}x{size}", f"{scale}x") for size in (20, 29, 40, 60) for scale in (2, 3)]
    + [("ipad", f"{size}x{size}", f"{scale}x") for size in (20, 29, 40, 76) for scale in (1, 2)]
    + [("ipad", "83.5x83.5", "2x"), ("ios-marketing", "1024x1024", "1x")]
)
for slot in required_slots:
    assert slot in slots, f"Missing icon slot: {slot}"
print(f"PASS: {len(slots)} source icon slots, exact dimensions, opaque RGB PNGs")

if len(sys.argv) > 1:
    bundle = Path(sys.argv[1]).resolve()
    if bundle.suffix == ".xcarchive":
        apps = list((bundle / "Products/Applications").glob("*.app"))
        assert len(apps) == 1, f"Expected one app in archive: {bundle}"
        bundle = apps[0]
    assert bundle.suffix == ".app", "Pass a .app or .xcarchive path"
    with (bundle / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    assert info["CFBundleIdentifier"] == "dev.somayumoto.IroIroKae"
    for dictionary, expected_size in (("CFBundleIcons", 120), ("CFBundleIcons~ipad", 152)):
        primary = info[dictionary]["CFBundlePrimaryIcon"]
        assert primary["CFBundleIconName"] == "AppIcon", f"Wrong/missing icon name: {dictionary}"
        names = primary["CFBundleIconFiles"]
        assert names, f"Missing icon file references: {dictionary}"
        referenced = [path for path in bundle.glob("*.png") if any(path.stem.startswith(Path(name).stem) for name in names)]
        assert any(png_info(path)[:2] == (expected_size, expected_size) for path in referenced), f"Missing referenced {expected_size}x{expected_size} PNG in {bundle}"
        print(f"PASS: {dictionary} references AppIcon and a {expected_size}x{expected_size} PNG")
    assert (bundle / "Assets.car").is_file(), "Missing compiled asset catalog"
    print(f"PASS: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}) bundle icons in {bundle}")
