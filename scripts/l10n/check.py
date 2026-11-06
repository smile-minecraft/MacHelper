#!/usr/bin/env python3
"""After a build (scripts/install.sh), lists strings the compiler extracted that are missing a
translation in any shipped language, and catalog entries no code uses any more."""
import glob, json, os, re
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
B = os.path.join(ROOT, 'build/Build/Intermediates.noindex')
TARGETS = {'App/Resources/Localizable.xcstrings': B + '/MacHelper.build/Release/MacHelper.build/Objects-normal/arm64/*.stringsdata',
           'Sources/CleanEngine/Localizable.xcstrings': B + '/MacHelperKit.build/Release/CleanEngine-t.build/Objects-normal/arm64/*.stringsdata',
           'Sources/Diagnostics/Localizable.xcstrings': B + '/MacHelperKit.build/Release/Diagnostics-t.build/Objects-normal/arm64/*.stringsdata'}
LANGS = ['zh-Hant', 'zh-Hans', 'ja', 'ko', 'es']
TRIVIAL = re.compile(r'^[\s%@lldf°·:：()/–-]*( ?(rpm|°C|W|s))?$|^(App|CPU|GPU|GB)$')
ok = True
for cat, pattern in TARGETS.items():
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
# Rule text is looked up by key at run time, so every key needs every language (names such as
# "Node.js" that only carry en are left to fall back to English).
rules = json.load(open(os.path.join(ROOT, 'Sources/CleanEngine/Rules.xcstrings'), encoding='utf-8'))['strings']
gaps = sorted(f'{k} [{l}]' for k, v in rules.items() if 'zh-Hant' in v.get('localizations', {})
              for l in LANGS if l not in v['localizations'])
print(f'Sources/CleanEngine/Rules.xcstrings: {len(rules)} keys, {len(gaps)} untranslated')
for g in gaps: print('  untranslated:', g)
ok = ok and not gaps
raise SystemExit(0 if ok else 1)
