#!/usr/bin/env python3
"""Trace Esteban's approved artwork as paths, without replacing its lettering.
Tool licenses do not grant an open license to the supplied artwork.
"""

from __future__ import annotations
import argparse, copy, hashlib, json, re, shutil, subprocess
from pathlib import Path
import xml.etree.ElementTree as ET
import cairosvg
import numpy as np
from PIL import Image
import vtracer

SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)
COLORS = {"red": "#ec0812", "ink": "#121212", "white": "#ffffff"}
OPTIONS = dict(
    colormode="binary",
    mode="spline",
    filter_speckle=4,
    corner_threshold=55,
    length_threshold=3.5,
    max_iterations=20,
    splice_threshold=45,
    path_precision=3,
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bbox(mask):
    y, x = np.nonzero(mask)
    if not len(x):
        raise ValueError("Expected artwork color has no visible pixels")
    return [int(x.min()), int(y.min()), int(x.max() + 1), int(y.max() + 1)]


def node(name, **attrs):
    return ET.Element(f"{{{SVG}}}{name}", attrs)


def document(box, title):
    root = node(
        "svg",
        version="1.1",
        width=str(box[2]),
        height=str(box[3]),
        viewBox=" ".join(f"{v:g}" for v in box),
    )
    ET.SubElement(root, f"{{{SVG}}}title").text = title
    ET.SubElement(root, f"{{{SVG}}}desc").text = (
        "Libron-X artwork by Esteban. Emblem and lettering traced from the approved PNG; fitted curves, not substituted font glyphs."
    )
    ET.SubElement(root, f"{{{SVG}}}metadata").text = (
        "Artwork author: Esteban. No open artwork license asserted. Tool/code licenses are separate. Raster texture flattened to median colors."
    )
    return root


def painted(paths, color, identifier):
    group = node("g", id=identifier, fill=color)
    for path in paths:
        child = copy.deepcopy(path)
        child.set("fill", color)
        group.append(child)
    return group


def emblem(paths, color, white_holes):
    group = node("g", id="emblem")
    if white_holes:
        for path in paths:
            outer = copy.deepcopy(path)
            outer.set("d", re.split(r"(?=M)", path.get("d", ""))[1])
            outer.set("fill", COLORS["white"])
            group.append(outer)
    group.append(painted(paths, color, "emblem-ink"))
    return group


def save(root, path):
    ET.indent(root, space="  ")
    path.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True))


