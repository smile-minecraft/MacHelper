#!/usr/bin/env python3
"""After a build (scripts/install.sh), lists strings the compiler extracted that are missing a
translation in any shipped language, and catalog entries no code uses any more."""
import glob, json, os, re
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DERIVED_DATA = os.environ.get('DERIVED_DATA', 'build')
B = os.path.join(ROOT, DERIVED_DATA, 'Build/Intermediates.noindex')
TARGETS = {'App/Resources/Localizable.xcstrings': B + '/MacHelper.build/Release/MacHelper.build/Objects-normal/arm64/*.stringsdata',
           'Sources/CleanEngine/Localizable.xcstrings': B + '/MacHelperKit.build/Release/CleanEngine-t.build/Objects-normal/arm64/*.stringsdata',
           'Sources/Diagnostics/Localizable.xcstrings': B + '/MacHelperKit.build/Release/Diagnostics-t.build/Objects-normal/arm64/*.stringsdata'}
LANGS = ['zh-Hant', 'zh-Hans', 'ja', 'ko', 'es']
TRIVIAL = re.compile(r'^[\s%@lldf°·:：()/–-]*( ?(rpm|°C|W|s))?$|^(App|CPU|GPU|GB)$')
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])')


def placeholders(text):
    # Argument positions may move between languages, but the type of every placeholder must match.
    return sorted(PLACEHOLDER.findall(text))


# L10N_ONLY limits the check to catalogs whose path contains this text. It lets a parallel
# change verify its own catalog without reading the shared Localizable.xcstrings.
ONLY = os.environ.get('L10N_ONLY', '')
ok = True
for cat, pattern in TARGETS.items():
    if ONLY and ONLY not in cat:
        continue
    used = set()
    for f in glob.glob(pattern):
        for table, entries in json.load(open(f)).get('tables', {}).items():
            if table == 'Localizable': used.update(e['key'] for e in entries)
    strings = json.load(open(os.path.join(ROOT, cat), encoding='utf-8'))['strings']
    missing = sorted(f'{k} [{l}]' for k in used if not TRIVIAL.match(k)
                     for l in LANGS if l not in strings.get(k, {}).get('localizations', {}))
    unused = sorted(set(strings) - used)
    print(f'{cat}: {len(used)} used, {len(missing)} untranslated, {len(unused)} unused')
    for k in missing: print('  untranslated:', k)
    for k in unused: print('  unused:', repr(k))
    ok = ok and not missing
# Dedicated catalogs are also looked up by table name at run time, so the compiler cannot prove
# which keys the code uses. Every key must carry every shipped language and keep its placeholders.
DEDICATED = ['App/Resources/DiskCapacityHistory.xcstrings',
             'App/Resources/NetworkDetails.xcstrings',
             'App/Resources/DiskVolumeSelection.xcstrings']
for cat in DEDICATED:
    if ONLY and ONLY not in cat:
        continue
    strings = json.load(open(os.path.join(ROOT, cat), encoding='utf-8'))['strings']
    gaps = sorted(f'{k} [{l}]' for k, v in strings.items() for l in LANGS
                  if l not in v.get('localizations', {}))
    print(f'{cat}: {len(strings)} keys, {len(gaps)} untranslated')
    for g in gaps: print('  untranslated:', g)
    for k, v in strings.items():
        expected = placeholders(k)
        for l, loc in v.get('localizations', {}).items():
            value = loc.get('stringUnit', {}).get('value', '')
            if placeholders(value) != expected:
                print(f'  placeholder mismatch: {k} [{l}]')
                ok = False
    ok = ok and not gaps

# Rule text is looked up by key at run time, so every key needs every language (names such as
# "Node.js" that only carry en are left to fall back to English).
rules_path = 'Sources/CleanEngine/Rules.xcstrings'
if not ONLY or ONLY in rules_path:
    rules = json.load(open(os.path.join(ROOT, rules_path), encoding='utf-8'))['strings']
    gaps = sorted(f'{k} [{l}]' for k, v in rules.items() if 'zh-Hant' in v.get('localizations', {})
                  for l in LANGS if l not in v['localizations'])
    print(f'{rules_path}: {len(rules)} keys, {len(gaps)} untranslated')
    for g in gaps: print('  untranslated:', g)
    ok = ok and not gaps
raise SystemExit(0 if ok else 1)
