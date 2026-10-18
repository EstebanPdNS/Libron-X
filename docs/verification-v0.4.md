# v0.4 verification

The 19 features assigned to v0.4 in the [release plan](release-plan.md) are
implemented within their documented supported-resource scope. This does not
establish complete functional parity with the original Libronix application.

- The maintained source passed 856 tests in 144 suites, serially on macOS.
- The tested and public trees matched across 381 source, test and localization files.
- Swift 6.2 compatibility fixes split metadata concatenation and snapshot reference-search progress before awaiting callbacks. CI restores checksum-verified, attributed dictionary packages and runs tests serially.
- The release app was built from the public tree as v0.4.0 build 70 for arm64,
  installed at `/Applications/Libron-X.app` and verified with strict code signing.
- Native bibliography checks generated a 535-resource catalog report, a
  two-resource collection report, a partial collection with one missing member,
  and a selection containing two distinct editions. Native JSON export retained
  both editions and their actual dates.
- Native citation checks exercised the Catalog, MLA and Chicago author–date
  picker and live preview, and confirmed the reader's context action. Isolated
  pasteboard tests checked consistent plain text/HTML output and safe empty copying.
- The native edition audit examined 535 resources without integrity issues,
  presented six possible-edition groups and exposed restoration for an already
  hidden resource. Synthetic tests distinguish exact copies from different
  native readers and legitimate editions; visibility round trips preserve files
  and reject stale catalog actions.
- Live catalog and hidden-resource files remained byte-identical. No original
  book, imported study resource or user library is included in the release.
- The distributable passed ZIP CRC, fresh extraction, strict signature checking
  and byte comparison of all 89 installed bundle files. Uploaded asset digests
  and a fresh download are checked before delivery is reported complete.

Corpus tests that require additional private inputs skip by default. Their
absence is not counted as original-program acceptance. Citation styles implement
the basic book templates described in [library reports](library-reports.md).
Protected modern Logos resources and broader original-engine compatibility
remain incomplete.
