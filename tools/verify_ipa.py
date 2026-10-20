#!/usr/bin/env python3
"""Unsigned iPhone IPA integrity check. Does not validate LiveContainer runtime."""
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path
base=Path(__file__).resolve().parents[1]
name=json.loads((base/'Config/project.json').read_text())['name']
ipa=Path(sys.argv[1])
with zipfile.ZipFile(ipa) as z:
    assert z.testzip() is None, 'Corrupt ZIP entry'
    prefix=f'Payload/{name}.app/'
    info=plistlib.loads(z.read(prefix+'Info.plist'))
    executable=info['CFBundleExecutable']
    binary=z.read(prefix+executable)
    assert binary[:4] == b'\xcf\xfa\xed\xfe', 'Not thin 64-bit Mach-O (check arm64 device build)'
    assert struct.unpack_from('<I',binary,4)[0] == 0x0100000C, 'Not an ARM64 executable'
    version=json.loads((base/'Config/version.json').read_text())['version']
    assert info['CFBundleShortVersionString'] == version, 'Incorrect bundle version'
    print(f'PASS: {ipa.name}: ARM64 {info["CFBundleIdentifier"]} v{version}; runtime not tested')
