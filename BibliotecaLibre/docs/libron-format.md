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

Version 1 deliberately preserves native payloads. The existing LSF, embedded
Libronix LLS and OEB readers retain typography, links and original coordinates.
SQLite e-Sword resources use a new read-only schema adapter. EPUB uses a bounded
ZIP reader and the existing isolated local HTML/CSS/image renderer. This does
not claim that an opaque or protected native payload has become readable.

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
- `.cmti`: book introductions, chapter introductions and verse commentaries,
  including source range labels.
- `.LSF` with optional `.LIX`, `.lbxlls`, `.lbxoeb`: existing native readers.
- `.epub`: stored/DEFLATE ZIP entries with CRC verification, OPF bibliography and
  spine order, local styles and images. ZIP64, multipart archives, encrypted
  content and configured expansion limits are rejected explicitly.
- Modern `.logos4`/`.logos5`/`.logos6`: preservation/cataloging only; no verified
  reader or unlocking capability is implied.

The supplied private corpus has no `.bblx`, EPUB or modern Logos example. The
`.bblx` and EPUB pathways therefore require authored-fixture evidence alongside
real `.bbli` tests, rather than a claim of real-corpus coverage for absent formats.
Rich e-Sword HTML/RTF preserves readable styles and Unicode. Proprietary e-Sword
cross-reference, popup-note and Strong-link dialects are retained in the payload;
complete interactive parity with e-Sword is a separate acceptance task.
