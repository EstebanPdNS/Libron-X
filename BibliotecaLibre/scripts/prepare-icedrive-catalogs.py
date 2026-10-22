#!/usr/bin/env python3
"""Bind encrypted catalogs to verified Icedrive public file IDs, without network access.

The remote index is private release evidence, never a source-controlled fixture.
Only the resulting .lxcollection files are intended for the hosting service.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--distribution', type=Path, required=True)
    parser.add_argument('--remote-index', type=Path, required=True)
    parser.add_argument('--collections', type=Path, required=True)
    parser.add_argument('--crypto-tool', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--probe-manifest', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    key = args.distribution / 'private/recovery-key.txt'
    secret = key.read_bytes()
    if len(secret) != 30 or not secret.isalnum() or not secret.isascii():
        raise ValueError('The existing 30-character distribution key is required')
    remote = json.loads(args.remote_index.read_text())['objects']
    objects = {item['name']: item for item in remote}
    if len(objects) != len(remote) or len({item['id'] for item in remote}) != len(remote):
        raise ValueError('Remote object names and file IDs must be unique')
    collections = json.loads(args.collections.read_text())
    jobs = [(args.distribution / 'private' / (item['id'] + '.json'), item['file']) for item in collections]
    if args.probe_manifest:
        jobs.append((args.probe_manifest, 'Connection Test.lxcollection'))
    prepared = []
    for path, name in jobs:
        if Path(name).name != name or not name.endswith('.lxcollection'):
            raise ValueError('Unsafe catalog filename')
        manifest = json.loads(path.read_text())
        if manifest.get('schemaVersion') != 2:
            raise ValueError('Only file-deduplicated collection version 2 is supported')
        members = [f for entry in manifest['resources'] for f in entry['files']]
        members += manifest.get('readingFonts', [])
        for member in members:
            item = objects.get(Path(member['object']).name)
            if not item or item['bytes'] != member['downloadBytes'] or not isinstance(item['id'], int) or item['id'] <= 0:
                raise ValueError('Missing or mismatched remote object: ' + member['object'])
            member['url'] = f"https://apis.icedrive.net/v3/webapp/download-multi&items=file-{item['id']}&public=1"
        manifest.pop('baseURL', None)
        manifest.pop('status', None)
        prepared.append((name, manifest))
    private = args.output / 'private'
    upload = args.output / 'upload'
    private.mkdir(parents=True, exist_ok=True)
    upload.mkdir(parents=True, exist_ok=True)
    receipts = []
    for name, manifest in prepared:
        plain = private / (name + '.json')
        plain.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(',', ':')))
        encrypted = upload / name
        subprocess.run([str(args.crypto_tool), 'seal', str(key), str(plain), str(encrypted)], check=True)
        verified = private / 'roundtrip.json'
        subprocess.run([str(args.crypto_tool), 'open', str(key), str(encrypted), str(verified)], check=True)
        if verified.read_bytes() != plain.read_bytes():
            raise ValueError('Encrypted catalog failed its round-trip check')
        verified.unlink()
        receipts.append({'file': name, 'id': manifest['id'], 'title': manifest['title'],
                         'resources': len(manifest['resources']), 'bytes': encrypted.stat().st_size,
                         'sha256': hashlib.sha256(encrypted.read_bytes()).hexdigest()})
    (args.output / 'catalog-receipts.json').write_text(json.dumps(receipts, ensure_ascii=False, indent=2))
    print(json.dumps({'catalogsPrepared': len(receipts), 'remoteObjects': len(objects),
                      'encryptedBytes': sum(item['bytes'] for item in receipts)}))


if __name__ == '__main__':
    main()
