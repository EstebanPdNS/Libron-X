"""Exercise the maintained postings CLI with authored numeric index fixtures.

Optional original comparison uses an explicitly supplied immutable pair and a
numeric-only independent fixture. Original instructions are not executed;
book text is not decoded or emitted.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def u16(value):
    return struct.pack('<H', value)


def u32(value):
    return struct.pack('<I', value)


def literal_dcl(raw):
    # PKWARE binary literal flag 0, dictionary bits 4, literal records, then
    # length symbol 15 / extra 255 terminator. Final consumed-byte padding only.
    bits = []
    for byte in raw:
        bits.extend([0] + [(byte >> i) & 1 for i in range(8)])
    bits.extend([1] + [0] * 7 + [1] * 8)
    return b'\0\x04' + bytes(sum((bits[j + i] if j + i < len(bits) else 0) << i
                                 for i in range(8)) for j in range(0, len(bits), 8))


def packet(blocks, hint=1):
    output = u16(0) + u16(1) + u16(hint)
    for i, (indicator, raw) in enumerate(blocks):
        assert 0 < len(raw) < 32768
        output += bytes([indicator]) + u16(len(raw) | (0x8000 if i == len(blocks) - 1 else 0)) + raw
    return output


def container(kind, chunks):
    def size(chunk):
        _, data, children = chunk
        return sum(8 + size(child) for child in children) if children else len(data)

    def count(chunk):
        return 1 + sum(count(child) for child in chunk[2])

    directory_size = 18 + sum(count(chunk) for chunk in chunks) * 18
    header = bytearray(44)
    header[:4] = b'LSFF'
    header[8:12] = kind.encode()
    header[36:40] = b'pcr '
    header[40:44] = u32(directory_size)
    directory = bytearray(b'LSFF' + kind.encode() + bytes(10))
    payload = bytearray()

    def emit(chunk, offset):
        tag, data, children = chunk
        directory.extend(tag.encode() + u32(0) + u32(size(chunk)) + u32(offset + 8) + u16(len(children)))
        result = bytearray(tag.encode() + u32(size(chunk)))
        if children:
            for child in children:
                result.extend(emit(child, offset + len(result)))
        else:
            result.extend(data)
        return result

    for chunk in chunks:
        payload.extend(emit(chunk, 44 + directory_size + len(payload)))
    result = header + directory + payload
    result[4:8] = u32(len(result) - 8)
    return bytes(result)


def chunk(tag, data=b'', children=()):
    return tag, data, children


def make_pair(root, name, first, second, *, mismatch=False, first_count=2, body=True):
    lsf, lix = root / (name + '.LSF'), root / (name + '.LIX')
    identifier = bytes.fromhex('01000000030000003500')
    lsf.write_bytes(container('GTTL', [chunk('bkid', identifier)]))
    rows = u32(0) + u32(0) + u32(first_count) + u32(5) + u32(len(first)) + u32(1)
    children = [chunk('info', u16(0) + u32(2) + u16(1)), chunk('klst', b'\0Own\0\x02Z\0'),
                chunk('hlst', rows), chunk('hits', first + second)]
    chunks = [chunk('bkid', u16(1) + (bytes(10) if mismatch else identifier))]
    if body:
        chunks.append(chunk('BWDX', children=children))
    lix.write_bytes(container('BIDX', chunks))
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
    cli = args.cli.resolve()
    root = Path(tempfile.mkdtemp(prefix='libronx-postings-cli-'))
    env = os.environ.copy()
    env['PATH'] = os.pathsep.join(args.runtime_dir + [env.get('PATH', '')])
    first_numeric = bytes.fromhex('000000000900000002000f00000003060003000000040700')
    second_numeric = bytes.fromhex('07000000ffffffff0100ffffffffff ffff')
    first_dcl = literal_dcl(first_numeric)
    first_packet = packet([(2, first_dcl)])
    second_packet = packet([(0, second_numeric[:10]), (0, second_numeric[10:])])
    pairs = {
        'valid': make_pair(root, 'own', first_packet, second_packet),
        'mismatch': make_pair(root, 'wrong-pair', first_packet, second_packet, mismatch=True),
        'count': make_pair(root, 'wrong-count', first_packet, second_packet, first_count=3),
        'tail': make_pair(root, 'dcl-tail', packet([(1, first_dcl + b'\0')]), second_packet),
        'missing': make_pair(root, 'missing-index', first_packet, second_packet, body=False),
    }
    own_hashes = {path: digest(path) for pair in pairs.values() for path in pair}
    calls, groups = [], []

    def invoke(arguments, expected=0):
        run = subprocess.run([str(cli), *map(str, arguments)], capture_output=True, env=env, timeout=60)
        calls.append({'arguments': [str(x).replace(str(root), '<own-fixture>') for x in arguments],
                      'exitCode': run.returncode, 'stdoutSHA256': hashlib.sha256(run.stdout).hexdigest(),
                      'stderrSHA256': hashlib.sha256(run.stderr).hexdigest()})
        assert run.returncode == expected, (arguments, run.returncode, run.stderr.decode('utf-8', 'replace'))
        if expected:
            assert not run.stdout and run.stderr.endswith(b'\n')
            return None
        assert run.stdout.endswith(b'\n') and not run.stderr
        return json.loads(run.stdout)

    def group(name, body):
        start = len(calls)
        try:
            body()
            groups.append({'id': name, 'passed': True, 'processCalls': len(calls) - start})
        except Exception as error:
            groups.append({'id': name, 'passed': False, 'processCalls': len(calls) - start, 'error': str(error)})

    def read_pair(name, row=0, expected=0):
        return invoke(['postings', *pairs[name], '--dictionary-row', row], expected)

    def boundary_rows():
        first, last = read_pair('valid'), read_pair('valid', 1)
        assert [first['hitCount'], first['groupCount']] == [2, 1]
        assert first['entry']['postings']['leadingMetadataWord'] == 0
        assert not first['leadingWordMatchesGroupCount']
        assert base64.b64decode(first['entry']['dictionaryKeyBytes']) == b'\0Own\0'
        records = first['entry']['postings']['groups'][0]['postings']
        assert [(x['positionBits'], x['extentBits'], x['metadataBits']) for x in records] == [(15, 3, 6), (3, 4, 7)]
        assert last['entry']['postings']['groups'][0]['articleBits'] == 0xffffffff
        assert last['entry']['postings']['groups'][0]['postings'][0]['metadataBits'] == 0xffff
        assert all(source['verifiedAfter'] for result in [first, last] for source in result['sources'])
        for result in [first, last]:
            assert not result['originalEvaluationVerified'] and not result['originalPositionUnitVerified']

    group('POSTCLI01', boundary_rows)

    def usage():
        for arguments in [['postings'], ['postings', *pairs['valid']],
                          ['postings', *pairs['valid'], '--row', 0],
                          ['postings', *pairs['valid'], '--dictionary-row', -1],
                          ['postings', *pairs['valid'], '--dictionary-row', '9' * 80]]:
            invoke(arguments, 64)

    group('POSTCLI02', usage)
    group('POSTCLI03', lambda: read_pair('valid', 2, 1))
    group('POSTCLI04', lambda: read_pair('mismatch', expected=1))
    group('POSTCLI05', lambda: read_pair('count', expected=1))
    group('POSTCLI06', lambda: read_pair('tail', expected=1))
    group('POSTCLI07', lambda: read_pair('missing', expected=1))
    original = None

    if args.original_selection:
        selection = json.loads(args.original_selection.read_text(encoding='utf-8'))
        fixture = json.loads(args.original_fixture.read_text(encoding='utf-8'))
        sources = [args.workspace / record['path'] for record in selection['pair']]
        source_hashes = {path: record['sha256'] for path, record in zip(sources, selection['pair'])}
        assert all(digest(path) == sha for path, sha in source_hashes.items())

        def original_comparison():
            nonlocal original
            result = invoke(['postings', *sources, '--dictionary-row', selection['dictionary_row']])
            rows = []
            for group_ordinal, g in enumerate(result['entry']['postings']['groups']):
                for ordinal, hit in enumerate(g['postings']):
                    rows.append({'group_ordinal': group_ordinal, 'within_group_ordinal': ordinal,
                        'article_wire': g['articleBits'], 'position_wire': hit['positionBits'],
                        'extent_wire': hit['extentBits'], 'opaque_metadata_u16': hit['metadataBits'],
                        'stream_record_offset': hit['decodedOffset'],
                        'group_header_offset': g['decodedOffset']})
            expected_rows = fixture['records']
            assert rows == expected_rows, 'Maintained CLI differs from the independent numeric fixture.'
            assert result['entry']['packetFileOffset'] == selection['postings_absolute_offset']
            assert result['entry']['packetByteCount'] == selection['postings_length']
            assert result['hitCount'] == selection['third_dictionary_dword_preserved']
            assert result['entry']['postings']['leadingMetadataWord'] == fixture['leading_metadata_word']
            assert result['groupCount'] == fixture['observed_group_count']
            assert all(digest(path) == sha for path, sha in source_hashes.items())
            original = {'rowsCompared': len(rows), 'groupsCompared': result['groupCount'],
                        'decodedBytes': result['entry']['postings']['decodedByteCount'],
                        'packetBytes': result['entry']['packetByteCount'], 'sourceHashesPreserved': True,
                        'selectionSHA256': digest(args.original_selection), 'fixtureSHA256': digest(args.original_fixture),
                        'originalCodeExecuted': False, 'bookTextRetained': False}

        group('POSTCLI08', original_comparison)

    preserved = all(digest(path) == sha for path, sha in own_hashes.items())
    result = {'schema': 1, 'scope': 'Maintained BWDX postings CLI; numeric records only',
              'cliSHA256': digest(cli), 'verifierSHA256': digest(Path(__file__)),
              'passedGroups': sum(x['passed'] for x in groups), 'totalGroups': len(groups),
              'processCalls': calls, 'groups': groups, 'originalSyntheticSourcesPreserved': preserved,
              'originalComparison': original, 'fullOriginalSearchParity': False}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'passedGroups': result['passedGroups'], 'totalGroups': result['totalGroups'],
                      'processCalls': len(calls), 'originalComparison': original, 'sourcesPreserved': preserved}))
    return 0 if result['passedGroups'] == len(groups) and preserved else 1


if __name__ == '__main__':
    raise SystemExit(main())
