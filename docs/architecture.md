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

## Approximate phrase search

The native Match picker offers Exact and Approximate phrase. Exact preserves the
existing grammar and matching behavior. Approximate phrase treats the complete
entry literally, including AND, colons, quotes and backslashes; choose the source
field separately. Select one, two or three character edits. Insertions, deletions
and substitutions each cost one; a neighboring transposition costs two. This is
textual edit distance, not semantic similarity, stemming or word reordering.

The independent matcher uses banded Levenshtein over original extended grapheme
clusters. Comparison tokens use canonical normalization and the selected case /
diacritic folding with a fixed POSIX locale. A folding expansion stays one token
for its original grapheme; it does not introduce synthetic reader characters.
Spaces and punctuation participate in the distance. Native whole-word settings
retain explicit lexical boundaries, including internal apostrophes; they do not
claim language-specific tokenization. Disabling whole words allows every original
grapheme boundary as a candidate start.

For each eligible start, return the candidate with the lowest edit distance,
then the length closest to the query, then the shorter span. An exact candidate
wins at the same start. Overlapping starts may produce separate hits; this does
not rank articles by relevance. Original UTF-16 offsets, source hashes and opening
validation remain unchanged, including for combining marks and emoji sequences.

The phrase must contain more graphemes than the selected edit limit and at most
256 graphemes. Bounded query-parser source limits still apply. Each evaluated
article/verse or external field value is limited to 1048576 UTF-16 units. The
native controller allows 5000000 match-work units per article; candidate starts
and dynamic-programming cells consume the shared work budget. Preprocessing,
candidate scanning and matrix work observe cancellation. Budget exhaustion throws
an explicit error; the library reports partial coverage instead of complete
absence. General duration/result/occurrence budgets remain in force.

Approximation applies to operands in the Core AST, preserving Boolean/positional
witnesses there. The native phrase mode deliberately supplies one escaped literal
operand, optionally wrapped by the field picker. Field fragments and separate
article/verse units remain closed scopes; fuzzy matching cannot concatenate them.
External title values share work/hit budgets and keep their own coordinates.
Literal index pruning is disabled for approximate requests, including warm-cache
requests, so spelling variants cannot disappear behind exact candidate filters.
The decoded text cache keeps its schema; HTML word-boundary metadata uses the projection generation below.

The product matcher is independent of the original Libronix fuzzy implementation;
original algorithm/ranking equivalence remains a separate evidence requirement.

Rendered HTML supplies validated zero-width lexical breaks at block transitions
and visible BR elements. Inline markup keeps a continuous word. These breaks
split only words that the unchanged text-node stream would otherwise join; they
never add whitespace, shift offsets or count phantom words around existing
spaces. The reader's text fingerprint stays unchanged. Search transport/cache
records carry optional sorted, bounded, grapheme-safe offsets, clipped/rebased
with article/verse scopes. Native projection generation
`workspace-search-block-boundaries-v5` invalidates older missing-boundary caches;
old Codable records remain readable with unknown/nil boundary metadata.


XHTML and HTML reader responses declare UTF-8 consistently with the checked
UTF-8 source projection, including documents without a charset declaration.
This keeps emoji/combining characters and result fingerprints identical in
search and the actual reader; an encoding mismatch must never apply an offset
to different displayed text. A real WebKit regression opens the owned XHTML
fixture and verifies the selected DOM text without a test-side selection call.

Acceptance: 773 tests in 129 suites pass in maintained and public source trees,
including 16 new test definitions and 256 independent full-matrix oracle cases.
A separate enabled 64-article LSF/LLS/SQLite/OEB source-field regression passes.
Installed build 51 verifies exact, near and unrelated phrases, thresholds one
through three, literal operator text, field notes/titles and exact visible
selection of the original phrase beside an intact emoji. On real Reina-Valera
1909, Ge1:1 Body search for `En el principo` returns one hit with one allowed edit
and zero in Exact mode; all 1189 articles are inspected and 31102 out-of-range
verses excluded. A read-only SQL/full-matrix oracle independently confirms the
source phrase and edit distance. Ten original user-state files and the library
catalog/entries are restored exactly; all 1099 integrity checks across 521
managed packages pass. Evidence covers the observed Spanish dark native UI.

