"""Execute bounded CLI contracts against project-owned synthetic fixtures.

The fixture JSON is emitted by the diagnostic CLIFixture generator. No original
programs or commercial resources are needed. Native Mac output needs a separate
platform runner; this verifier records that gate instead of simulating it.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--fixture-json', type=Path)
parser.add_argument('--report', required=True, type=Path)
parser.add_argument('--runtime-dir', action='append', default=[])
parser.add_argument('--shared-fixture-root', type=Path)
args = parser.parse_args()
if sys.platform == 'darwin':
    parser.error('This verifier tests non-Mac capability rejection; native Mac output needs its own acceptance runner.')
if args.fixture_json:
    fixture = json.loads(args.fixture_json.read_text(encoding='utf-8-sig'))
else:
    from cli_fixture import generate
    fixture = generate()
root = Path(fixture['root']).resolve()
source = Path(fixture['file']).resolve()
assert source.parent == root and source.name == 'own.LSF'
input_files = {p: digest for p, digest in [(source, hashlib.sha256(source.read_bytes()).hexdigest()),
    (source.with_suffix('.LIX'), hashlib.sha256(source.with_suffix('.LIX').read_bytes()).hexdigest())]}
input_source = source
root = Path(tempfile.mkdtemp(prefix='libronx-cli-contract-')).resolve()
source = root / 'own.LSF'
shutil.copyfile(input_source, source)
shutil.copyfile(input_source.with_suffix('.LIX'), source.with_suffix('.LIX'))
env = os.environ.copy()
env['PATH'] = os.pathsep.join(args.runtime_dir + [env.get('PATH', '')])
cases = []
calls = []

def digest(data):
    return hashlib.sha256(data).hexdigest()

def invoke(argv, expected=0, decode=True):
    process = subprocess.run([str(args.cli.resolve()), *map(str, argv)], capture_output=True, timeout=20, env=env)
    sanitized = [str(x).replace(str(root), '<own-fixture>') for x in argv]
    if args.shared_fixture_root:
        sanitized = [x.replace(str(args.shared_fixture_root.resolve()), '<own-shared-fixture>') for x in sanitized]
    calls.append({'arguments': sanitized,
        'exitCode': process.returncode, 'stdoutSHA256': digest(process.stdout), 'stderrSHA256': digest(process.stderr)})
    assert process.returncode == expected, (argv, process.returncode, process.stderr.decode('utf-8', 'replace'))
    if expected == 0:
        assert process.stdout.endswith(b'\n') and not process.stderr
        return json.loads(process.stdout) if decode else process.stdout
    assert not process.stdout and process.stderr.endswith(b'\n')
    return process.stderr.decode('utf-8', 'replace')

def group(number, body):
    start = len(calls)
    try:
        body()
        cases.append({'id': f'WINCLI{number:02}', 'passed': True, 'processCalls': len(calls) - start})
    except Exception as error:
        cases.append({'id': f'WINCLI{number:02}', 'passed': False, 'processCalls': len(calls) - start,
            'error': str(error).replace(str(root), '<own-fixture>')})

originals = {p: digest(p.read_bytes()) for p in root.iterdir() if p.is_file()}
opaque = root / 'own.LBXLLS'; opaque.write_bytes(bytes.fromhex('4c544553000001010800000000000000'))
broken = root / 'bad.LBXOEB'; broken.write_bytes(b'own invalid header')
notes = root / 'own notes.xml'
body = '<P>Own שלום 😀.</P>'
notes.write_text(f'<lbx-annotations><annotation guid="own"><title>Own</title><content type="text/html"><![CDATA[{body}]]></content></annotation></lbx-annotations>', encoding='utf-8')
verses = root / 'own verses.xml'; verses.write_text('<lbx-verse-list><refs style="BothTwoColumns"><ref>bible.64.1.1</ref></refs></lbx-verse-list>', encoding='utf-8')

def catalog():
    report = invoke([root]); assert len(report['resources']) == 3
group(1, catalog)
group(2, lambda: invoke([root / 'missing'], 1))
search = ['search', root, '--file', source.name, '--query']
def searches():
    for flags in [[], ['--substrings'], ['--verses'], ['--case-sensitive', '--ignore-diacritics']]:
        value = invoke([*search, 'Own', *flags]); assert value['counts']['resultsReturned'] > 0
        assert all(x['verifiedAfter'] for x in value['sources'])
        assert value['sources'][0]['sha256'] == digest(source.read_bytes())
group(3, searches)
def usage():
    for argv in [['search'], ['search', root, '--unknown', 'x'], [*search], [*search, 'Own', '--file', 'own.LSF'],
                 ['search', root, '--file', '../own.LSF', '--query', 'Own']]: invoke(argv, 64)
group(4, usage)
def invalid_search():
    invoke([*search, '"unterminated'], 1); invoke([*search, 'Own', '--max-results', '-1'], 1)
group(5, invalid_search)
def bounded():
    absent = invoke([*search, 'Absentword']); assert absent['counts']['resultsReturned'] == 0
    limited = invoke([*search, 'Own', '--max-articles', '1']); assert not limited['coverageComplete']
    incompatible = invoke(['search', root, '--file', opaque.name, '--query', 'Own']); assert incompatible['counts']['resourcesIncompatible'] == 1
group(6, bounded)
def documents():
    report = invoke(['document', notes]); assert report['roundTripEquivalent']
    assert report['sourceSHA256'] == digest(notes.read_bytes()) and report['notes'][0]['bodySHA256'] == digest(body.encode())
    assert report['notes'][0]['titleSHA256'] == digest(b'Own')
    assert invoke(['document', verses])['verseCount'] == 1
group(7, documents)
def invalid_document():
    for i, data in enumerate([b'<broken>', b'<!DOCTYPE a [<!ENTITY x "own">]><lbx-annotations/>', b'x' * (16 * 1024 * 1024 + 1)]):
        path = root / f'invalid-{i}.xml'; path.write_bytes(data); invoke(['document', path], 1)
group(8, invalid_document)
position = 'LLS-AOL:0.0.3'
def locators():
    report = invoke(['locator', source, fixture['id'], position]); assert report['range'] == {'location': 0, 'length': 3}
    assert report['selectedTextSHA256'] == digest(b'Own')
    invoke(['locator', source, 'LLS:9.9.9', position], 1)
    invoke(['locator', source, fixture['id'], 'LLS-AOL:0.99999.1'], 1)
group(9, locators)
def index_case():
    directory = root / 'case'; directory.mkdir(exist_ok=True)
    shutil.copyfile(source, directory / 'own.LSF'); shutil.copyfile(source.with_suffix('.LIX'), directory / 'own.lix')
    expected = 0 if os.name == 'nt' else 1
    invoke(['locator', directory / 'own.LSF', fixture['id'], position], expected)
group(10, index_case)
def typography():
    direct = invoke(['typography', source]); directory = invoke(['typography', root])
    assert direct == directory and direct['resources'][0]['sourceVerifiedAfter']
    assert not direct['generalRenderingParityVerified']
group(11, typography)
def bad_typography():
    invoke(['typography', root / 'missing.LSF'], 1)
    invoke(['typography', broken], 1)
group(12, bad_typography)
def unsupported_valid():
    output = root / 'no-output-valid'
    message = invoke(['output', source, '0', output], 1)
    assert 'requires macOS' in message and not output.exists()
group(13, unsupported_valid)
def unsupported_selection():
    output = root / 'no-output-selection'
    invoke(['output', source, '0', output, '4', '5'], 1); assert not output.exists()
group(14, unsupported_selection)
def unsupported_missing():
    output = root / 'no-output-missing'
    message = invoke(['output', root / 'missing.LSF', '0', output], 1)
    assert 'requires macOS' in message and not output.exists()
    protected = root / 'protected'; protected.mkdir(exist_ok=True)
    sentinel = protected / 'reader-output.txt'; sentinel.write_bytes(b'own sentinel')
    invoke(['output', source, '0', protected], 1); assert sentinel.read_bytes() == b'own sentinel'
    assert len(list(protected.iterdir())) == 1
group(15, unsupported_missing)
def dispatch():
    for argv in [[], ['a', 'b'], ['typography', 'a', 'b'], ['document', 'a', 'b']]: invoke(argv, 64)
    for argv in [['typography'], ['document'], ['locator'], ['output']]: invoke(argv, 1)
group(16, dispatch)
def unicode_paths():
    directory = root / 'own space שלום 😀'; directory.mkdir(exist_ok=True)
    doc = directory / 'own notes 😀.xml'; shutil.copyfile(notes, doc)
    assert invoke(['document', doc])['sourceSHA256'] == digest(notes.read_bytes())
    assert invoke([directory])['resources'] == []
group(17, unicode_paths)
def streaming():
    directory = root / 'large'; directory.mkdir(exist_ok=True)
    lsf = directory / 'own.LSF'; data = source.read_bytes() + b'\0' * (3 * 65536); lsf.write_bytes(data)
    shutil.copyfile(source.with_suffix('.LIX'), directory / 'own.LIX')
    report = invoke(['search', directory, '--file', 'own.LSF', '--query', 'Own'])
    assert report['sources'][0]['sha256'] == digest(data) and report['sources'][0]['size'] == len(data)
group(18, streaming)
if args.shared_fixture_root:
    def shared_directory():
        shared = args.shared_fixture_root.resolve()
        shared.mkdir(parents=True, exist_ok=True)
        shared_file = shared / 'own.LSF'
        if any(path.name != 'own.LSF' for path in shared.iterdir()):
            raise ValueError('Shared fixture directory must be empty or contain only this synthetic own.LSF.')
        if shared_file.exists() and digest(shared_file.read_bytes()) != digest(source.read_bytes()):
            raise ValueError('Refusing to replace a shared file that differs from the generated synthetic fixture.')
        shutil.copyfile(source, shared_file)
        before = digest(shared_file.read_bytes())
        direct = invoke(['typography', shared_file])
        listed = invoke(['typography', shared])
        assert len(listed['resources']) == 1 and direct == listed
        assert digest(shared_file.read_bytes()) == before
    group(19, shared_directory)

preserved = all(digest(path.read_bytes()) == expected for path, expected in originals.items())
preserved = preserved and all(digest(path.read_bytes()) == expected for path, expected in input_files.items())
report = {'schema': 1, 'platform': sys.platform, 'groups': cases, 'processCalls': calls,
    'passedGroups': sum(x['passed'] for x in cases), 'totalGroups': len(cases), 'originalSyntheticSourcesPreserved': preserved,
    'cliSHA256': digest(args.cli.read_bytes()),
    'nativeMacOutputAcceptance': 'pending; Windows groups13/14 assert capability rejection only',
    'cancellationAndConcurrentMutationProcessAcceptance': 'pending; existing core tests remain separate',
    'scope': 'Synthetic CLI process contracts; no commercial content or original artifact writes'}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'passedGroups': report['passedGroups'], 'totalGroups': len(cases), 'processCalls': len(calls), 'syntheticSourcesPreserved': preserved}))
sys.exit(0 if report['passedGroups'] == len(cases) and preserved else 1)
