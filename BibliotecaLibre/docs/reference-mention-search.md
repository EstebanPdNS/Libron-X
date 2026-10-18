# Reference mention search core — integration pending

Status: implementation preparation for `study-expansion-search-07`. The feature remains unchecked. The installed v0.3.0 build 34 is unchanged; these source changes do not add a native command or publish a new release.

## Extraction and query contract

`BibleReferenceMentions` recognizes the shared navigation book spellings, Arabic and spaced Roman numbered-book prefixes, ordinal marks, decomposed accents, chapter/verse punctuation, explicit chapter spans, verse ranges and comma/semicolon continuations. Serialized `bible[+edition].book.chapter.verse` addresses retain the observed original book IDs. Known single-chapter books retain chapter 1 when their citation omits it, and legacy `=r` targets use the existing strict source parser before normalization. It preserves exact reader UTF-16 spans and raw labels. Extraction never rewrites the source text.

Queries accept a known book, chapter, passage or explicit union of references. A query with an explicit edition matches only that exact normalized edition identifier. Mixed-edition continuations retain separate edition groups, while a first trailing edition qualifies its preceding unqualified list. An unqualified query accepts mentions independently of their edition; it does not assign an edition to unqualified text. This performs spelling normalization, not cross-versification conversion. Cross-book ranges currently use only the shared observed 66-book identifier domain. Additional recognized book names work individually; cross-book ordering involving other canons remains unresolved and is rejected.

Explicit typed link destinations take precedence over overlapping visible labels. Unlinked citation continuations remain searchable. A typed link crossing logical article boundaries belongs to the article containing its start; its visible selection is clipped to that article and later fragments do not duplicate it. Conflicting destinations for the same span, invalid UTF-16/grapheme boundaries and excessive input fail explicitly.

Limits: 4096 UTF-16 units per query, 16 million per article projection, 256 spans per citation and 100000 mentions/links per article. A single combined scanner avoids repeatedly scanning the remaining text for a second reference dialect. The authored 6000-citation mixed stream is a throughput observation, not a user-library benchmark.

## Search and source identity

`BibleReferenceSearchService` scans source-bound reader projections and immutable personal-document fields. It does not prune normalized reference matches using a literal word index. Results retain the source mention, a bounded snippet and either an existing reader-search destination or the personal document/entry/field identity.

Personal fields remain separate, so a title ending in a book name cannot join a body beginning with numbers. Their destination retains both a text hash and a projection hash covering the visible text and explicit link targets. Editing an invisible hyperlink destination therefore invalidates an old result even when its label is unchanged. The owning editor must supply the same projection it renders and verify these fingerprints before navigation.

Personal snapshots are examined first and report their field progress separately from book article counters. Article, result, occurrence and duration limits report partial coverage. Failed/unsupported resources, incomplete personal projections and field failures remain visible. Cancellation and source changes propagate; final progress callbacks cannot conceal a changed source. `LibrarySearchDecodedArticle.referenceLinks` is optional so existing text-only cache records remain decodable. `LibrarySearchPreparedResource.projectionVersion` binds the producer contract into the persistent index identity: an older text-only projection is invalidated even when the source files have not changed.

## Reader link projections

The portable legacy adapter and the native workspace adapter supply checked `LegacyInlineLinkTarget.bible` destinations. Conversion uses the typed destination rather than `sourceName` or display text; this preserves references stored in an extended attribute after a different first attribute. Local article links do not become Bible references based on their labels.

The HTML bridge collects raw `href` and `lbxrt:xref` attributes across the same visible DOM text nodes used for reader selection. Hidden nodes have no coordinates, labels split by inline formatting retain one span, and external URLs are rejected by reference parsing. The source attributes remain inert. Shared-page article ownership still applies. The workspace projection version is `workspace-reference-links-v2`; the portable legacy version is `core-legacy-reference-links-v1`.

## Verification and remaining work

The host regression run passes 679 tests in 112 suites. New tests cover citation spellings, ranges, editions, original wire IDs, Unicode, article boundaries, typed-label conflicts, long streams, cache compatibility, personal projection identity, error/budget behavior, cancellation and changes during final progress. Authored raw and normalized OEB cases verify DOM link ranges, hidden nodes, external URLs, exact reader selection and persistent-cache reopening. A separate cache-upgrade test changes only the producer projection version, confirms the old text-only row is replaced, and then reads the new link projection with source reads deliberately blocked.

Before accepting the complete feature:

- Extend authored reader-link evidence to the managed original corpus, including format-specific destination dialects and unresolved source-index cases.
- Project every supported personal-document field using the current editor's actual text and link semantics; retain explicit unsupported-field reporting.
- Add source-checked document/entry navigation and reader selection through the native interface, preserving existing search commands.
- Verify positive/negative, edition and source-change cases on installed native workflows and the managed resource corpus.
- Keep unsupported canon ordering and full original-engine equivalence separate from scoped recognition evidence.
