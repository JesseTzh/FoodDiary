#!/usr/bin/env python3
"""Describe the verified APK using package metadata from the APK itself."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

apk = Path(sys.argv[1])
sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ['ANDROID_HOME'])
aapt = sorted((sdk / 'build-tools').glob('*/aapt'), key=lambda p: [int(n) for n in re.findall(r'\d+', p.parent.name)])[-1]
badging = subprocess.check_output([str(aapt), 'dump', 'badging', str(apk)], text=True)
code = int(re.search(r"^package:.*?versionCode='(\d+)'", badging, re.MULTILINE)[1])
digest = hashlib.sha256()
with apk.open('rb') as source:
    for block in iter(lambda: source.read(1024 * 1024), b''):
        digest.update(block)
manifest = {
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'version': Path('frontend/build-version.txt').read_text().strip(),
    'version_code': code,
    'apk': apk.name,
    'sha256': digest.hexdigest(),
    'size': apk.stat().st_size,
}
(apk.parent / 'android-update.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