## Search result views and occurrence navigation

Global search retains a bounded context for each returned reader hit, instead
of showing only the first match in an article. Each context carries its exact
original hit range and a grapheme-safe snippet range in the complete decoded
page. Article/verse boundaries clip context, and shared-page offsets are rebased
back to original reader coordinates. Context generation never changes the
source text, the report's hits, its fingerprints or its source stamps.

`LibrarySearchBudget.maximumContextUTF16` defaults to 8 Mi UTF-16 units and has a
0–64 Mi bound shared across the report. Each context also respects snippetUTF16.
The native occurrence budget is 20000 with 240-unit snippets, so the default
presentation budget accommodates ordinary retained hits. A smaller/custom budget
may omit contexts, with explicit context coverage separate from actual search
coverage. Hits and opening evidence stay available. Long matches may be shown
partially with ellipses; an oversized grapheme is omitted rather than split.
The existing article snippet remains the summary/backward-compatible fallback.

Native Context and Aligned context layouts share the same occurrence identities.
Aligned context uses three columns: preceding text, matched text, following text.
Visible text is verbatim source content; UI labels alone enter localization.
External title matches use their actual metadata value and its independent
field/value/range identity, never fabricated body positions. Negative-only
matches retain summary rows; positive evidence omitted by a search limit is
identified separately. A missing context is explicit and does not block opening.

Grouping is None or Resource, keyed by resource ID so identical titles stay
separate. Ordering is Search order, Title A–Z, Title Z–A or Most matches per
article. Title comparison uses fixed case/diacritic-insensitive numeric ordering
with deterministic identity/source tie breaks. With resource grouping, groups
follow their first result in the selected order; most-matches ordering ranks
articles, not an inferred aggregate resource relevance score. Reordering never
mutates the report or drops/reassigns occurrence IDs. Layout, grouping and order
are session preferences, retained when a query clears or is replaced.

Previous/Next selection stops at both ends. The list scrolls to the selected
occurrence and keeps it through presentation changes. Native list selection,
Enter/double-click, per-row Open and Open selection use the same focus. Option-
Command-Up/Down navigate the list without replacing existing Find shortcuts.
The navigation counter counts retained occurrence/summary rows; the original
footer counts matching article/verse result units and examined source articles.

Opening a reader occurrence validates that its exact range belongs to the report
before loading it, then uses the established source-stamp/fingerprint validation.
Opening metadata deliberately has no reader highlight, even when the same result
also contains body matches. Negative summaries preserve their legitimate verse
scope; omitted positive hits do not invent a selection. Invalid focus and changed
sources remain explicit failures. This presentation does not claim the original
Libronix relevance ranking or unrestricted original result-view equivalence.

Acceptance: 784 tests in 131 suites pass in maintained and public source trees,
with 11 new test definitions. Installed build 52 verifies six occurrence rows
across two owned EPUBs, both context layouts, grouping/order changes that retain
the selected occurrence, navigation boundaries/shortcuts and Enter opening of
the third far match. Independent authored HTMLParser/native archive selections
agree at [1015,15]; metadata opening from a mixed body/title result stays [0,0].
Real Reina-Valera 1909 Ge1:1 yields two rows for `Dios OR cielos`; selecting the
second opens `cielos` at [32,6], independently checked against read-only original
SQLite and the reader display-prefix contract. Negative-only and empty result
states pass native checks. Ten original state files and catalog/entry set are
restored exactly; all 1099 integrity checks across 521 managed packages pass.
Native visual evidence covers observed Spanish dark appearance only.

## Long-running managed search (bounded acceptance)

Each execution owns an isolated actor accumulator and a cooperative control gate.
Running snapshots publish retained results at bounded batches; only a finished,
source-verified report can claim complete coverage. Paused, cancelled and failed
snapshots remain partial. The original single-progress-callback API remains
compatible, including trailing closures.

