#!/usr/bin/env python3
"""Portable query reference CLI. All queries are data; no search is executed."""

import argparse
import hashlib
import json
from pathlib import Path
import sys

from reference_parser import parse, translate_advanced, ParseFailure

DIRECTORY = Path(__file__).resolve().parent
MODES = {"basic": "QueryParser", "advanced": "AdvancedQueryParser"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_fixture(name):
    path = DIRECTORY / "fixtures" / name
    data = path.read_bytes()
    if len(data) > 4 * 1024 * 1024:
        raise ValueError("Query fixture exceeds the 4 MiB limit")
    document = json.loads(data.decode("utf-8"))
    if document.get("schema_version") != 1 or not isinstance(document.get("cases"), list):
        raise ValueError("Unsupported or invalid query fixture schema")
    cases = document["cases"]
    if len(cases) > 2048 or len({case["case_id"] for case in cases}) != len(cases):
        raise ValueError("Query fixture exceeds the case limit or duplicates case identities")
    if any(not isinstance(case.get("query"), str) for case in cases):
        raise ValueError("Query fixture contains a non-text query")
    return path, document


def verify():
    parser_path, parser_fixture = load_fixture("parser-cases.json")
    translation_path, translation_fixture = load_fixture("translation-cases.json")
    accepted, acceptance_matches, ast_matches, translation_matches, failures = 0, 0, 0, 0, []
    for case in parser_fixture["cases"]:
        actual = None
        try:
            actual = parse(case["query"], case["parser_mode"])
        except ParseFailure:
            pass
        expected_accepted = case["expected_accepted"]
        accepted += expected_accepted
        acceptance_match = (actual is not None) == expected_accepted
        ast_match = actual == case["expected_ast"] if expected_accepted else None
        acceptance_matches += acceptance_match
        ast_matches += ast_match is True
        if not acceptance_match or ast_match is False:
            failures.append(dict(kind="parser", case_id=case["case_id"], acceptance_matches=acceptance_match, ast_matches=ast_match))
    translation_accepted = 0
    for case in translation_fixture["cases"]:
        actual = None
        try:
            actual = translate_advanced(parse(case["query"], "AdvancedQueryParser"))
        except ParseFailure:
            pass
        match = actual == case["expected_tree"]
        translation_matches += match
        translation_accepted += case["expected_translated"]
        if not match:
            failures.append(dict(kind="translation", case_id=case["case_id"]))
    summary = dict(schema_version=1, component="Libron-X Query Reference",
                   parser_cases=len(parser_fixture["cases"]), parser_acceptance_matches=acceptance_matches,
                   accepted_original_ast_cases=accepted, exact_accepted_ast_matches=ast_matches,
                   translation_cases=len(translation_fixture["cases"]), translation_original_accepted=translation_accepted,
                   translation_outcome_matches=translation_matches, failures=failures, passed=not failures,
                   fixture_hashes={"parser": digest(parser_path), "translation": digest(translation_path)},
                   grammar_complete=False, search_engine_executed=False, native_swift_parser_executed=False)
    print(json.dumps(summary, ensure_ascii=True, indent=2))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("verify", help="Compare every bundled synthetic behavior fixture")
    parse_command = subcommands.add_parser("parse", help="Parse a query without executing a search")
    parse_command.add_argument("--mode", choices=MODES, required=True)
    parse_command.add_argument("--query", required=True)
    parse_command.add_argument("--translate", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.command == "verify":
            return verify()
        if arguments.translate and arguments.mode != "advanced":
            parser.error("--translate requires --mode advanced")
        tree = parse(arguments.query, MODES[arguments.mode])
        if arguments.translate:
            tree = translate_advanced(tree)
        print(json.dumps(dict(schema_version=1, mode=arguments.mode, translated=arguments.translate,
                              tree=tree, search_executed=False), ensure_ascii=True, indent=2))
        return 0
    except ParseFailure as failure:
        print(json.dumps(dict(schema_version=1, error=str(failure), original_diagnostic_equivalence=False)))
        return 1
    except (ValueError, KeyError, TypeError, OSError) as failure:
        print(json.dumps(dict(schema_version=1, error=str(failure))))
        return 2


if __name__ == "__main__":
    sys.exit(main())
