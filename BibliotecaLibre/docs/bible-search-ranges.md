# Configurable Bible search ranges

`study-expansion-search-03` extends the existing **Search → Bible search** tool. The ordinary article search and explicit-reference mention search retain their own commands and semantics.

## Scope contract

The Bible-search range picker offers all observed verses, custom passages/books, or an existing verse-list document. A custom range is a union: `Genesis 1–3; John 3:16,18; Romans`, `Genesis, John`, and mixed whole books/passages are supported. Numeric chapter/verse continuations keep their preceding reference context. Unsupported names, reversed ranges, dangling separators and malformed entries fail explicitly. Separate saved-list entries never borrow reference context from one another.

A range compiles to sorted, merged address intervals grouped by explicit edition. Membership uses binary lookup; overlaps and duplicates do not duplicate results. Raw serialized Bible references keep the observed original book identifiers, not Protestant ordinal guesses. An explicit edition in a source anchor takes precedence over resource identity; otherwise an exact payload basename or bibliographic abbreviation can satisfy a requested edition. Titles and interface language never supply an inferred edition. Unqualified ranges are edition independent. This does not convert versification between editions, and cross-book ranges outside the shared observed 66-book ordering remain rejected.

Saved lists produce immutable snapshots containing the document ID, title, references and a fingerprint. Changing a list after starting a search does not alter that search's scope. A missing/empty list or one incompatible entry is an error, not a silently reduced list. Manual/list input is bounded to 100000 compiled intervals and 16 million UTF-16 units; each citation group retains the reference-query grammar's bounds. Scope preparation runs off the main executor and cooperates with cancellation.

## Evaluation and navigation

`LibrarySearchService` validates each reader projection and its verse directory before applying the range. It evaluates the text query separately inside each selected verse. `AND` terms never join different verses, passages or articles. A logical HTML article cannot borrow a neighboring article's verse, and a partially cut verse fails as an ambiguous directory. Full-reader UTF-16 coordinates, source stamps and text fingerprints remain attached to every result.

A Bible with valid intervals outside the requested range reports complete zero results; a source with no compatible intervals reports incompatibility. Counters distinguish examined verses from those excluded by the range. A partial scan, corrupt interval or exhausted budget remains partial coverage. The native limits remain 120 seconds, 250000 articles and 500 results. The implementation still reads and validates the resource's articles; this is not a claim of original index/RPOS acceleration.

A positive result selects its first text hit. A pure-negative result has no positive hit, so opening it now selects the result's verified whole-verse interval instead of landing at the article start. Selection still requires the original source stamps and full-projection fingerprint.

## Original format compatibility

Observed LSF Bible anchors use datatype 2. LLS 0x52 references use datatype 16 with an explicit `bible[+edition].book.chapter.verse` scheme. The verse adapter recognizes that strict scheme while preserving the original datatype and ignoring unrelated type-16 labels. Repeated markers with incompatible edition identities fail as an ambiguous directory rather than merging text under the first marker’s edition. e-Sword retains its existing explicitly projected datatype-0 verse intervals.

The actual e-Sword source spellings `2Jo` and `3Jo` normalize to the existing `2jn` and `3jn` keys. Read-only native lookup accepts both canonical keys and the earlier stored `2jo`/`3jo` keys, so existing databases require no rewrite. The workspace search projection version is `workspace-bible-intervals-v3`, invalidating generated text caches that contain earlier e-Sword normalized verse keys. Original resource bytes, normalized databases, user documents and imported XML remain unchanged.

## Verification

The regression run passes **703 tests in 117 suites**. Authored cases cover mixed whole books/passages, inherited continuations, disjoint and overlapping ranges, edition precedence, saved-list snapshots, invalid and oversized input, cancellation, source changes, logical article boundaries, immutable old native indexes, raw/normalized readers, cache reopening, and exact negative-result navigation. All ten interface languages include the new range controls.

The private real-corpus test scans all **105259 articles in six Bible resources across three original formats**. Manual and saved-list ranges each select exactly Genesis 1:1 and 1:3: **12 selected verses**, with **186348 other observed verses excluded**. Debug runs take approximately 7–108 seconds per resource under the 120-second limit. These measurements describe this corpus/run, not universal performance or original-engine equivalence.

Native checks across builds 39–40 verify custom and saved ranges yielding the same two results, a two-book union evaluating 28 verses, pure-negative one-verse selection, navigation through an older stored `3jo` key, and a recognized book absent from the selected edition yielding complete zero coverage. The current dark Spanish native interface was inspected; light/RTL/older-macOS rendering was not manually observed in this acceptance run. Original search/action-registry and general RPOS parity gates remain separate.
