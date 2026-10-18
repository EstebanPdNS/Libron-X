# Development

## Setup and build

Use Xcode 26 or later, or equivalent Command Line Tools with Swift 6.2+ and a macOS 26+ SDK. New glass APIs require this SDK even when deploying to older macOS versions. Check `swift --version` and `xcode-select -p`. `Package.swift` specifies Swift 6 language mode and macOS 14. `Package.resolved` pins dependencies, including Swift Crypto 4.3.1. macOS uses CryptoKit and system zlib; SwiftPM still resolves package dependencies on the first build.

From the repository root:

```sh
cd BibliotecaLibre
scripts/test.sh
scripts/build-rebuild-app.sh
open /Applications/Libron-X.app
```

The test wrapper supplies Swift Testing macro paths for Command Line Tools installations. It disables XCTest because the suites use Swift Testing. Corpus checks skip unless their explicitly named `LIBRONX_*` environment variables point to owner-supplied local inputs. Do not treat skipped checks as corpus acceptance.

The app builder compiles `LibronXRebuild` in release mode, installs translations,
approved icons and offline dictionaries, writes v0.4 metadata and ad-hoc signs the
bundle. Close Libron-X before building. It preserves source snapshots and replaces
`/Applications/Libron-X.app`, moving the previous bundle to Trash.

The large dictionary packages are distributed in the release ZIP, rather than Git.
Before a source build, extract the current release app and copy its attributed packages into
the checkout:

```sh
cp -R /Applications/Libron-X.app/Contents/Resources/BundledDictionaries/ Resources/BundledDictionaries/
```

Alternatively, use the same directory from an extracted release app in another path.
Each package includes exact source data, notices and conversion code. The catalog
records dataset and payload hashes. `scripts/vendor-dictionaries.py` rebuilds the
packages when its exact source inputs and notices have been restored under
`Resources/BundledDictionaries/sources/`; it never downloads data implicitly.

`swift build --product LibronX` and `scripts/build-app.sh` belong to the earlier prototype; its builder writes to `dist/prototype/Libron-X.app`. Use `LibronXRebuild` for the current workspace.

## Checks

```sh
scripts/test.sh --filter MacRebuildTests
swift run libronix-inspect
```

The independent synthetic query reference runs with `python3 Tools/QueryReference/query_reference.py verify`. The standalone C harness requires an explicit zlib checkout via `--zlib-source`; Swift suites also exercise the C adapter.

The last command prints CLI usage when called without arguments. Read its command help before using original inputs. Automated suites cover pure contracts and selected native adapters; manual focus, accessibility, pane, print and restoration checks remain necessary.

## Change interface text

Edit `Localization/Interface.tsv`, then run `python3 scripts/build-interface-catalog.py`. Commit both the TSV and generated JSON. Language selection must not translate resource text or change source coordinates.

## Source and distribution

The [source map](source-map.md) lists all source files. Keep Core portable, UI state on its owning actor and persistence separate from original resources. Preserve public target names and the earlier prototype's comparison coverage when reorganizing files.

For a release: freeze a revision, run tests and a release build, inspect bundle version/architecture/resources/signature, exercise the app, package the app with LICENSE and third-party notices, and verify a fresh extraction. Publish the exact tested revision as a prerelease until compatibility gates are met. Download uploaded assets and compare their checksums. Do not replace historical release bytes.

The [v0.1 verification record](verification-v0.1.md) states the checks actually performed. Build output and raw private corpus reports stay outside Git. Code Atlas D01–D18 guides these documentation and publication boundaries.
