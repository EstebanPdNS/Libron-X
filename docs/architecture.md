# Architecture

## Module boundaries

| Target | Responsibility | Dependencies |
| --- | --- | --- |
| `MacRebuild` | Current SwiftUI/AppKit study workspace | `LibronixCore` |
| `LibronixCore` | Resource formats, domain values, metadata, search and services | C compression; platform cryptography |
| `CLibronxCompression` | Buffer-bounded DCL and zlib adapters | System zlib; retained Mark Adler blast |
| `LibronixOutputMac` | Native attributed output, clipboard, PDF and printing | `LibronixCore`, Apple frameworks |
| `BibliotecaMac` | Earlier application prototype and comparison tests | Core and native output |
| `LibronixInspect` | Command-line inspection and diagnostics | Core; native output on macOS |

`LibronXRebuild` is the current app product. Target names are retained so existing imports, test coverage and tools stay compatible. Feature folders express responsibility without introducing additional modules.

## Current Mac workspace

| Folder in `Sources/MacRebuild` | Owner |
| --- | --- |
| `App` | Scenes, lifecycle, commands, language, appearance and icon preferences |
| `Workspace` | Pane arrangement, activation, shared actions, toolbars and Bible linking |
| `Features/Reader` | Reader sessions, navigation, find, links and bounded article flow |
| `Features/Reader/Rendering` | AppKit text, typography, tables, images and interlinear layout |
| `Features/Reader/OEB` | Web document rendering, find and output |
| `Features/Reader/Output` | Explicit print, clipboard and export actions |
| Other `Features` folders | Library, search, topics, documents, Bible copying and settings |
| `Persistence` | Personal snapshots, recent workspaces, resource visibility and Bible sets |
| `Shared/Controls` | Common native inputs, toolbar labels and availability fallbacks |

`StudyWorkspace` owns readers, activation and shared state on the main actor. Each `ReaderSession` owns its accepted page, source-local selection, history and pending request. Import/search/topic services perform resource work through actors; request generations prevent stale results from replacing newer state. Shared materialization is coordinated by the book service, with source-stamp checks before cache publication.

## Reading path

```text
Local resource → Core format reader → checked article/page
              → ReaderSession → AppKit text or OEB web view
              → explicitly requested clipboard / print / export
```

Stored UTF-16 ranges, source article ordinals, native indexes and Bible references are distinct coordinates. Bible navigation resolves the destination in the target edition. It must not reuse another edition's article offsets. Local links preserve the outer resource identity; unsupported or ambiguous destinations remain unresolved.

## Personal data

Original resources are read-only inputs. Owned JSON files live in `~/Library/Application Support/org.libronx.mac.rebuild/`: `personal.json`, `last-workspace.json`, `recent-workspaces.json`, `hidden-resources.json` and `parallel-bible-sets.json`. Preferences use the `org.libronx.mac.rebuild` defaults domain.

`PersonalStateFile` validates bounded reads, rejects unknown schemas, checks previously loaded bytes before saving and retains a predecessor backup. A load failure prevents silent overwrite. Workspace restoration validates all panes before replacing visible state. Normal-exit restoration does not establish crash recovery or synchronization across machines.

## Localization and appearance

`Localization/Interface.tsv` owns interface translations. Its builder produces `Sources/MacRebuild/Resources/Interface.json`; the app installs the exact SwiftPM resource bundle. `AppLanguage` and `AppPreferences` choose locale and direction independently of book language. Some legacy errors and new-document names still use Spanish.

Shared controls use native macOS APIs, SF Symbols and availability checks for newer glass presentation. Source typography remains separate from interface appearance. Reading, keyboard focus and accessibility need their own checks after a visual change.

See the [source map](source-map.md) for individual files and [compatibility](compatibility.md) for open acceptance work.


Persistent global search uses a rebuildable, source-bound local index. See [persistent search](../BibliotecaLibre/docs/persistent-library-search.md) for matching, invalidation and recovery boundaries.

Manual resource collections use separate validated, atomic app-owned state. See [the collection contract](../BibliotecaLibre/docs/manual-resource-collections.md) for identity, filtering, persistence and acceptance limits.

Resource priorities keep promoted order, enabled flags and per-datatype opening counts in independent owned state. See [key-link resolution and persistence](../BibliotecaLibre/docs/resource-priorities.md).

Reference-mention search spans reader projections and personal documents. See [the query, projection and native acceptance contract](../BibliotecaLibre/docs/reference-mention-search.md); original-engine equivalence remains a separate gate.

