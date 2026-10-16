"""Verify exact literal dictionary selection through the maintained real CLI.

Fixtures are authored, source ordered and intentionally unsorted. Optional
original checks use an explicit preserved pair and numeric postings oracle.
No original instructions execute; reports omit original dictionary strings.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

helper_spec = importlib.util.spec_from_file_location('postings_fixtures', Path(__file__).with_name('verify-postings.py'))
fixtures = importlib.util.module_from_spec(helper_spec)
helper_spec.loader.exec_module(fixtures)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def full_key(text):
    return b'\xf0' + text.encode('utf-16le') + b'\0\0'


def make_pair(root, name, keys, *, mismatch=False):
    lsf, lix = root / (name + '.LSF'), root / (name + '.LIX')
    identifier = bytes.fromhex('01000000030000003500')
    lsf.write_bytes(fixtures.container('GTTL', [fixtures.chunk('bkid', identifier)]))
    header_rows, key_table, packets = b'', b'', b''
    for ordinal, key in enumerate(keys):
        header_rows += struct.pack('<III', len(key_table), len(packets), 1)
        key_table += key
        numeric = struct.pack('<IIHI BH', 0, ordinal + 7, 1, ordinal + 10, ordinal + 3, ordinal + 6)
        packets += fixtures.packet([(0, numeric)], hint=8192)
    body = fixtures.chunk('BWDX', children=[
        fixtures.chunk('info', struct.pack('<HIH', 0, len(keys), 1)),
        fixtures.chunk('klst', key_table), fixtures.chunk('hlst', header_rows), fixtures.chunk('hits', packets)])
    lix.write_bytes(fixtures.container('BIDX', [
        fixtures.chunk('bkid', b'\1\0' + (bytes(10) if mismatch else identifier)), body]))
    return lsf, lix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--runtime-dir', action='append', default=[])
    parser.add_argument('--original-selection', type=Path)
    parser.add_argument('--original-fixture', type=Path)
    parser.add_argument('--workspace', type=Path)
    args = parser.parse_args()
    if any([args.original_selection, args.original_fixture, args.workspace]) and not all(
            [args.original_selection, args.original_fixture, args.workspace]):
        parser.error('Original comparison requires selection, numeric fixture and workspace together.')
    root = Path(tempfile.mkdtemp(prefix='libronx-dictionary-cli-'))
    keys = [b'\0zeta\0', b'\0alpha\0', full_key('alpha'), full_key('\u0391'),
            full_key('\u00e9'), full_key('e\u0301'), b'\0\0', b'\0last\0' + bytes(4)]
    pairs = {'valid': make_pair(root, 'own', keys),
             'bad-key': make_pair(root, 'truncated-key', [b'\0alpha\0', b'\0broken']),
             'mismatch': make_pair(root, 'wrong-pair', keys, mismatch=True)}
    before = {p: digest(p) for pair in pairs.values() for p in pair}
    env = os.environ.copy()
    env['PATH'] = os.pathsep.join(args.runtime_dir + [env.get('PATH', '')])
    calls, groups = [], []
    original = None

    def invoke(pair, literal, expected=0, original_literal=False):
        return run(['postings', *pair, '--literal-key', literal], expected, original_literal)

    def run(arguments, expected=0, original_literal=False):
        result = subprocess.run([str(args.cli), *map(str, arguments)], capture_output=True, env=env, timeout=60)
        shown = [str(x).replace(str(root), '<own-fixture>') for x in arguments]
        if original_literal:
            shown[-1] = '<original-literal>'
        calls.append({'arguments': shown, 'exitCode': result.returncode,
                      'stdoutSHA256': hashlib.sha256(result.stdout).hexdigest(),
                      'stderrSHA256': hashlib.sha256(result.stderr).hexdigest()})
        assert result.returncode == expected, (shown, result.returncode, result.stderr.decode('utf-8', 'replace'))
        if expected:
            assert not result.stdout and result.stderr.endswith(b'\n')
            return
        assert result.stdout.endswith(b'\n') and not result.stderr
        return json.loads(result.stdout)

    def group(name, body):
        start = len(calls)
        try:
            body()
            groups.append({'id': name, 'passed': True, 'processCalls': len(calls) - start})
        except Exception as error:
            groups.append({'id': name, 'passed': False, 'processCalls': len(calls) - start, 'error': str(error)})

    def exact_duplicate():
        result = invoke(pairs['valid'], 'alpha')
        assert result['selection']['scannedRows'] == 8
        assert [x['dictionaryRow'] for x in result['selection']['matches']] == [1, 2]
        assert [x['dictionaryRow'] for x in result['entries']] == [1, 2]
        assert [x['postings']['groups'][0]['articleBits'] for x in result['entries']] == [8, 9]
        assert result['hitCount'] == 2
        assert all(x['verifiedAfter'] for x in result['sources'])
        assert not result['originalEvaluationVerified'] and not result['originalNormalizationVerified']
        assert not result['originalPositionUnitVerified']

    group('DICTCLI01', exact_duplicate)

    def unchanged_forms():
        for literal, row in [('ALPHA', None), ('\u00e9', 4), ('e\u0301', 5), ('\u0391', 3)]:
            result = invoke(pairs['valid'], literal)
            assert [x['dictionaryRow'] for x in result['entries']] == ([] if row is None else [row])

    group('DICTCLI02', unchanged_forms)

    def final_and_empty():
        empty, last = invoke(pairs['valid'], ''), invoke(pairs['valid'], 'last')
        assert empty['entries'][0]['dictionaryRow'] == 6
        key = last['selection']['matches'][0]['key']
        assert last['entries'][0]['dictionaryRow'] == 7
        assert key['consumedByteCount'] == 6 and key['storedByteCount'] == 10

    group('DICTCLI03', final_and_empty)
    group('DICTCLI04', lambda: invoke(pairs['bad-key'], 'alpha', 1))
    group('DICTCLI05', lambda: invoke(pairs['mismatch'], 'alpha', 1))

    def usage():
        for arguments in [['postings'], ['postings', *pairs['valid'], '--literal-key'],
                          ['postings', *pairs['valid'], '--literal-key', 'alpha', 'extra']]:
            run(arguments, 64)
    group('DICTCLI06', usage)

    if args.original_selection:
        selection = json.loads(args.original_selection.read_text(encoding='utf-8'))
        fixture = json.loads(args.original_fixture.read_text(encoding='utf-8'))
        sources = [args.workspace / item['path'] for item in selection['pair']]
        original_hashes = {p: item['sha256'] for p, item in zip(sources, selection['pair'])}
        assert all(digest(p) == sha for p, sha in original_hashes.items())

        def original_match():
            nonlocal original
            result = invoke(sources, selection['term_ascii'], original_literal=True)
            assert result['selection']['scannedRows'] == 25163
            assert result['selection']['decodedUnitCount'] == 199142
            assert len(result['entries']) == 1
            entry = result['entries'][0]
            assert entry['dictionaryRow'] == selection['dictionary_row']
            assert entry['packetFileOffset'] == selection['postings_absolute_offset']
            assert entry['packetByteCount'] == selection['postings_length']
            observed = []
            for group_ordinal, g in enumerate(entry['postings']['groups']):
                for ordinal, hit in enumerate(g['postings']):
                    observed.append({'group_ordinal': group_ordinal, 'within_group_ordinal': ordinal,
                        'article_wire': g['articleBits'], 'position_wire': hit['positionBits'],
                        'extent_wire': hit['extentBits'], 'opaque_metadata_u16': hit['metadataBits'],
                        'stream_record_offset': hit['decodedOffset'], 'group_header_offset': g['decodedOffset']})
            assert observed == fixture['records']
            uppercase = invoke(sources, selection['term_ascii'].upper(), original_literal=True)
            assert not uppercase['entries'] and uppercase['hitCount'] == 0
            assert all(digest(p) == sha for p, sha in original_hashes.items())
            original = {'dictionaryRowsScanned': 25163, 'decodedUnits': 199142,
                        'exactMatchingRows': 1, 'numericHitsCompared': len(observed),
                        'groupsCompared': len(entry['postings']['groups']),
                        'originalSourcesPreserved': True, 'normalizationIntentionallyAbsent': True,
                        'originalEngineExecuted': False, 'bookTextDecoded': False,
                        'selectionSHA256': digest(args.original_selection), 'fixtureSHA256': digest(args.original_fixture)}
        group('DICTCLI07', original_match)

    preserved = all(digest(p) == sha for p, sha in before.items())
    report = {'schema': 1, 'scope': 'Exact literal BWDX key scan and checked numeric postings',
              'cliSHA256': digest(args.cli), 'verifierSHA256': digest(Path(__file__)),
              'passedGroups': sum(x['passed'] for x in groups), 'totalGroups': len(groups),
              'processCalls': calls, 'groups': groups, 'ownSourcesPreserved': preserved,
              'originalComparison': original, 'fullOriginalSearchParity': False}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'passedGroups': report['passedGroups'], 'totalGroups': len(groups),
                      'processCalls': len(calls), 'ownSourcesPreserved': preserved, 'originalComparison': original}))
    return 0 if preserved and all(x['passed'] for x in groups) else 1


if __name__ == '__main__':
    raise SystemExit(main())
