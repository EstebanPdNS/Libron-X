# Sermon documents

A sermon is a `StudyDocument` with `kind: "sermon"` and document schema 3.
It uses the existing note hierarchy and rich-text editor. Notebooks and verse
lists keep their existing schemas and representations. Older applications reject
the new kind instead of rewriting it as a different document type.

## Metadata

The `sermon` object contains an optional `preachedOn` civil Gregorian date
(`year`, `month`, `day`), plus `speaker`, `series`, `venue`, `passages` and `tags`.
Dates use the existing `ReadingDay` contract, including real calendar validation
and years 1900–9999. An absent date remains unknown; it is not replaced with the
creation date. Passage strings retain their entered spelling and edition
qualifiers and must parse as supported Bible references.

At the document persistence boundary, metadata is limited to 4096 UTF-8 bytes
per speaker/series/venue field, 128 passages of at most 4096 bytes each, and 64
unique nonempty tags of at most 256 bytes each. A sermon cannot contain verse-list
entries. Metadata on a different document kind is rejected.

## Editing and browsing

Sermon Archive is available from Tools and the command palette. Sermons can also
be created from New Document and the study-document window. The archive searches
titles, dates, speakers, series, places, passages, tags, note titles, anchors and
visible note content. It uses ordinary case/diacritic-insensitive text matching,
not query-operator or lemma semantics. Queries are limited to 512 UTF-16 units.
Rich edits are projected once; a corrupt rich representation falls back to the
preserved source and makes coverage explicitly partial. Unsupported HTML objects
are retained in the document and do not become invented searchable text.

Search work runs separately from the interface and is cancelled when its inputs
change or the archive closes. Ordering supports newest/oldest sermon date, title
and speaker; undated documents follow dated documents in either date order.

Metadata editing uses a draft. Local cancellation prompts before discarding edits,
and application termination consults the active draft guard. Saving details checks
the original title and metadata, retains newer note content, and uses the normal
transactional personal-data writer. Sermon passages also participate in reference
search and extraction, with a distinct document-level field and source fingerprint.

## Reports, history and recovery

Notebook-style reports include sermon metadata and the selected note content.
Native JSON opening/export uses the normal study-document contract. This does
not claim support for undocumented historical sermon-file formats.

Editing and deleting sermons retain the prior personal snapshot in the existing
content-addressed history. Recovery creates a separate document and note IDs,
preserves note hierarchy, metadata and provenance, and verifies the selected
snapshot before writing. The current document is never replaced by recovery.
Note movement, duplication, rich editing and deletion must preserve schema 3;
they must not downgrade a sermon to a notebook schema.
