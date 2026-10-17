#!/usr/bin/env python3
"""Audit packaged e-Sword content with the application's deterministic pipeline.

The default is read-only. --write-sidecars updates derived audit reports only;
immutable source payloads and manifests are never modified.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--library', required=True, type=pathlib.Path)
parser.add_argument('--inspect', required=True, type=pathlib.Path)
parser.add_argument('--report', required=True, type=pathlib.Path)
parser.add_argument('--write-sidecars', action='store_true')
args = parser.parse_args()
records = []
for package in sorted(args.library.glob('*.libron')):
    manifest = json.loads((package/'manifest.json').read_text())
    if manifest['sourceFormat'] != 'eSwordSQLite':
        continue
    payload = (package/manifest['payload']['path']).resolve()
    if not payload.is_relative_to(package.resolve()):
        raise ValueError('Payload escapes its package')
    before = hashlib.sha256(payload.read_bytes()).hexdigest()
    if before != manifest['payload']['sha256']:
        raise ValueError('Payload checksum mismatch: '+package.name)
    completed = subprocess.run([str(args.inspect.resolve()), 'import-audit', str(payload)], check=True, capture_output=True, text=True)
    audit = json.loads(completed.stdout)
    if hashlib.sha256(payload.read_bytes()).hexdigest() != before:
        raise ValueError('Audit modified immutable payload: '+package.name)
    if args.write_sidecars:
        destination = package/'import-formatting-audit.json'
        temporary = destination.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(audit, ensure_ascii=False, indent=2)+'\n')
        temporary.replace(destination)
    records.append(dict(package=package.name, sha256=before, audit=audit))
report = dict(resources=len(records), entries=sum(r['audit']['entries'] for r in records), records=records)
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
print(json.dumps(dict(resources=report['resources'], entries=report['entries'], originalPayloadsPreserved=True)))
