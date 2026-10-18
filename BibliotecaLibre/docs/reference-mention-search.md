# Reference mention search

Status: native product implementation for `study-expansion-search-07`, initially verified on macOS in installed v0.3.0 build 37. Subsequent Bible-range integration advances the workspace projection contract to v3, with the mention-search regression cases retained in the current suite. The search is available from **Search → Find Bible references**. It is the fifth verified feature assigned to v0.4; no new release is published until that version’s full feature gate passes.

## Extraction and query contract

`BibleReferenceMentions` recognizes the shared navigation book spellings, Arabic and spaced Roman numbered-book prefixes, ordinal marks, decomposed accents, chapter/verse punctuation, explicit chapter spans, verse ranges and comma/semicolon continuations. Serialized `bible[+edition].book.chapter.verse` addresses retain the observed original book IDs. Known single-chapter books retain chapter 1 when their citation omits it, and legacy `=r` targets use the existing strict source parser before normalization. It preserves exact reader UTF-16 spans and raw labels. Extraction never rewrites the source text.

Queries accept a known book, chapter, passage or explicit union of references. A query with an explicit edition matches only that exact normalized edition identifier. Mixed-edition continuations retain separate edition groups, while a first trailing edition qualifies its preceding unqualified list. An unqualified query accepts mentions independently of their edition; it does not assign an edition to unqualified text. This performs spelling normalization, not cross-versification conversion. Cross-book ranges currently use only the shared observed 66-book identifier domain. Additional recognized book names work individually; cross-book ordering involving other canons remains unresolved and is rejected.

Explicit typed link destinations take precedence over overlapping visible labels. Unlinked citation continuations remain searchable. A typed link crossing logical article boundaries belongs to the article containing its start; its visible selection is clipped to that article and later fragments do not duplicate it. Conflicting destinations for the same span, invalid UTF-16/grapheme boundaries and excessive input fail explicitly.

Limits: 4096 UTF-16 units per query, 16 million per article projection, 256 spans per citation and 100000 mentions/links per article. A single combined scanner avoids repeatedly scanning the remaining text for a second reference dialect. The authored 6000-citation mixed stream is a throughput observation, not a user-library benchmark.

## Search and source identity

`BibleReferenceSearchService` scans source-bound reader projections and immutable personal-document fields. It does not prune normalized reference matches using a literal word index. Results retain the source mention, a bounded snippet and either an existing reader-search destination or the personal document/entry/field identity.

Personal fields remain separate, so a title ending in a book name cannot join a body beginning with numbers. Their destination retains both a text hash and a projection hash covering the visible text and explicit link targets. Editing an invisible hyperlink destination therefore invalidates an old result even when its label is unchanged. The owning editor supplies the same projection it renders and verifies these fingerprints before navigation. Notebook titles, note titles, current plain/HTML note bodies, explicit note-anchor references and verse-list entries remain independent fields. HTML uses the editor's inert `NoteHTMLProjection`; adjacent formatting spans with the same explicit citation retain one link. Saved RTF that the current editor does not render is disclosed as incomplete coverage rather than silently indexed. That representation belongs to the separate rich-note editor work.

Personal snapshots are examined first and report their field progress separately from book article counters. Article, result, occurrence and duration limits report partial coverage. Failed/unsupported resources, incomplete personal projections and field failures remain visible. Cancellation and source changes propagate; final progress callbacks cannot conceal a changed source. `LibrarySearchDecodedArticle.referenceLinks` is optional so existing text-only cache records remain decodable. `LibrarySearchPreparedResource.projectionVersion` binds the producer contract into the persistent index identity: an older text-only projection is invalidated even when the source files have not changed.

## Reader link projections

The portable legacy adapter and the native workspace adapter supply checked `LegacyInlineLinkTarget.bible` destinations. Conversion uses the typed destination rather than `sourceName` or display text; this preserves references stored in an extended attribute after a different first attribute. Local article links do not become Bible references based on their labels.

The HTML bridge collects raw `href` and `lbxrt:xref` attributes across the same visible DOM text nodes used for reader selection. Hidden nodes have no coordinates, labels split by inline formatting retain one span, and external URLs are rejected by reference parsing. The source attributes remain inert. Shared-page article ownership still applies. The workspace projection version is `workspace-bible-intervals-v3`; the portable legacy version is `core-legacy-reference-links-v1`.

## Native interaction and verification

The dedicated search retains the existing basic, Bible-text and topic commands. Users choose one resource or the whole visible managed library and can include personal documents. Search snapshots are immutable, personal projection work runs off the main executor, progress separates articles from personal fields, and cancellation/superseding requests cannot publish stale reports. Empty resource selections are explicit errors.

Book results use the reader's source stamps, full-projection text hash and exact UTF-16 selection. Personal results verify the document/entry/field identity and both fingerprints, select the correct note or verse entry, and show the matching citation above the editor. They do not claim a programmatic selection inside the current SwiftUI text editor. Stale personal results show an error inside the search tool and can be refreshed there; they do not create an alert behind the modal sheet. Original documents, imported XML and HTML are preserved.

The regression run passes **686 tests in 114 suites**. Authored cases cover reference spelling, ranges, explicit editions, original wire IDs, Unicode, logical article boundaries, typed-label conflicts, long streams, old-cache migration, source changes, personal field isolation, invisible destination edits, cancellation and query replacement. DOM tests cover raw and normalized OEB projections, hidden text, external links, exact reader selection and cache reopening with source reads deliberately blocked. All ten interface-language catalogs contain the new controls and matching placeholders.

The private managed-corpus run checks **521 resources**, **1042 first/last article projections**, **14504 recognized mentions**, and **62 checked Bible destinations in 50 linked note articles from five original resources**. These are stated sample scopes, not an exhaustive comparison of every article with the original engine. All **1099 payload/index/normalized-content integrity checks** pass.

Installed native checks across builds 35–37 verify the menu, document-only results, explicit-edition positive/negative cases, HTML note opening, verse-entry selection, normal-restart persistence, source-change rejection and recovery. Build 36 verifies real resource matches for the observed Spanish `Efe` abbreviation; build 37 verifies the final inline stale-result error. The same source/core regression tests pass on the final build. Temporary acceptance documents were kept privately, and all ten original personal/workspace state files were restored byte for byte.

## Deliberate boundaries

This feature recognizes explicit references under the grammar above. It does not convert versification between editions or close the separate original action-registry/search-engine parity gates. Unsupported cross-canon ordering remains rejected. The native walkthrough observed the current dark Spanish interface; light/RTL/older-macOS rendering was not manually observed in this acceptance run.
