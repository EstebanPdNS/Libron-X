# Verification: v0.5.1

Checked on 2026-10-21 with Swift 6.4, an arm64 Mac and macOS 27.
The installed bundle reports version 0.5.1, build 99 and the Beta channel.

- The general suite passed: 909 tests in 159 suites. Private-corpus checks require
  their explicit inputs; this run is not exhaustive acceptance of original books.
- Nine focused localization/release-note checks passed after catalog regeneration.
- The Icedrive transport downloaded a public encrypted object without cookies or
  credentials and matched an independently recorded SHA-256.
- All 19 final collection codes and the one-resource probe downloaded exactly the
  uploaded encrypted catalog, decrypted successfully, passed the native schema
  checks and contained valid permanent file-ID addresses.
- The native installer downloaded a one-resource collection, verified it, read its
  text and skipped its objects when the code was repeated.
- The installed app's Downloads window reported one new resource and zero failures.
  Repeating the code reported one already installed resource and zero failures.
  The resource opened from the Library in the native reader; typography and links
  were visually inspected.
- Authored regressions cover code authentication, malformed provider responses,
  file identity/size checks, safe paths, compression, repeated installation and
  repair from the verified cache.
- The release build and strict bundle signature verification passed. The embedded
  distribution key matched the existing encrypted catalogs without adding the key
  or any private library files to the public repository.

These checks do not claim that every resource or historical Libronix feature is
implemented. Private receipts and book contents remain outside Git.
