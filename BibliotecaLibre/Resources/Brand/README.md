# Libron-X artwork

Design by Esteban. The owner supplied and approved the original PNG reference. The vectors trace that reference, retaining the emblem and lettering rather than substituting a font.

The project code license does not license this artwork under MIT. Inclusion is authorized for Libron-X; no separate open artwork license is declared.

| Folder | Purpose |
| --- | --- |
| `reference` | Unmodified owner-supplied source image |
| `vector` | Editable path-based compositions and emblem variants |
| `raster`, `pdf` | Rendered exports |
| `iconset`, `macOS` | Earlier Mac icon work and source geometry |
| `verification` | Historical tracing and visual comparison evidence |

The current app builder uses the approved files in `../AppIcons/Approved-Cristal/`. It does not regenerate branding. Earlier variants remain available for provenance and comparison.

`vectorize-brand.py` and `verify-brand.py` are optional authoring tools. Their dependencies are in `scripts/requirements-brand.txt`. Comparison metrics describe thresholded image masks, not pixel-identical appearance or acceptance of every later icon variant. Do not regenerate or replace approved artwork during an ordinary app build.
