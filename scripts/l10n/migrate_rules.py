#!/usr/bin/env python3
"""One-time migration: rule/detector JSON text -> English, with zh-Hant in Rules.xcstrings
(keys "rule.<id>.title" / "rule.<id>.description", "detector.<id>.title")."""
import glob, json, os, re
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EN = {
 'browser.safari': ('Safari cache', 'Web cache, downloaded again as you browse. Bookmarks, history and sign-ins are not affected.'),
 'browser.chrome': ('Google Chrome cache', 'Web and code caches. Bookmarks, passwords and extensions are not affected.'),
 'browser.edge': ('Microsoft Edge cache', 'Web and code caches.'),
 'browser.brave': ('Brave cache', 'Web and code caches.'),
 'browser.arc': ('Arc cache', 'Web and code caches.'),
 'browser.firefox': ('Firefox cache', 'Web cache (cache2). Profiles and bookmarks are not affected.'),
 'xcode.derived-data': (None, 'Intermediate build products and indexes, regenerated on the next build (which is slower the first time).'),
 'xcode.previews': ('SwiftUI previews cache', 'Simulated environments for Xcode Previews, rebuilt when needed.'),
 'xcode.device-support': ('Device support files (iOS / watchOS / tvOS DeviceSupport)', 'Symbols downloaded when debugging on a device. Versions unused for 30 days are downloaded again the next time you connect such a device.'),
 'xcode.archives': ('Xcode Archives (older than 180 days)', 'Archives of old builds. Without them you can’t symbolicate crash reports from those versions, so make sure you no longer need them.'),
 'simulator.caches': ('Simulator caches', 'CoreSimulator’s dynamic caches. Apps and data inside simulators are not affected.'),
 'dev.swiftpm': ('Swift Package Manager cache', 'Downloaded package sources, downloaded again when needed.'),
 'dev.npm': ('npm cache', 'npm’s download cache (_cacache), downloaded again when needed.'),
 'dev.yarn': ('Yarn cache', 'Yarn’s package cache.'),
 'dev.pnpm': ('pnpm cache', 'pnpm’s metadata cache. The package store is not included; use pnpm store prune for that.'),
 'dev.pip': ('pip cache', 'Python package download cache.'),
 'dev.homebrew': ('Homebrew download cache', 'Downloaded installers. Installed packages are not affected.'),
 'dev.cargo': ('Cargo registry cache', 'Rust crate archives and extracted sources, downloaded again when needed.'),
 'dev.gradle': ('Gradle cache', 'Dependency and build caches. The next build downloads them again and may take longer.'),
 'dev.cocoapods': ('CocoaPods cache', 'Pod download cache.'),
 'dev.go': ('Go build cache', 'The go build cache, rebuilt automatically.'),
 'dev.node-gyp': ('node-gyp headers cache', 'Headers used to compile native Node modules.'),
 'dev.playwright': ('Playwright browsers', 'Test browsers downloaded by Playwright; run npx playwright install to get them again.'),
 'user.caches': ('App caches', 'Each app’s cache folder, rebuilt by the app when needed. Caches of Apple system components are not included.'),
 'user.logs': ('App logs and crash reports', 'Logs and DiagnosticReports written by apps. MacHelper’s own operation log is never removed.'),
 'user.trash': ('Trash', 'Permanently deletes the items in the Trash. This can’t be undone.'),
 'user.installers': ('Installers in Downloads', 'DMG, PKG, XIP and ISO installers, usually no longer needed once the app is installed.'),
 'user.old-downloads': ('Files in Downloads older than 90 days', 'Check the list first: there may be files here you want to keep.'),
 'user.ios-backups': ('iPhone / iPad backups', 'Local device backups made by Finder. Make sure you have another backup (such as iCloud) before deleting.'),
 'user.mail-downloads': ('Mail attachment downloads', 'Copies of attachments opened in Mail. The original messages are not affected.'),
 'xcode': ('Xcode projects', None),
}
strings = {}
def zh(v): return v and re.search('[一-龥]', v)
for f in sorted(glob.glob(os.path.join(ROOT, 'Sources/CleanEngine/Rules/*.json'))) + [os.path.join(ROOT, 'Sources/CleanEngine/Artifacts/detectors.json')]:
    d = json.load(open(f, encoding='utf-8'))
    items = d.get('rules') or d.get('detectors')
    prefix = 'detector' if 'detectors' in d else 'rule'
    for r in items:
        en = EN.get(r['id'], (None, None))
        for i, k in enumerate(('title', 'description')):
            v = r.get(k)
            if not v: continue
            if zh(v):
                strings[f"{prefix}.{r['id']}.{k}"] = v
                if en[i]: r[k] = en[i]
                else: raise SystemExit(f"missing English for {r['id']} {k}")
    with open(f, 'w', encoding='utf-8') as out:
        json.dump(d, out, ensure_ascii=False, indent=2); out.write('\n')
doc = {'sourceLanguage': 'en', 'version': '1.0', 'strings': {k: {'extractionState': 'manual', 'localizations': {'zh-Hant': {'stringUnit': {'state': 'translated', 'value': v}}}} for k, v in sorted(strings.items())}}
with open(os.path.join(ROOT, 'Sources/CleanEngine/Rules.xcstrings'), 'w', encoding='utf-8') as out:
    json.dump(doc, out, ensure_ascii=False, indent=2); out.write('\n')
print(len(strings), 'rule strings')
