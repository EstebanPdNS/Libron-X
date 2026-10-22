# Resource download codes

The Downloads window accepts an `LX2.` code, fetches its encrypted collection,
and installs native `.libron` resources. Repeating a code verifies existing
packages and skips their downloads. Verified cached objects can repair changed
packages. A replacement keeps the previous package in `backup/downloads`.

## Files and responsibilities

- `ResourceDownloadCode`: bounded code parsing and authenticated AES-GCM decoding.
- `ResourceDownloadKey`: obtains the distribution key embedded by the build script.
- `ResourceCollectionManifest`: validates identities, sizes, hashes and safe paths.
- `AnonymousResourceTransport`: isolated HTTPS sessions without account credentials,
  cookies or URL caches; bounded transfers, cancellation and HTML rejection.
- `IcedrivePublicDownload`: resolves a public file ID to a fresh CDN address on
  every transfer. Codes and collection members store the public metadata endpoint,
  never its expiring CDN response.
- `ResourcePackageInstaller`: checks encrypted and plaintext hashes, decompresses
  bounded zlib streams, verifies the native package, and commits its catalog entry.
- `ResourceDownloadController`: cancellation, progress and installation outcomes.

Icedrive's observed public web protocol uses
`https://apis.icedrive.net/v3/webapp/download-multi&items=file-ID&public=1`.
The resolver accepts one positive file ID and one matching response, checks its
size, and accepts only HTTPS `/download` addresses on Icedrive's CDN domain.
The protocol was verified against the public web application on 2026-10-21.
Revoked sharing, transfer limits and invalid responses fail explicitly.

## Preparing a distribution

`build-optimized-distribution.py` produces deduplicated, encrypted file objects and
private collection metadata. `prepare-icedrive-catalogs.py` binds those objects to
an independently captured public Icedrive file inventory. It checks unique file
IDs, names and sizes, then encrypts and reopens every catalog before writing its
receipt. Its `upload/` folder contains only encrypted catalogs.

The publisher uploads those catalogs, records their current public file IDs,
generates codes with `download-package-crypto.swift`, and verifies the uploaded
ciphertext against the local receipts. Keep all keys, private manifests, resource
inventories, books and release evidence outside Git. Build with
`LIBRONX_RESOURCE_KEY_FILE` pointing at the existing distribution key; changing
the key makes existing encrypted codes and objects unreadable.

## Verification

Authored tests cover code authentication, malformed requests, file identity,
download hosts, size limits, compression, path traversal, repeated installation
and repair from the verified cache. Opt-in release checks use private inputs:

- `LIBRONX_ICEDRIVE_PROBE_URL` and `LIBRONX_ICEDRIVE_PROBE_SHA256`: download a known
  encrypted object without authentication and compare its independently recorded hash.
- `LIBRONX_DOWNLOAD_PROBE_CODE_FILE` and `LIBRONX_DOWNLOAD_PROBE_KEY_FILE`: install
  a one-resource collection, read it through the native reader, and repeat the code.
- `LIBRONX_PUBLISHED_CATALOG_RECEIPTS` and `LIBRONX_DOWNLOAD_PROBE_KEY_FILE`: test
  every published code, encrypted hash, decoded catalog and member address.

The tests do not imply every book or original-format feature has been exercised.
The release evidence records the exact collections and reader checks performed.
