# Deterministic import presentation

The package keeps the exact original payload and its SHA-256. Presentation
normalization runs during native conversion and remains available in the reader
for resources not yet normalized. It does not rewrite a user's source database or invent text.

`ImportFormattingPipeline` prepares HTML for the native parser, retains semantic
structure and safe stylesheet rules, removes active or externally loaded
surfaces, and repairs narrowly observed legacy character substitutions inside
Latin-majority words. Real Greek and Hebrew words remain unchanged. One-to-one
UTF-16 repairs preserve formatting ranges and verse anchors.

`ImportedTypography` adapts imported foreground colors to light/dark appearance,
removes neutral paper backgrounds, retains emphasis, applies bounded font sizes,
and scales paragraph geometry together with text zoom. Appearance adaptation
never changes the anchored text. The selected system font remains a reader
preference. Imported HTML tables and lists retain their native text structures.

Each e-Sword import writes `import-formatting-audit.json` beside the immutable
payload. This is a derived diagnostic, not part of resource identity. It records
entry counts, detected body formats, observed repairs and empty source entries.
It is not proof of complete semantic equivalence for every proprietary dialect.

## Audit an original file

```sh
scripts/audit-import-formatting.sh /path/to/dictionary.dcti > /path/to/audit.json
```

## Re-audit an existing managed library

Build `libronix-inspect` with Swift Package Manager, then pass its absolute path:

```sh
scripts/audit-library-imports.py --library /path/to/Library \
  --inspect /path/to/libronix-inspect --report /path/to/import-audit.json \
  --write-sidecars
```

Omit `--write-sidecars` for read-only inspection. Both paths use the same core
normalization code as the application. The batch script verifies every payload
against its manifest before auditing and checks again afterwards.

Regression coverage includes rich emphasis, emoji, Greek/Hebrew, RTL direction,
tables, lists, paragraph zoom, dynamic colors, text/anchor identity and all 807
articles of the supplied DJN dictionary when its private fixture is available.
Missing or already corrupt source content is reported, never fabricated.

## Batch conversion

Bible HTML is projected once per chapter with temporary unique verse markers.
Every marker must survive parsing in order before it is removed and converted
to a checked UTF-16 anchor. Malformed batches fall back to isolated entry
projection. Plain bodies avoid unnecessary HTML parsing, while RTF uses the
native rich-text decoder. The converter reuses immutable SQLite directories
across articles rather than reconstructing the full source index on every read.

Explicit embedded bibliographic declarations are decoded with paragraph breaks,
numeric entities and the same narrow legacy-character repairs. Missing author,
publisher, edition and year fields stay pending unless the source states them;
a copyright year is not silently substituted for a publication year.
