# Libron-X Query Reference

This portable component implements an independently written, bounded reference for two observed original query dialects and the advanced-to-engine translation contract. It uses Python's standard library. It is a research and compatibility reference, separate from the application's Swift search engine.

The bundled synthetic fixtures reproduce 124 parser acceptance outcomes, including 86 accepted ASTs, and 47 translation outcomes, including 37 successful translations. They contain only synthetic query inputs, normalized behavioral trees and provenance hashes. The counts describe this fixed corpus, not complete grammar or search parity. No original DLL, JavaScript, decompiled code, private path, book content, credential or user metadata is required.

## Use

From this directory:

```text
python query_reference.py verify
python query_reference.py parse --mode basic --query "faith hope"
python query_reference.py parse --mode advanced --query "faith NOT fear" --translate
```

`verify` compares the independent parser and translator with every bundled record and writes a JSON summary to stdout. It returns 0 when all comparisons match and 1 on a mismatch. It reads the bundled fixtures without changing them. Parser acceptance, exact AST matching and translation matching have separate denominators.

`parse` returns a normalized JSON tree. `--mode basic` selects the observed basic contract; `--mode advanced` selects the observed advanced contract. `--translate` is available only for advanced mode and returns the serialized engine-query reference. Invalid syntax returns a JSON error and exit code 1. Invalid CLI usage or fixture schema returns exit code 2. Error messages and categories belong to this component and are not original HRESULT/diagnostic equivalents.

All input reaches the parser as data. No command executes user queries, searches books, loads scripts, calls a network or changes application settings. There are no third-party dependencies, installed services, environment variables or implicit input directories.

## Contract and limits

`parse(query, mode) -> normalized tree` preserves term text and source UTF-16 spans. `translate_advanced(tree) -> normalized engine tree` lowers the observed advanced AST to term identities and separate constraints. Returned values belong to the caller; no file or process remains open.

The parser limits input to 16,384 UTF-16 units, 512 tokens and nesting depth 32. Wrong modes and unsupported verified-subset parameters fail explicitly. Fixture input is limited to 4 MiB and 2,048 uniquely identified cases per file. The fixture schema is version 1; unknown versions are refused. Dictionary ordering does not affect tree comparison. Child order and exact Unicode term text do. The fixtures retain repeated language observations rather than deduplicating them into an inflated feature count.

Observed basic adjacency becomes nested OR, while advanced adjacency becomes a natural node and translates to AND. NOT, proximity precedence, field syntax and WITHIN availability differ between modes. Advanced accepted-node offsets use UTF-16 source units, include quoted delimiters and retain combining/supplementary widths. Literal escaped-quote text is retained. These rules are verified against the bundled cases; additional compositions remain provisional.

Translation serializes observed default NEAR distance, ordering and field constraints. It does not evaluate them. Default distance units, tokenization, wildcard matching, field schema, error-coordinate units, morphological/graphical syntax, result ordering and complete grammar remain unresolved. Unsupported engine semantics must not be represented as a successful empty search in a consuming application.

## Maintenance

Keep the independent implementation separate from recorded expected outputs. Add a fixture only after preserving its input, parser mode, language, normalized original output and recording hash. Synthetic acceptance fixtures must not contain book text or private data. A passing fixture replay is not a claim of native application or original search-result parity.

Run `verify` after changing parser behavior or fixtures. Validate from a clean copied directory as well as the development checkout so the component cannot depend on private diagnostics. The CLI summary includes fixture hashes and exact counts for reproducible audit. See `PROVENANCE.json` for the recording hashes and observation scope.