Bible text search supports compiled passage/book unions and immutable saved-list scopes. See [the range and verse-boundary contract](../BibliotecaLibre/docs/bible-search-ranges.md).


## Resource search scopes

`WorkspaceSearchScopeSelection` provides one source-selection contract for text, Bible and reference-mention searches: a resource, the visible library, the union of selected collections, an explicit resource subset, or all open readers (including minimized panes). Native multi-selection retains off-filter resource choices. Repeated readers and overlapping collections contribute each stable resource identity once. An empty selection fails explicitly and never widens to the library.

Each submission captures an immutable `WorkspaceSearchScopeSnapshot`. Collection membership checks ID, source format and legacy identity; titles are display metadata. Missing, hidden or replaced members remain scope issues. Available members can still be searched, but complete coverage requires both a complete source report and an issue-free scope. Collection or visibility state errors fail the affected search rather than guessing membership. Personal-document-only reference searches remain independent of library scope.

Result navigation is bound to the captured resource and source location. A still-available external source can reopen after its reader closes; a removed managed source, changed identity or hidden resource fails explicitly. The core evaluators, source coordinate contracts, index generation and Bible range semantics remain unchanged. Selection is session state; this feature does not introduce saved query documents or rule-based collections.

Installed v0.3.0 build 41 was checked in the current Spanish dark native interface: overlapping collections, explicit missing-member warnings, manual selection across filters, empty-selection errors, two open resources including a minimized reader, and reference search within collections. Two real resources produced 16 scanned articles; the literal query returned the expected 16 matches in one article and the passage query returned its expected explicit citation. The full suite passes 712 tests in 118 suites, including nine new scope workflow tests covering identity conflicts, external-reader reopening, supersession and Bible-range composition. Light/RTL and older macOS rendering were not manually inspected in this checkpoint. Original engine/RPOS and cross-versification equivalence retain separate acceptance gates.

Rule-based collections use bounded metadata conditions and calculate membership from the current catalog. See [the collection persistence and rule contract](../BibliotecaLibre/docs/manual-resource-collections.md). Running searches retain immutable evaluated source snapshots.


## Advanced positional queries

The independent product evaluator executes proximity and ordering. The recorded original compatibility parser remains a separate API; this does not claim identical original engine matching, RPOS units, ordering or advanced receiver behavior.

| Form | Product contract |
| --- | --- |
| `a NEAR b` | Either direction; maximum gap 48 original UTF-16 code units |
| `a NEAR/n b` | Either direction; at most n intervening lexical words |
| `a BEFORE b`, `a AFTER b` | Directional, without a distance cap, inside the current search unit |
| `a BEFORE/n b`, `a AFTER/n b` | Directional with at most n intervening lexical words |
| `a WITHIN n WORDS b` | Either direction; at most n intervening lexical words |
| `a WITHIN n CHARACTERS b` | Either direction; gap measured in original UTF-16 code units |
| `a WITHIN n VERSES b` | Either direction; actual source verse-number difference within the same chapter and edition |
| `a BEFORE n VERSES b`, `a AFTER n CHARACTERS b` | Directional explicit-unit variants; all three units are supported |

Distances are integers from 0 through 1000000. `WORDS` counts fully intervening lexical tokens in the reader projection, including numeric tokens; internal apostrophes join a word. Adjacent words have distance zero. `VERSES` uses the actual numbered anchors rather than counting available rows, so missing verse numbers do not shorten a distance. It requires verified intervals covering both operands. Different chapters/editions need an explicit source versification map and are reported as unsupported rather than guessed. Articles without compatible anchors produce partial coverage for verse-distance queries.

Precedence is unary NOT, proximity/order, AND, then OR; operators are uppercase and positional chains associate left to right. Proximity operands may be terms, quoted phrases, positive OR alternatives or nested proximity. Keep AND/NOT outside the positional expression, e.g. `(a BEFORE b) AND NOT c` or `NOT (a BEFORE b)`. Quote numeric literals immediately following a bare directional operator to distinguish them from explicit distances. Wildcards and other unsupported syntax remain explicit errors; field scopes are documented below.

Each pair needs distinct, nonoverlapping spans. Nested expressions carry the full extent and original positive evidence of their actual witnesses; unmatched occurrences are not highlighted. Boolean and negative-only behavior remains unchanged. Every physical article, resource or selected Bible verse retains its scope: cross-verse proximity is available in article mode; verse mode cannot join separate verses, even when its requested verse distance is greater than zero. Custom Bible ranges still restrict the evaluated verses.

