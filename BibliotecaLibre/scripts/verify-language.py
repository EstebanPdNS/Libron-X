"""Exercise serialized language inspection and explicit weighted comparison.

Uses authored tables with nonordinal weights, a contraction and capability
failures. Optional original comparison checks only serialized metadata/hashes;
it neither executes original code nor exports original strings or tables.
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

spec = importlib.util.spec_from_file_location('authored_container', Path(__file__).with_name('verify-postings.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def profile(language=0x1234, collation=0x5678, *, callback=b'', version=1):
    word = lambda n: struct.pack('<H', n)
    string = lambda b: word(len(b)) + b
    data = (word(version) if version is not None else b'') + word(language)
    data += word(0x2345) + word(0xabcd) + b'\x89'
    data += string(b'\xff\x00\x81') + string(b'\xc1') + string(b'\x80\xfe')
    if version is not None and version > 0:
        data += string(b'\x00\xff') + b'\xfa'
    data += b''.join(string(callback if i == 3 else b'') for i in range(7))
    return data + b''.join(word(n) for n in (0, 0, 0x4567, collation, 0x6789))


def collation(identifier, rows):
    return struct.pack('<HH', identifier, len(rows)) + b''.join(struct.pack('<5H', *r) for r in rows)


def serialized_metadata(raw):
    """Independent scalar metadata decoder; deliberately no weight implementation."""
    assert raw[:4] == b'LSFF' and raw[8:12] == b'LANG'
    assert struct.unpack_from('<I', raw, 4)[0] + 8 == len(raw)
    directory = struct.unpack_from('<I', raw, 40)[0]
    assert raw[36:40] == b'pcr ' and directory % 18 == 0
    profiles, tables = [], []
    for at in range(62, 44 + directory, 18):
        tag = raw[at:at + 4]
        size, offset = struct.unpack_from('<II', raw, at + 8)
        assert raw[offset - 8:offset - 4] == tag
        assert struct.unpack_from('<I', raw, offset - 4)[0] == size
        packet = raw[offset:offset + size]
        assert len(packet) == size
        if tag == b'ldat':
            cursor = 0

            def word():
                nonlocal cursor
                result = struct.unpack_from('<H', packet, cursor)[0]
                cursor += 2
                return result

            def string():
                nonlocal cursor
                count = word()
                assert count < 32768
                result = packet[cursor:cursor + count]
                assert len(result) == count
                cursor += count
                return result

            first = word()
            version, language = (first, word()) if first <= 100 else (None, first)
            unit_map = word(); word(); cursor += 1
            module = string(); string(); string()
            if version is not None and version > 0:
                string(); cursor += 1
            callbacks = [string() for _ in range(7)]
            word(); word(); word(); collation_id = word(); word()
            assert cursor == len(packet)
            entry = {'languageIdentifier': language, 'unitMapIdentifier': unit_map,
                     'collationIdentifier': collation_id, 'moduleNameByteCount': len(module),
                     'nonemptyCallbackSlots': [i for i, b in enumerate(callbacks) if b],
                     'packetByteCount': len(packet), 'packetSHA256': digest(packet)}
            if version is not None:
                entry['serializedVersion'] = version
            profiles.append(entry)
        elif tag == b'coll':
            identifier, count = struct.unpack_from('<HH', packet)
            assert len(packet) == 4 + 10 * count
            primary = [struct.unpack_from('<H', packet, 8 + 10 * i)[0] for i in range(count)]
            tables.append({'identifier': identifier, 'rowCount': count,
                           'maximumPrimaryWeight': max(primary, default=0),
                           'packetByteCount': len(packet), 'packetSHA256': digest(packet)})
    return profiles, tables, directory // 18 - 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--runtime-dir', action='append', default=[])
    parser.add_argument('--original-language', type=Path)
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='libronx-language-cli-'))
    rows = [[n, 0, n, 0, 0] for n in range(40, 81)]
    rows[25][2], rows[26][2], rows[27][2] = 700, 600, 900
    rows.insert(27, [67, 104, 10, 0, 0])
    packets = [fixtures.chunk('ldat', profile()),
               fixtures.chunk('coll', collation(0x5678, rows)),
               fixtures.chunk('ldat', profile(0x4321, callback=b'own-callback', version=None)),
               fixtures.chunk('ldat', profile(0x040c, 0x040c, version=0)),
               fixtures.chunk('coll', collation(0x040c, rows))]

    def write(name, chunks):
        path = root / (name + '.DAT')
        path.write_bytes(fixtures.container('LANG', chunks))
        return path

    own = write('own language', packets)
    ambiguous = write('duplicate profile', [fixtures.chunk('ldat', profile()), fixtures.chunk('ldat', profile())])
    missing = write('missing collation', [fixtures.chunk('ldat', profile())])
    negative = bytearray(profile()); negative[9:11] = b'\xff\xff'
    malformed = write('signed string length', [fixtures.chunk('ldat', bytes(negative))])
    tail = write('packet tail', [fixtures.chunk('ldat', profile() + b'\0')])
    physical = root / 'physical header.DAT'
    physical_raw = bytearray(own.read_bytes())
    first_header = 44 + struct.unpack_from('<I', physical_raw, 40)[0]
    physical_raw[first_header] ^= 1
    physical.write_bytes(physical_raw)
    oversized = root / 'budget.DAT'
    with oversized.open('wb') as stream:
        stream.truncate(16 * 1024 * 1024 + 1)
    paths = [own, ambiguous, missing, malformed, tail, physical, oversized]
    before = {p: digest(p.read_bytes()) for p in paths}
    env = os.environ.copy()
    env['PATH'] = os.pathsep.join(args.runtime_dir + [env.get('PATH', '')])
    calls, groups = [], []
    original = None

    def run(arguments, expected=0, original_file=False):
        proc = subprocess.run([str(args.cli), 'language', *map(str, arguments)], env=env,
                              capture_output=True, timeout=60)
        shown = [str(a).replace(str(root), '<own-fixture>') for a in arguments]
        if original_file:
            shown[0] = '<original-language-data>'
        calls.append({'arguments': shown, 'exitCode': proc.returncode,
                      'stdoutSHA256': digest(proc.stdout), 'stderrSHA256': digest(proc.stderr)})
        assert proc.returncode == expected, (shown, proc.returncode, proc.stderr.decode('utf-8', 'replace'))
        if expected:
            assert not proc.stdout and proc.stderr.endswith(b'\n')
            return None
        assert proc.stdout.endswith(b'\n') and not proc.stderr
        return json.loads(proc.stdout)

    def group(name, action):
        start = len(calls)
        try:
            action()
            groups.append({'id': name, 'passed': True, 'processCalls': len(calls) - start})
        except Exception as error:
            groups.append({'id': name, 'passed': False, 'processCalls': len(calls) - start, 'error': str(error)})

    def metadata(path, original_file=False):
        result = run([path], original_file=original_file)
        profiles, tables, count = serialized_metadata(path.read_bytes())
        assert result['profiles'] == profiles and result['collations'] == tables
        assert result['directoryRecordCount'] == count
        assert result['source']['byteCount'] == path.stat().st_size
        assert result['source']['sha256'] == digest(path.read_bytes()) and result['sourceVerifiedAfter']
        assert not any(result[k] for k in ('nativeModuleLoaded', 'originalLiveContextVerified',
                                         'originalEvaluationVerified', 'normalizationApplied'))
        assert 'selectedProfile' not in result and 'comparison' not in result
        return result

    group('LANGCLI01', lambda: metadata(own))

    def explicit_selection():
        first = run([own, '--profile', '0x1234'])
        second = run([own, '--profile', '4660'])
        assert first == second and first['selectedProfile'] == first['profiles'][0]
        assert 'comparison' not in first
    group('LANGCLI02', explicit_selection)

    def comparisons():
        for left, right, expected in [('A', 'B', 1), ('Ch', 'C', -1), ('A', 'a', -1),
                                      ('A', 'A', 0), ('', 'A', -1), ("'", 'A', 1), ('\U0001f600', '', 1)]:
            result = run([own, '--profile', '0x1234', '--compare', left, right])
            value = result['comparison']
            assert value['ordering'] == expected
            assert value['leftUnitCount'] == len(left.encode('utf-16le')) // 2
            assert value['rightUnitCount'] == len(right.encode('utf-16le')) // 2
    group('LANGCLI03', comparisons)

    def capabilities():
        for code in ['0x4321', '0x040c']:
            assert run([own, '--profile', code])['selectedProfile']
            run([own, '--profile', code, '--compare', 'A', 'B'], 1)
        run([own, '--profile', '7'], 1)
        run([missing, '--profile', '0x1234', '--compare', 'A', 'B'], 1)
    group('LANGCLI04', capabilities)

    def ambiguous_selection():
        assert len(run([ambiguous])['profiles']) == 2
        run([ambiguous, '--profile', '0x1234'], 1)
    group('LANGCLI05', ambiguous_selection)

    def bad_inputs():
        for path in (malformed, tail, physical, oversized):
            run([path], 1)
        run([own, '--profile', '0x1234', '--compare', 'a' * 4097, 'A'], 1)
    group('LANGCLI06', bad_inputs)

    def usage():
        for arguments in [[], [own, '--compare', 'A', 'B'], [own, '--profile'],
                          [own, '--profile', '7', '--profile', '8'], [own, '--wat'],
                          *[[own, '--profile', n] for n in ['65536', '-1', '+1', '0x', '\u0661']]]:
            run(arguments, 64)
    group('LANGCLI07', usage)

    if args.original_language:
        original_before = digest(args.original_language.read_bytes())

        def original_metadata():
            nonlocal original
            result = metadata(args.original_language, original_file=True)
            assert digest(args.original_language.read_bytes()) == original_before
            original = {'profilesCompared': len(result['profiles']), 'collationsCompared': len(result['collations']),
                        'sourceSHA256': original_before, 'originalSourcePreserved': True,
                        'comparisonScope': 'Serialized numeric metadata and raw packet hashes only',
                        'nativeCodeExecuted': False, 'stringsOrTablesExported': False}
        group('LANGCLI08', original_metadata)

    preserved = all(digest(p.read_bytes()) == sha for p, sha in before.items())
    report = {'schema': 1, 'scope': 'Authored weighted comparison and explicit serialized profile selection',
              'cliSHA256': digest(args.cli.read_bytes()), 'verifierSHA256': digest(Path(__file__).read_bytes()),
              'passedGroups': sum(g['passed'] for g in groups), 'totalGroups': len(groups),
              'processCalls': calls, 'groups': groups, 'ownSourcesPreserved': preserved,
              'originalComparison': original, 'fullOriginalSearchParity': False}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'passedGroups': report['passedGroups'], 'totalGroups': len(groups),
                      'processCalls': len(calls), 'ownSourcesPreserved': preserved, 'originalComparison': original}))
    return 0 if preserved and all(g['passed'] for g in groups) else 1


if __name__ == '__main__':
    raise SystemExit(main())
