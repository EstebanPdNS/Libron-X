#!/usr/bin/env python3
"""Validate traced assets and render a comparison sheet for visual review.

The approved logo itself has no font substitution. A system font is used only
for comparison-sheet labels, outside the delivered vector artwork.
"""

from __future__ import annotations

import json
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader

PROJECT = Path(__file__).resolve().parents[1]
BRAND = PROJECT / "Resources/Brand"
SVG_NAMESPACE = "{http://www.w3.org/2000/svg}"


def composite_tile(source: Path, size: tuple[int, int], color: str) -> Image.Image:
    image = Image.open(source).convert("RGBA")
    image.thumbnail(size, Image.Resampling.LANCZOS)
    tile = Image.new("RGBA", size, color)
    offset = ((size[0] - image.width) // 2, (size[1] - image.height) // 2)
    tile.alpha_composite(image, offset)
    return tile.convert("RGB")


def comparison_sheet() -> Path:
    font_path = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
    font = (
        ImageFont.truetype(str(font_path), 24)
        if font_path.exists()
        else ImageFont.load_default(size=24)
    )
    sheet = Image.new("RGB", (1680, 1580), "#eeeeea")
    labels = ImageDraw.Draw(sheet)
    compositions = [
        ("reference/Libron-X-official-Esteban.png", "Original aprobado", "#ffffff"),
        ("raster/Libron-X-color-1024.png", "Trazado: color", "#ffffff"),
        ("raster/Libron-X-color-dark-1024.png", "Trazado: fondo oscuro", "#202020"),
    ]
    for index, (filename, title, background) in enumerate(compositions):
        x = 25 + index * 555
        labels.text((x, 20), title, fill="#202020", font=font)
        sheet.paste(composite_tile(BRAND / filename, (530, 530), background), (x, 65))

    emblems = [
        ("Libron-X-emblem-red-white", "Rojo + interior blanco", "#202020"),
        ("Libron-X-emblem-red", "Rojo / huecos transparentes", "#ffffff"),
        ("Libron-X-emblem-black", "Monocromo negro", "#ffffff"),
        ("Libron-X-emblem-white", "Monocromo blanco", "#202020"),
    ]
    for index, (stem, title, background) in enumerate(emblems):
        x = 25 + index * 415
        labels.text((x, 625), title, fill="#202020", font=font)
        tile = composite_tile(BRAND / f"raster/{stem}-1024.png", (380, 430), background)
        sheet.paste(tile, (x, 670))

    labels.text(
        (25, 1130),
        "Icono: lienzo transparente y silueta original sin deformación",
        fill="#202020",
        font=font,
    )
    for index, logical in enumerate([16, 32, 128, 256, 512]):
        x = 25 + index * 330
        labels.text((x, 1175), f"{logical}px / 2×", fill="#202020", font=font)
        file = BRAND / f"iconset/LibronX.iconset/icon_{logical}x{logical}@2x.png"
        image = Image.open(file).convert("RGBA")
        if logical < 128:
            image = image.resize((logical * 4, logical * 4), Image.Resampling.NEAREST)
        else:
            image.thumbnail((280, 280), Image.Resampling.LANCZOS)
        tile = Image.new("RGBA", (290, 300), "#ffffff")
        tile.alpha_composite(
            image, ((290 - image.width) // 2, (300 - image.height) // 2)
        )
        sheet.paste(tile.convert("RGB"), (x, 1225))

    output = BRAND / "verification/brand-proof.png"
    sheet.save(output)
    return output


def validate() -> dict:
    result = {"svg": [], "pdf": [], "png": [], "iconset": []}
    for file in sorted((BRAND / "vector").glob("Libron-X-*.svg")):
        root = ET.parse(file).getroot()
        unexpected = [
            element.tag
            for element in root.iter()
            if element.tag.split("}")[-1]
            in {"text", "image", "foreignObject", "script"}
        ]
        if unexpected:
            raise ValueError(
                f"Unexpected non-path artwork in {file.name}: {unexpected}"
            )
        result["svg"].append(
            {
                "name": file.name,
                "path_count": len(root.findall(f".//{SVG_NAMESPACE}path")),
                "font_or_embedded_bitmap": False,
            }
        )

    for file in sorted((BRAND / "pdf").glob("*.pdf")):
        reader = PdfReader(file)
        image_count = font_count = stream_bytes = 0
        for page in reader.pages:
            resources = page["/Resources"]
            font_count += len(resources.get("/Font", {}))
            image_count += sum(
                1
                for value in resources.get("/XObject", {}).values()
                if value.get_object().get("/Subtype") == "/Image"
            )
            stream_bytes += len(page.get_contents().get_data())
        if len(reader.pages) != 1 or image_count or font_count or not stream_bytes:
            raise ValueError(f"PDF is not a single page of path artwork: {file.name}")
        result["pdf"].append(
            {
                "name": file.name,
                "pages": len(reader.pages),
                "image_xobjects": image_count,
                "font_resources": font_count,
                "content_stream_bytes": stream_bytes,
            }
        )

    for file in sorted((BRAND / "raster").glob("*.png")):
        image = Image.open(file)
        if image.mode != "RGBA" or image.getpixel((0, 0))[3] != 0:
            raise ValueError(f"Expected transparent RGBA artwork: {file.name}")
        result["png"].append(
            {
                "name": file.name,
                "size": list(image.size),
                "mode": image.mode,
                "transparent_corner": True,
            }
        )

    for logical in [16, 32, 128, 256, 512]:
        for multiple in [1, 2]:
            suffix = "@2x" if multiple == 2 else ""
            name = f"icon_{logical}x{logical}{suffix}.png"
            source = BRAND / "iconset/LibronX.iconset" / name
            output = PROJECT / "Resources/LibronX.iconset" / name
            image = Image.open(source)
            if (
                image.size != (logical * multiple, logical * multiple)
                or image.mode != "RGBA"
                or source.read_bytes() != output.read_bytes()
            ):
                raise ValueError(f"Invalid or stale app icon: {name}")
            result["iconset"].append(
                {"name": name, "size": list(image.size), "build_copy_equal": True}
            )

    icns = (PROJECT / "Resources/LibronX.icns").read_bytes()
    if icns[:4] != b"icns" or struct.unpack(">I", icns[4:8])[0] != len(icns):
        raise ValueError("Invalid ICNS container header")
    result["icns"] = {"bytes": len(icns), "valid_magic_and_length": True}
    return result


def main() -> None:
    report = validate()
    proof = comparison_sheet()
    report["comparison_sheet"] = str(proof.relative_to(PROJECT))
    report["visual_review_required"] = (
        "Inspect the sheet and rasterize the vector PDF independently; this script does not certify perceptual identity."
    )
    (BRAND / "verification/asset-validation.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    )
    print(
        f"Validated {len(report['svg'])} SVG, {len(report['pdf'])} vector PDF, {len(report['png'])} PNG and {len(report['iconset'])} macOS icon sizes."
    )
    print(f"Visual review: {proof}")


if __name__ == "__main__":
    main()
