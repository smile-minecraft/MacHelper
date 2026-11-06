#!/usr/bin/env python3
"""After a build (scripts/install.sh), lists strings the compiler extracted that are missing a
translation in any shipped language, and catalog entries no code uses any more."""
import glob, json, os, re
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
B = os.path.join(ROOT, 'build/Build/Intermediates.noindex')
TARGETS = {'App/Resources/Localizable.xcstrings': B + '/MacHelper.build/Release/MacHelper.build/Objects-normal/arm64/*.stringsdata',
           'Sources/CleanEngine/Localizable.xcstrings': B + '/MacHelperKit.build/Release/CleanEngine-t.build/Objects-normal/arm64/*.stringsdata'}
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
raise SystemExit(0 if ok else 1)
