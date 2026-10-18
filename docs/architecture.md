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

Reference-mention extraction and search are being integrated. See [the core contract and remaining native gates](../BibliotecaLibre/docs/reference-mention-search.md); the feature is still unchecked.
