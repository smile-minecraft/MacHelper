#!/usr/bin/env python3
"""Add or update zh-Hant translations in a String Catalog.
Usage: add.py <catalog.xcstrings> 'English key' '中文' ['key2' '中文2' ...]"""
import json, sys
path, pairs = sys.argv[1], sys.argv[2:]
assert len(pairs) % 2 == 0, 'pairs of key and translation expected'
doc = json.load(open(path, encoding='utf-8'))
for k, v in zip(pairs[::2], pairs[1::2]):
    doc['strings'].setdefault(k, {}).setdefault('localizations', {})['zh-Hant'] = {'stringUnit': {'state': 'translated', 'value': v}}
doc['strings'] = dict(sorted(doc['strings'].items()))
with open(path, 'w', encoding='utf-8') as f:
    json.dump(doc, f, ensure_ascii=False, indent=2); f.write('\n')
print(f'{len(pairs)//2} entries -> {path}')