Pair work, witness counts and cancellation use explicit evaluator budgets. Exhaustion throws an error and cannot return a complete truncated result. Persistent indexes only prune conservative operand candidates; proximity stays in the evaluator. Verse-distance queries inspect source intervals instead of pruning away articles that might lack compatible anchors. Source/result UTF-16 coordinates and stored cache projections remain unchanged.

Acceptance: 735 tests in 122 suites, including 15 new positional-query tests, pass in both maintained and public source trees. Native build 43 verifies word/character thresholds, reversed ordering, nesting, actual verse distances, partial-coverage diagnostics and exact source selection on real installed resources. A separate read-only SQL oracle identifies the sole expected Ge1:1/Ge1:2 pair. Final build 44 repeats positive/negative word-distance controls after deferring unused word-coordinate preparation. Ten original state files were restored byte for byte; 1099 integrity checks across 521 managed resource packages passed. Native visual evidence covers Spanish dark appearance only.


## Resource field search

The native Campo picker restricts a query to Title, Body, Footnote, Heading,
Bible text or Quotation; All text retains the existing visible-reader search.
Equivalent explicit clauses are `title:term`, `body:(a AND b)`,
`footnote:"literal phrase"`, `heading:term`, `bible:term` and `quote:term`.
Mixed clauses use All text; nested field clauses are explicit syntax errors.

| Projection | Verified field source |
| --- | --- |
| OEB/EPUB | Visible DOM: explicit EPUB title roles, HTML/ARIA headings, declared footnotes, q/blockquote quotations; body excludes separately classified title/heading/note content |
| OEB/EPUB titles outside the stream | Actual HTML document title and OEB article-directory labels; no generated EPUB filename labels |
| Legacy LSF / prepared LLS | Primary decoded reader text as body; actual AIDX title strings as external title values |
| e-Sword SQLite | Rendered main content column; actual Dictionary/Lexicon Topic or Reference Chapter column as title |
| Native dictionary | Plain stored entry body and actual headword |
| Bible text | Checked source verse intervals; e-Sword excludes its generated numeric display prefixes from body/Bible field fragments |

Primary legacy body is the complete decoded article stream. Neutral native frame
flags do not prove a separate heading, footnote or quotation role. Unavailable
roles produce named coverage diagnostics; a verified empty field is an ordinary
zero match. In particular an empty SQLite Chapter never acquires its generated
numeric navigation label as a searchable title. LLS title extraction uses the
reader's checked partial-index mode: available AIDX strings can survive unrelated
unavailable index blocks, while unreadable indexes stay unknown.

Field fragments retain original UTF-16 coordinates and must be bounded and
Unicode-safe. Shared-page article and selected-verse scopes clip/rebase fragments
before evaluation. Phrases cannot bridge disjoint fragments. Explicit producer
witness containers permit Bible/body proximity across source verses inside the
current article, without counting generated verse markers as intervening words.
They cannot join separate verse search units. Arbitrary disjoint fragments never
acquire such containers automatically.

Titles outside the visible stream retain their own value/range identity and
share evaluator budgets with visible hits. They open their bound article without
inventing a body selection. External title values cannot be positional operands;
Boolean combinations remain supported. Visible result opening verifies source
stamps and decoded-text fingerprints. WebKit applies the pending range after DOM
validation; exact node-boundary selection starts in the following text node so a
preceding block does not introduce an extra newline into a selected word.

Persistent decoded articles carry optional validated field directories. Projection
generation `workspace-search-fields-v4` invalidates older native projections;
core legacy source fields use `core-legacy-source-fields-v2`. Missing fields in
older Codable records stay unknown. Field queries bypass unsafe candidate pruning.
Original files and normalized payloads remain read-only.

This is independent product field search. Original field-index/RPOS matching,
opaque legacy footnote link semantics and cross-versification fidelity retain
separate acceptance gates. Native visual checks cover the observed Spanish dark
appearance; no claim is made for unobserved appearance/locale combinations.

Acceptance: 757 tests in 127 suites pass in maintained and public source trees,
with 22 new test definitions. The enabled read-only corpus probe samples 64
articles across LSF, LLS, SQLite and OEB, validates real source titles/body where
present, and verifies unchanged source stamps. The sampled OEB pages expose
external titles without body witnesses; authored DOM fixtures separately verify
body/note discrimination. Builds 46/47 verify native field controls, exact note
selection, external-title opening, actual LSF title/body queries, and the positive
and negative Bible verse-distance pair across all 1189 Reina-Valera 1909 articles.
Ten pre-existing state files and the library catalog/entry set were restored
exactly. All 1099 integrity checks across 521 managed packages pass.
