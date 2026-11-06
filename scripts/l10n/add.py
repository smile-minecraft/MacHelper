#!/usr/bin/env python3
"""Add or update translations in a String Catalog (zh-Hant unless --lang is given).
Usage: add.py [--lang ja] <catalog.xcstrings> 'English key' 'translation' ['key2' 'translation2' ...]"""
import json, sys
args = sys.argv[1:]
lang = 'zh-Hant'
if args[:1] == ['--lang']:
    lang, args = args[1], args[2:]
path, pairs = args[0], args[1:]
assert len(pairs) % 2 == 0, 'pairs of key and translation expected'
doc = json.load(open(path, encoding='utf-8'))
for k, v in zip(pairs[::2], pairs[1::2]):
    loc = doc['strings'].setdefault(k, {}).setdefault('localizations', {})
    loc[lang] = {'stringUnit': {'state': 'translated', 'value': v}}
    doc['strings'][k]['localizations'] = dict(sorted(loc.items()))
doc['strings'] = dict(sorted(doc['strings'].items()))
with open(path, 'w', encoding='utf-8') as f:
    json.dump(doc, f, ensure_ascii=False, indent=2); f.write('\n')
print(f'{len(pairs)//2} entries -> {path}')
