# Libron resource packages, version 1

A `.libron` document is a directory package identified by `org.libron.resource`.
The importer creates and verifies it in a hidden staging directory, then commits
it by an atomic rename within the library. It never renames a source file's
extension as a substitute for conversion.

## Structure and identity

- `manifest.json`: format identifier, schema version, stable resource identity,
  normalized bibliography, original name, source format and optional legacy ID.
- `content/<original filename>`: immutable payload, byte count and SHA-256.
- `content/<original index filename>`: optional immutable paired LIX index.

Original internal member names are retained because edition-qualified links use
those names. External package names use title, known author, language, known year
and a content digest suffix. UTF-8 names are bounded below filesystem limits.

Version 1 retains immutable source payloads as evidence and adds an independent
normalized reader representation at `normalized/reader.sqlite`. The optional
`normalizedContent` manifest member records its size and SHA-256. A resource
without this member may still use its original adapter while conversion is
pending; packaging alone does not claim native conversion.

The normalized SQLite schema has fixed, versioned tables. `values_v1` stores
bounded zlib-compressed records with uncompressed size and SHA-256. Records hold
the header, complete structured sections, deduplicated typography, or indexed
HTML members. Sections preserve supported rich text, anchors, paragraph/table
structures, graphics, inline links and interlinear definitions. `bible_v1`
indexes observed canonical book/chapter/verse positions; `words_v1` indexes
normalized dictionary headwords and aliases. No Protestant chapter count is
assumed. Legacy note IDs are excluded from chapter selectors.

The converter writes a temporary database and rereads every serialized record,
checks original hashes again, commits SQLite, checks integrity and publishes the
database. `normalized/conversion.json` records converter version, source hash,
checked section count, warnings and complete/pending status. Converter version 2
rebuilds older e-Sword projections so all newly normalized text and UTF-16 anchors
use the same chapter/entry renderer. The reader, local Find and dictionary lookup
prefer normalized content; original adapters remain conversion inputs and
fallbacks for resources without normalized content. Global legacy indexed search
retains its existing source-index scope.

A complete receipt means every supported decoded section was stored and checked.
It is not independent proof of visual or semantic equivalence for every private
format dialect, nor a decoder for opaque or protected content.

The library's `catalog.json` is an atomic, regenerable catalog. Stable IDs retain
existing workspace, hidden-resource, group and favorite references. Original
workspaces remain readable when the new optional resource fields are absent.

## Metadata and provenance

Title, subtitle, authors, contributors, resource type, category, subcategories,
tags, languages, publication year, original publication year, publisher,
collection, edition, Bible coverage and origin remain separate fields.
Bibliographic data is not interface text and is not translated. Controlled type
and category labels are localized for display. ISO language names are localized
by the system; search also recognizes Spanish, English and Portuguese names.

Field-level evidence records its value, source and status. Embedded metadata,
manual reconciliation, inspected content and external catalog evidence remain
distinguishable. Original titles/information are retained separately. A reprint's
publication date is not applied to a different installed edition. Unknown fields
remain pending. The private migration research and resource corpus are excluded
from the application distribution and repository documentation.

## Import and backup

The native warning asks whether to copy original files to `backup/<digest>/`.
Yes and No choose that extra copy; Cancel stops the operation. The suppression
checkbox persists the choice. Settings → Library can restore the question and
change the backup default. Source files at their original locations remain
untouched in both cases. Backup contents and package descendants are excluded
from resource enumeration. Exact duplicate payloads are not cataloged twice.

Checksums and sizes are checked before a new package is committed. Explicit
verification rejects same-size payload corruption. Package members cannot
escape the package through relative paths or symbolic links. Cancellation
removes the uncommitted staging package; completed packages remain recoverable.

## Supported adapters and boundaries

- `.refi`: `Reference` entries and original HTML.
- `.dcti`: `Dictionary` terms and definitions.
- `.lexi`: `Lexicon` terms and definitions.
- `.bbli`, `.bblx`: Bible book/chapter/verse rows, HTML or RTF text.
- `.devi`: dated month/day devotional entries.
- `.cmti`: book introductions, chapter introductions and verse commentaries,
  including source range labels.
- `.LSF` with optional `.LIX`, `.lbxlls`, `.lbxoeb`: existing native readers.
- `.epub`: stored/DEFLATE ZIP entries with CRC verification, OPF bibliography and
  spine order, local styles and images. ZIP64, multipart archives, encrypted
  content and configured expansion limits are rejected explicitly.
- Modern `.logos4`/`.logos5`/`.logos6`: preservation/cataloging only; no verified
  reader or unlocking capability is implied.

The expanded private corpus includes real `.bbli`, `.bblx`, `.dcti`, `.lexi`,
`.refi`, `.cmti` and `.devi` examples. Both `Details.Title/Information` and
`Details.Description/Comments` are supported. EPUB retains authored-fixture
coverage; no modern Logos decoder is claimed.
Rich e-Sword HTML/RTF preserves readable styles and Unicode. Proprietary e-Sword
cross-reference, popup-note and Strong-link dialects are retained in the payload;
complete interactive parity with e-Sword is a separate acceptance task.

## Reproducible conversion and independent audit

On macOS, run `scripts/convert-libron.sh LIBRARY [SOURCE_DIRECTORY]`. This builds
the same native converter used by the application. Omit the optional source to
resume the managed library. The executable also supports `--refresh-metadata`
for filling missing e-Sword fields from explicit embedded declarations, without
overwriting existing curated values. Detected languages have inferred provenance.

Run `scripts/audit-libron-corpus.py LIBRARY SOURCE REPORT --verify-records` for an
independent source-to-package inventory, immutable-payload hashes, native SQLite
integrity, complete section counts and decompressed-record hash verification.
This audit produces a nonzero exit status for missing imports, pending resources
or integrity failures. It does not require an original-format decoder.

## Embedded graphics and checked source recovery

Legacy CWMFRun (`0x31`) retains its original shared attributes, signed extents and
bounded metafile bytes. The wire constructor is corroborated by the immutable
run-factory/constructor receipts in the private reverse-engineering evidence.
The bitmap path follows Microsoft's [WMF DIBSTRETCHBLT specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/3306ee6b-e7c1-4bef-af95-a75a040afadc).
It creates a BMP file header around a complete SRCCOPY DIB after checking record
boundaries, dimensions, bitmap headers, palettes and pixel storage. Composited,
cropped or vector-only metafiles retain their source bytes and an explicit
rendering diagnostic; they are not flattened by guessing.

A damaged typed closing-reference marker may be retained without an invented
target only when a complete following text run is structurally valid. The
original marker bytes, flags and diagnostic remain available, and the complete
paragraph extent, run count and document byte cursor must still agree. A failed
check rejects conversion. Source section decoding is bounded to 8 MiB, while
native record decoding retains its separate 64 MiB bound.

`--organize-library` uses the same naming function as the importer, preflights
collisions, recognizes APFS Unicode-equivalent names by package identity and
rolls back a failed rename batch. Stable resource IDs and internal source member
names do not change. The catalog is regenerated after organization.
