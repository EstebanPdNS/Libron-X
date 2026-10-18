# Bibliographies, citations and editions

Open **Tools → Bibliography** to generate a report for the complete catalog,
selected collections or an explicit resource selection. The complete catalog
includes hidden resources. Reports retain edition metadata, field provenance,
unknown values and unavailable collection members. Changing the catalog or scope
disables stale copying/export until the report is regenerated.

Reports export as text, HTML or JSON. JSON retains the complete metadata snapshot
and provenance. Text and HTML use the selected citation style; the Catalog style
includes the detailed field report. Export cannot replace a book, package or
library catalog.

## Citation styles

Choose Catalog, Chicago author–date or MLA in the bibliography or a reader's
actions menu. The preference is shared with **Copy resource citation** in the
library, reader actions and native text/HTML context menus. Copying provides
plain text and HTML with title emphasis. Ordinary selection/article copying
retains its existing behavior.

Chicago and MLA implement basic book references from the available author,
title, subtitle, edition, publisher and date fields. They preserve the catalog's
names and titles instead of guessing missing bibliographic data. Chicago uses
`n.d.` for a missing date; MLA omits unavailable elements. Contributor roles,
publication places, chapter authors, URLs and page ranges are not invented.
These are book-reference templates, not a complete citation processor for every
publication type. Consult the [Chicago author–date guide](https://www.chicagomanualofstyle.org/tools_citationguide/citation-guide-2.html)
or the [MLA book-reference guide](https://style.mla.org/works-cited/citations-by-format/books/)
when preparing a formal bibliography.

## Duplicates and editions

Open **Tools → Duplicates and editions**, then analyze the library. The scan
verifies package members against their manifest hashes and hashes standalone
sources and companion indexes. It distinguishes:

- Exact copies with identical original, index and native reader bytes.
- An identical original with different native reader representations.
- Possible editions sharing normalized title, author and language metadata.

Metadata similarity is a review suggestion. It never proves duplicate content.
The inspector shows the actual edition, date, publisher and physical file for
each member. Missing, changed or unreadable resources remain explicit issues.
Cancel stops an audit without replacing its previous report.

Hide and Show again change the existing identity-bound visibility list. They
preserve packages, originals, annotations and saved locations. There is no
automatic deletion, edition merge or automatic choice of a preferred copy.
Actions reject a report whose catalog snapshot has changed.
