# Notebook and sermon reports

Reports use a study-document snapshot and the catalog snapshot captured when the
report opens. A later catalog update cannot change a reviewed report when an
inclusion option changes. Selecting notes preserves their outline order; the
report does not mutate notes, anchors, provenance or source files.

## Independent inclusion options

- Note content uses the current rich edit when present, otherwise the preserved
  supported source representation. Unsupported original HTML objects or corrupt
  rich text cause an explicit error instead of silently exporting stale text.
- References include the stored note anchor and, for sermons, metadata passages.
  References already written into a note's body remain part of that body.
- Bibliographic citations use the linked resource's catalog metadata in Catalog,
  Chicago author–date or MLA style. Resource ID, physical format and original
  identifier must all match. Missing resources and unidentified legacy sources
  are stated explicitly; another edition is never substituted. General notes
  with no source do not acquire an invented citation. No page numbers, authors,
  publication dates or text quotations are inferred or retrieved.

The report shows sermon metadata as well as selected notes. Disabling reference
inclusion hides sermon passage metadata without hiding the remaining metadata.
An empty selection disables output and shows a selection instruction.

## Preview and output

The native report window keeps inclusion options and the selectable note list in
one column, and an attributed, selectable preview in the other. Each option
change prepares the preview once. Export and print capture that same attributed
result, including when a system save panel remains open.

TXT exports UTF-8 text; RTFD exports a native attributed document package; PDF
uses the shared paginated print view with a private copy of print settings and
top alignment, including for short reports. Shared centering preferences remain
unchanged. Printing presents the system print panel
using that same view. Output actions are disabled for an invalid report. The
report's 16-million-UTF-16-unit bound applies before output.

The window uses the common macOS Glass controls, native checkboxes and the
shared selection menu. Interface direction and translated labels are inherited
at the report's sheet boundary; source note text remains user-authored content.
