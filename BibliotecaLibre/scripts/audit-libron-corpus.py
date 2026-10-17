#!/usr/bin/env python3
"""Account for every source and validate native conversion without source adapters."""
import argparse
import hashlib
import json
import sqlite3
import zlib
from collections import Counter
from pathlib import Path


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def checked_record(body, size, sha):
    assert 0 < size < 64 * 1024 * 1024 and 0 < len(body) < 64 * 1024 * 1024, 'Native record bounds'
    decoder = zlib.decompressobj()
    raw = decoder.decompress(body, size + 1)
    assert decoder.eof and not decoder.unconsumed_tail and not decoder.unused_data, 'Native compression boundary'
    assert len(raw) == size and hashlib.sha256(raw).hexdigest() == sha, 'Native record checksum'
    return raw


def audit(library, source, verify_records):
    packages, failures = [], []
    by_hash = {}
    for path in sorted(library.glob('*.libron')):
        try:
            manifest = json.loads((path / 'manifest.json').read_text())
            payload = path / manifest['payload']['path']
            assert digest(payload) == manifest['payload']['sha256'], 'Original payload checksum mismatch'
            if manifest.get('index'):
                assert digest(path / manifest['index']['path']) == manifest['index']['sha256'], 'Original companion checksum mismatch'
            receipt_path = path / 'normalized/conversion.json'
            receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
            native = path / 'normalized/reader.sqlite'
            complete = receipt.get('state') == 'complete' and native.exists()
            if complete:
                assert receipt['sourceSHA256'] == manifest['payload']['sha256'], 'Receipt identity mismatch'
                assert receipt['sections'] == receipt['checkedSections'], 'Unchecked sections'
                connection = sqlite3.connect(native.as_uri() + '?mode=ro', uri=True)
                try:
                    assert connection.execute('PRAGMA quick_check').fetchone()[0] == 'ok', 'Native SQLite integrity failure'
                    body, size, sha = connection.execute("SELECT body,size,sha256 FROM values_v1 WHERE key='header'").fetchone()
                    header = json.loads(checked_record(body, size, sha))
                    assert header['resourceID'] == manifest['id'] and header['sourceSHA256'] == manifest['payload']['sha256'], 'Native header identity mismatch'
                    assert header['sectionCount'] == receipt['sections'] and receipt['sections'] > 0, 'Native section count mismatch'
                    if header['profile'] == 'structured-text':
                        count = connection.execute("SELECT count(*) FROM values_v1 WHERE key LIKE 'section/%'").fetchone()[0]
                        assert count == receipt['sections'], 'Missing native section'
                    if verify_records:
                        for key, body, size, sha in connection.execute('SELECT key,body,size,sha256 FROM values_v1'):
                            checked_record(body, size, sha)
                finally:
                    connection.close()
                assert manifest.get('normalizedContent'), 'Native content missing from package manifest'
                if manifest.get('normalizedContent'):
                    assert digest(native) == manifest['normalizedContent']['sha256'], 'Native package checksum mismatch'
            item = {'package': str(path), 'sourceSHA256': manifest['payload']['sha256'],
                    'title': manifest['metadata']['title'], 'type': manifest['metadata']['resourceType'],
                    'category': manifest['metadata']['category'], 'languages': manifest['metadata']['languages'],
                    'pendingMetadata': manifest['metadata'].get('pendingFields', []),
                    'nativeComplete': complete, 'sections': receipt.get('checkedSections', 0),
                    'warnings': receipt.get('warnings', [])}
            packages.append(item)
            by_hash.setdefault(item['sourceSHA256'], []).append(item)
        except Exception as error:
            failures.append({'path': str(path), 'error': str(error)})
    resources = {'.bbli', '.bblx', '.dcti', '.cmti', '.refi', '.lexi', '.devi', '.epub', '.lsf', '.lbxlls', '.lbxoeb', '.logos4', '.logos5', '.logos6'}
    files = []
    for path in sorted(source.rglob('*')):
        if not path.is_file():
            continue
        if path.suffix.lower() not in resources:
            files.append({'file': str(path), 'status': 'auxiliary'})
            continue
        sha = digest(path)
        matches = by_hash.get(sha, [])
        files.append({'file': str(path), 'sha256': sha, 'status': 'imported' if matches else 'missing',
                      'packages': [item['package'] for item in matches],
                      'nativeComplete': bool(matches) and all(item['nativeComplete'] for item in matches)})
    return {'counts': {'packages': len(packages), 'nativeComplete': sum(p['nativeComplete'] for p in packages),
                       'sections': sum(p['sections'] for p in packages),
                       'sourceFiles': dict(Counter(f['status'] for f in files)), 'failures': len(failures)},
            'files': files, 'packages': packages, 'failures': failures}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('source', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--verify-records', action='store_true')
    args = parser.parse_args()
    report = audit(args.library.resolve(), args.source.resolve(), args.verify_records)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report['counts'], ensure_ascii=False))
    raise SystemExit(bool(report['failures']) or report['counts']['sourceFiles'].get('missing', 0) > 0 or report['counts']['nativeComplete'] < report['counts']['packages'])