Pause waits for the current article or verse boundary and suspends the same scan
stack. Acknowledged pause time is excluded from the elapsed-time budget; active
time includes source I/O and callbacks. Resume verifies every prepared source
before continuing. A changed or unverifiable source fails explicitly and blocks
opening results. Cancellation wakes a suspended gate and preserves committed
results. This is session-only continuation: no restart cursor is persisted.

The native controller freezes submitted query/options and limits while active.
Generation tokens reject callbacks from superseded runs. Incremental result
presentation retains the selected occurrence. Closing the search tool requests
pause. Editing the query or limits after termination marks retained results stale
and blocks opening until a fresh run. Existing source fingerprint and occurrence
validation still apply when opening valid results.

Duration, article, result-unit and occurrence limits are adjustable before each
run and validated before source preparation. Reaching a limit finishes a partial
report with its explicit reason. Increasing the limit requires a new search;
finished limited scans cannot resume. Resource/source coverage and context
omissions remain independently visible.

Acceptance: 795 tests in 133 suites pass, including 11 new definitions covering
pause/resume without duplicate reads, excluded pause time, both cancellation
paths, source mutation during pause, limits, stale generations and selection.
Installed build 53 verifies progressive search across 533 resources, stable
acknowledged pause at 816 articles / 5.9 active seconds, continuation to 1389 /
11.6 seconds, cancellation with retained results, two- and five-result limits,
invalid-zero rejection, and stale-query opening guards. A finished Reina-Valera
1909 body search for whole-word `Dios` scans 1189 chapters, returns 879 matching
chapters and 4122 occurrences: an independent read-only SQLite/HTMLParser/Unicode
regex oracle agrees exactly. Native visual evidence covers observed Spanish dark
appearance. Full original Libronix search equivalence remains unproven.

## Resource association manager
The Tools menu opens a native association editor for ordered alternative or
companion resource groups. Owned definitions live in resource-associations.json,
separate from original .lbxras files, Bible groups, collections and priorities.
Groups have stable UUIDs, an explicit relation and a compatibility scope: Bible,
commentary, dictionary, lexicon or a named series, optionally constrained by a
canonical language code. Series match the declared collection with fixed case-
and diacritic-insensitive comparison; blank or unknown series never match all
resources. Dictionary/lexicon language eligibility uses the existing KeyLink
datatype declarations when available. These are declared compatibility criteria,
not proof that every source implements every navigation coordinate.

The editor creates, names, configures and deletes groups, filters/adds eligible
resources, removes members and changes their order. Draft profile changes must
be saved before adding resources. A compatibility change is transactional and
requires all retained members to resolve and satisfy the new scope. Renaming or
changing relation preserves unresolved members. Hidden, absent, replaced or
newly incompatible resources remain visible with their saved identity and order;
resolution checks exact path, format, legacy identifier and current scope.
Restoring the same eligible identity resolves it again without changing the
saved definition.

Persistence validates version, group/member bounds, unique IDs, names, paths,
language and series before saving. There are at most 128 groups and 256 members
per group. Writes use the established atomic previous-file/concurrent-writer
checks. Invalid or future state remains untouched and blocks writes until a
valid reload; failed reloads retain the last valid in-memory groups.

Static examination of the 53 supplied original association files finds 49 groups
and 1116 ordered member references, mostly without an explicit relation type.
That establishes ordered membership and priority declarations, including absent
resources, but does not establish a runtime alternative/companion contract.
This editor records the user's chosen relation explicitly. Import of original
association definitions and resource navigation are separate integration work;
this manager alone does not close the original Parallel Resources workflow.

Acceptance: 803 tests in 134 suites pass, including eight new test definitions.
Installed build 54 verifies creation, Unicode naming, language filtering, adding
real Reina-Valera 1909/Biblia al Día members, ordered movement and companion
relation persistence. An incompatible profile change is rejected without loss.
Restart retains name/relation/scope/order and an unavailable identity; restoring
the exact owned test definition resolves it again. Member removal, group removal
and empty states pass native checks. Ten original user-state files restore
exactly; the new test-only state is archived. Catalog/entry set and all 53 original
association definitions remain unchanged; 1099 package integrity checks pass.
Native visual evidence covers observed Spanish dark appearance only.
