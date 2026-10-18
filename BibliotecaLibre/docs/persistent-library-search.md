# Persistent library search


`PersistentLibrarySearchProvider` wraps a stamped content provider with a private, rebuildable SQLite cache. Resource identity, source/database/manifest stamps and the article directory bind each cache generation. Records preserve full reader text, UTF-16 extents, explicit Bible intervals and shared-page article ranges. Original resource files and normalized reader databases remain read-only.

An FTS5 trigram index supplies conservative article candidates; `TextSearchEngine` remains the match authority. ASCII candidate pruning never substitutes SQLite Unicode rules for Foundation matching: Unicode documents, short operands, negations and unindexed articles remain eligible. Bible-verse searches reuse cached records but still evaluate actual verse intervals. See the official SQLite FTS5 trigram documentation: https://www.sqlite.org/fts5.html#the_trigram_tokenizer.

The cache stores payload and candidate-metadata checksums, validates SQLite/FTS structure, uses a consistent read snapshot for candidate sets, invalidates changed source generations and recovers damaged derivative files. Cancellation cannot leave a write transaction open. At most eight resource connections stay open per provider. Unsupported SQLite/cache availability falls back to the original provider; it never converts cache failure into a no-match result. `articlesRuledOutByIndex` is separate from articles examined and does not consume the decode budget. Cold searches build indexes incrementally under existing explicit budgets.

The index is an implementation of independent product search, not proof of original Libronix index semantics. Original proximity/order acceptance and advanced linguistic queries retain their own gates.
