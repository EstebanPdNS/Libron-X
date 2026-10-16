# v0.1 verification

Checked on October 16, 2026, on Apple Silicon with macOS 27.2 (26B5086k), Apple Swift 6.4 and Command Line Tools. These are development-machine results, not certification of every supported macOS version.

| Check | Result |
| --- | --- |
| Complete Swift Testing invocation | 509 passed, 28 skipped, 0 failed; 537 declared tests in 84 suites |
| Independent synthetic query reference | 124/124 acceptance outcomes, 86/86 accepted trees, 47/47 translation outcomes |
| Release build of `LibronXRebuild` | Passed; arm64 executable; app version 0.1, build 1 |
| Bundle | Translation resource bundle, two approved icons and retained legal notices installed |
| Signature | `codesign --verify --deep --strict` passed; ad-hoc signature, no notarization |
| Native smoke check | Exact packaged app launched, restored two reading panes and opened Settings |
| English presentation | Language switched in place; Home and General settings captured from the packaged app |
| Preservation | Source and test bytes match the frozen development snapshot; personal language and visible readings restored after checking |
| Repository documentation | Relative file links checked within the public tree |

The 28 skipped tests require optional original corpora or explicit performance inputs. No private corpus was enabled for this run. A skipped test is not a successful original-resource comparison. The native restoration smoke check used locally owned resources; none is distributed.

The publication review inventoried all 151 files under `Sources`, checked target dependencies, entry points, resource installation, request ownership and personal-data boundaries, and documented the active workspace separately from the earlier prototype. This is a packaging and architecture review, not an exhaustive proof of every algorithm or complete original workflow parity.

The compiler reported an existing ambiguous trailing-closure warning in `WorkspaceBibleVersions` and a SwiftPM deprecation warning for the explicit native build-system flag. Neither prevented testing or release compilation. Full VoiceOver, translation review, older macOS execution, Intel distribution, extended stability, signing/notarization and complete Libronix compatibility remain open.

The [source map](source-map.md) and [compatibility guide](compatibility.md) belong to this release. Raw build logs and private research inputs are excluded. GitHub Actions runs the documented test/build gates independently; its result is visible in the repository Actions tab and is not implied by these local results.