def render(svg, png, width, height=None):
    cairosvg.svg2png(
        url=str(svg), write_to=str(png), output_width=width, output_height=height
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--minimal", action="store_true")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    brand = project / "Resources/Brand"
    for folder in [
        "reference",
        "vector",
        "raster",
        "pdf",
        "verification",
        "iconset/LibronX.iconset",
    ]:
        (brand / folder).mkdir(parents=True, exist_ok=True)
    reference = brand / "reference/Libron-X-official-Esteban.png"
    if args.source and args.source.resolve() != reference.resolve():
        shutil.copyfile(args.source, reference)
    if not reference.exists():
        parser.error("Supply the approved PNG with --source")
    original = Image.open(reference).convert("RGB")
    width, height = original.size
    pixels = np.array(original).astype(np.int16)
    masks = {
        "emblem": (pixels[:, :, 0] - pixels[:, :, 1] > 110)
        & (pixels[:, :, 0] - pixels[:, :, 2] > 110),
        "wordmark": np.max(pixels, axis=2) < 130,
    }
    boxes = {name: bbox(mask) for name, mask in masks.items()}
    paths = {}
    for name, mask in masks.items():
        temporary = brand / "verification" / f"{name}-binary.png"
        Image.fromarray(np.where(mask, 0, 255).astype(np.uint8)).save(temporary)
        output = brand / "vector" / f"traced-{name}.svg"
        vtracer.convert_image_to_svg_py(str(temporary), str(output), **OPTIONS)
        paths[name] = list(ET.parse(output).getroot())
    variants = {
        "Libron-X-color": (COLORS["red"], COLORS["ink"], True),
        "Libron-X-color-dark": (COLORS["red"], COLORS["white"], True),
        "Libron-X-black": (COLORS["ink"], COLORS["ink"], False),
        "Libron-X-white": (COLORS["white"], COLORS["white"], False),
    }
    if args.minimal:
        variants = {"Libron-X-color": variants["Libron-X-color"]}
    svgs = []
    for name, (red, ink, white) in variants.items():
        root = document([0, 0, width, height], name)
        root.append(emblem(paths["emblem"], red, white))
        root.append(painted(paths["wordmark"], ink, "wordmark"))
        svg = brand / "vector" / f"{name}.svg"
        save(root, svg)
        svgs.append(svg)
        render(svg, brand / "raster" / f"{name}-1024.png", 1024, 1024)
    x0, y0, x1, y1 = boxes["emblem"]
    bw, bh = x1 - x0, y1 - y0
    scale = 880 / bw
    icon = document([0, 0, 1024, 1024], "Libron-X approved app emblem")
    fit = node(
        "g",
        transform=f"translate(72 {(1024-bh*scale)/2:.6f}) scale({scale:.9f}) translate({-x0} {-y0})",
    )
    fit.append(emblem(paths["emblem"], COLORS["red"], True))
    icon.append(fit)
    icon_svg = brand / "vector/Libron-X-app-icon.svg"
    save(icon, icon_svg)
    icon_base = brand / "raster/Libron-X-app-icon-1024.png"
    render(icon_svg, icon_base, 1024, 1024)
    shutil.copyfile(icon_base, project / "Resources/LibronX-1024.png")
    iconset = project / "Resources/LibronX.iconset"
    iconset.mkdir(exist_ok=True)
    for logical in [16, 32, 128, 256, 512]:
        for multiple in [1, 2]:
            suffix = "@2x" if multiple == 2 else ""
            name = f"icon_{logical}x{logical}{suffix}.png"
            output = brand / "iconset/LibronX.iconset" / name
            render(icon_svg, output, logical * multiple, logical * multiple)
            shutil.copyfile(output, iconset / name)
    subprocess.run(
        [
            "/usr/bin/iconutil",
            "-c",
            "icns",
            str(iconset),
            "-o",
            str(project / "Resources/LibronX.icns"),
        ],
        check=True,
    )
    if not args.minimal:
        for name, color, white in [
            ("Libron-X-emblem-red", COLORS["red"], False),
            ("Libron-X-emblem-red-white", COLORS["red"], True),
            ("Libron-X-emblem-black", COLORS["ink"], False),
            ("Libron-X-emblem-white", COLORS["white"], False),
        ]:
            root = document([x0 - 8, y0 - 8, bw + 16, bh + 16], name)
            root.append(emblem(paths["emblem"], color, white))
            svg = brand / "vector" / f"{name}.svg"
            save(root, svg)
            svgs.append(svg)
            render(svg, brand / "raster" / f"{name}-1024.png", 1024)
        tx0, ty0, tx1, ty1 = boxes["wordmark"]
        for name, color in [
            ("Libron-X-wordmark-black", COLORS["ink"]),
            ("Libron-X-wordmark-white", COLORS["white"]),
        ]:
            root = document([tx0 - 4, ty0 - 4, tx1 - tx0 + 8, ty1 - ty0 + 8], name)
            root.append(painted(paths["wordmark"], color, "wordmark"))
            svg = brand / "vector" / f"{name}.svg"
            save(root, svg)
            svgs.append(svg)
            render(svg, brand / "raster" / f"{name}-1024.png", 1024)
        for svg in svgs + [icon_svg]:
            cairosvg.svg2pdf(
                url=str(svg), write_to=str(brand / "pdf" / f"{svg.stem}.pdf")
            )
    metrics = {}
    for name, mask in masks.items():
        png = brand / "verification" / f"{name}-vector.png"
        render(brand / "vector" / f"traced-{name}.svg", png, width, height)
        traced = np.array(Image.open(png).convert("RGBA"))[:, :, 3] >= 128
        metrics[name] = {
            "intersection_over_union": float(
                np.sum(mask & traced) / np.sum(mask | traced)
            ),
            "different_mask_pixels": int(np.sum(mask != traced)),
            "source_bbox": boxes[name],
            "path_count": len(paths[name]),
            "compound_subpaths": sum(p.get("d", "").count("M") for p in paths[name]),
        }
    report = {
        "artwork_author": "Esteban",
        "artwork_license": "No open artwork license asserted; tool/code licenses are separate",
        "reference": str(reference.relative_to(project)),
        "reference_sha256": sha(reference),
        "source_size": [width, height],
        "palette": COLORS,
        "trace_options": OPTIONS,
        "thresholds": {"red_difference": 110, "ink_max_channel": 130},
        "metrics": metrics,
        "lettering": "Traced paths only, no font replacement",
        "texture": "Flattened to median colors",
        "icon_fit": {"canvas": 1024, "width": 880, "aspect_ratio_preserved": True},
        "generator_package": "vtracer 0.6.15; embedded generator identifies engine 0.6.12",
        "renderer": f"CairoSVG {cairosvg.__version__}",
        "pixel_identical_claim": False,
        "files": [
            {
                "path": str(p.relative_to(project)),
                "bytes": p.stat().st_size,
                "sha256": sha(p),
            }
            for p in sorted(brand.rglob("*"))
            if p.is_file() and p.suffix in [".svg", ".png", ".pdf"]
        ],
    }
    (brand / "verification/trace-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    )
    print(
        json.dumps(
            {
                "icon": str(project / "Resources/LibronX.icns"),
                "metrics": metrics,
                "minimal": args.minimal,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
