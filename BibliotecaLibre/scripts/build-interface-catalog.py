#!/usr/bin/env python3
"""Build the owned UI catalog. Book content never enters this pipeline."""
import json
from pathlib import Path
root = Path(__file__).resolve().parent.parent
codes = ['es', 'en', 'pt', 'fr', 'zh-Hans', 'hi', 'ar', 'bn', 'id', 'ur']
catalog = {}
for number, line in enumerate((root / 'Localization/Interface.tsv').read_text().splitlines(), 1):
    columns = line.split('|')
    if len(columns) != len(codes) or any(not value.strip() for value in columns):
        raise SystemExit(f'Invalid translation row {number}')
    key = columns[0]
    if key in catalog:
        raise SystemExit(f'Duplicate translation key: {key}')
    catalog[key] = dict(zip(codes, columns))
for key in ['100 %', 'HTML…', 'PDF…']:
    catalog[key] = dict.fromkeys(codes, key)
for key, suffix in [('Cerrar búsqueda', ' (Esc)'), ('Coincidencia anterior', ' (⇧⌘G)'), ('Coincidencia siguiente', ' (⌘G)')]:
    catalog[key + suffix] = {code: value + suffix for code, value in catalog[key].items()}
# Validate named-placeholder parity, allowing translators to reorder placeholders.
import re
for key, values in catalog.items():
    expected = set(re.findall(r'\{([A-Za-z]+)\}', key))
    for code, value in values.items():
        if set(re.findall(r'\{([A-Za-z]+)\}', value)) != expected:
            raise SystemExit(f'Placeholder mismatch: {key} ({code})')
output = root / 'Sources/MacRebuild/Resources/Interface.json'
output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
print(f'{len(catalog)} interface keys × {len(codes)} languages')
