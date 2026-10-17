# Third-party code

## PKWARE DCL decompression: Mark Adler's blast

`Sources/CLibronxCompression/blast.c` and `blast.h` come unchanged from
[zlib's official contrib/blast directory](https://github.com/madler/zlib/tree/da607da739fa6047df13e66a2af6b8bec7c2a498/contrib/blast),
zlib tag **v1.3.2**, commit **da607da739fa6047df13e66a2af6b8bec7c2a498**.
The implementation identifies itself as **blast 1.3, 24 August 2013**.
Copyright belongs to **Mark Adler (2003, 2012, 2013)**.

The permissive license and its complete notice remain in
[`blast.h`](Sources/CLibronxCompression/blast.h). It permits use, alteration,
and redistribution subject to preserving the notice, accurately attributing
the original authorship, and marking altered versions. The two upstream source
files have not been altered.

| Source | SHA-256 |
|---|---|
| `blast.c` | `ebe6ec1b37dbd2b03959f453a5eab298621dcb6e593954bf22fe88d1abcfa72e` |
| `blast.h` | `2b99276c3b40fd231a09df942a95a7cf007858e6bdf0a051fe29719316cc58a7` |

`wrapper.c` and `include/LibronxCompression.h` are new project code. They
provide a buffer-bounded API and initialize blast's shared Huffman tables once
before concurrent decoding. The warm-up fixture is the public eight-byte
example published in upstream `blast.c`; it contains no commercial book data.

This dependency implements generic **PKWARE Data Compression Library (DCL)**
decompression. DCL differs from PKZIP's compression method also called
“implode.” It performs no cryptographic key processing or license alteration.
No Libronix proprietary executable, DLL, source code, or book content is part
of this native module.

## LZCS zlib blocks: system libz

The separate `libronx_inflate_zlib` project wrapper links the platform's `libz`
and uses `uncompress2` to validate a zlib-wrapped stream, its Adler-32 trailer,
the output bound, and consumed input length. No zlib library implementation is
copied for this operation. The format and API are described in the
[official zlib manual](https://www.zlib.net/manual.html).

The native LTES configuration reader is project code. Its cryptographic
operations implement the observed XTEA variant with a caller-supplied context;
it contains no context from the proprietary program or library license files.

## Portable SHA-256: Swift Crypto

`Package.swift` pins [Apple Swift Crypto 4.3.1](https://github.com/apple/swift-crypto/tree/bb4ba815dab96d4edc1e0b86d7b9acf9ff973a84),
commit **bb4ba815dab96d4edc1e0b86d7b9acf9ff973a84**. The `Crypto` product is
a dependency of `LibronixCore` on Windows and Linux. Apple builds retain their
existing CryptoKit import. This dependency supplies SHA-256 for the existing
text, asset, and style-file fingerprints; the project does not introduce a
replacement hashing algorithm.

Swift Crypto is copyright Apple Inc. and the SwiftCrypto project authors,
licensed under Apache License 2.0. Its complete
[LICENSE.txt](https://github.com/apple/swift-crypto/blob/bb4ba815dab96d4edc1e0b86d7b9acf9ff973a84/LICENSE.txt)
and [NOTICE.txt](https://github.com/apple/swift-crypto/blob/bb4ba815dab96d4edc1e0b86d7b9acf9ff973a84/NOTICE.txt)
belong with redistributions of the dependency. Its source includes BoringSSL,
XKCP, and other components whose source-level copyright and license notices
must also be retained. The pinned copy identifies its BoringSSL origin as
revision **0226f30467f540a3f62ef48d453f93927da199b6** in
`Sources/CCryptoBoringSSL/hash.txt`.

No Swift Crypto source is copied into the maintained `Sources` directory;
Swift Package Manager obtains the pinned dependency. A downstream binary or
source bundle that includes it must include the corresponding upstream notices.
The verification receipt records the resolved transitive Swift ASN.1 version;
the core uses `Crypto`, not `CryptoExtras`, and does not build Swift ASN.1 for
this target. This source snapshot does not bundle toolchain, SDK, MSVC, zlib, or
package-manager cache files.


## Bundled offline dictionaries

Libron-X includes twelve monolingual definition or synonym datasets, three per
language. The application code license does not replace these data licenses.
Each package includes `ATTRIBUTION.txt`, exact downloaded source data, upstream
notices, the conversion script and file hashes. Converted entries and indexes
remain under their respective source licenses. No endorsement is implied.

| Language | Dataset | Data license |
| --- | --- | --- |
| Spanish | Wikcionario (native Spanish edition, via Kaikki) | CC BY-SA 4.0 |
| Spanish | Spanish WordNet / MCR | CC BY 3.0 |
| Spanish | OpenThesaurus Spanish (LibreOffice distribution) | LGPL 2.1 |
| English | Simple English Wiktionary (via Kaikki) | CC BY-SA 4.0 |
| English | Easton's Bible Dictionary (1897) | Original public domain; electronic dataset CC BY 4.0 |
| English | Smith's Bible Dictionary (1863) | Original public domain; electronic dataset CC BY 4.0 |
| Portuguese | Wikcionário (native Portuguese edition, via Kaikki) | CC BY-SA 4.0 |
| Portuguese | Dicionário Aberto / Cândido de Figueiredo (1913) | CC BY-SA 2.5 Portugal |
| Portuguese | OpenWordnet-PT (synonyms) | CC BY-SA 3.0 |
| Italian | Wikizionario (native Italian edition, via Kaikki) | CC BY-SA 4.0 |
| Italian | MultiWordNet Italian | CC BY 3.0 |
| Italian | Italian thesaurus (Davide Prina and contributors, LibreOffice) | GPL 3.0 |

Wiktionary contributors are credited in each derived entry through its source
page. Source edition downloads: https://kaikki.org/dictionary/rawdata.html .
WordNet notices: https://github.com/omwn/omw-data/tree/main/wns .
Thesaurus sources and licenses: https://github.com/LibreOffice/dictionaries .
Dicionário Aberto resources: https://dicionario-aberto.net/recursos .
Biblical electronic sources: https://github.com/neuu-org/bible-dictionary-dataset .

Synonym datasets are labeled as such; they are not represented as full prose
definition dictionaries. No private imported resource is included in this set.
