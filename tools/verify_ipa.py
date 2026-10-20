#!/usr/bin/env python3
"""Unsigned iPhone IPA integrity check. Does not validate LiveContainer runtime."""
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path
BASE = Path(__file__).resolve().parents[1]


def verify_device_binary(binary):
    if len(binary) < 32 or binary[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Not thin 64-bit Mach-O')
    _, cpu, _, kind, commands, command_size, _, _ = struct.unpack_from('<8I', binary)
    if cpu != 0x0100000C or kind != 2:
        raise ValueError('Not an ARM64 application executable')
    end = 32 + command_size
    if end > len(binary):
        raise ValueError('Truncated Mach-O commands')
    offset = 32
    platforms = []
    for _ in range(commands):
        if offset + 8 > end:
            raise ValueError('Truncated Mach-O command')
        command, size = struct.unpack_from('<2I', binary, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError('Invalid Mach-O command size')
        if command == 0x32:  # LC_BUILD_VERSION, PLATFORM_IOS=2, IOSSIMULATOR=7.
            if size < 24:
                raise ValueError('Truncated build version')
            platforms.append(struct.unpack_from('<I', binary, offset + 8)[0])
        offset += size
    if offset != end or platforms != [2]:
        raise ValueError('Not built for an iOS device (LC_BUILD_VERSION)')


def verify(ipa):
    project = json.loads((BASE/'Config/project.json').read_text())
    version = json.loads((BASE/'Config/version.json').read_text())
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError('Corrupt ZIP entry')
        prefix = f'Payload/{project["name"]}.app/'
        info = plistlib.loads(archive.read(prefix+'Info.plist'))
        if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
            raise ValueError('Not an iPhoneOS bundle')
        if info.get('CFBundleIdentifier') != project['bundleIdentifier']:
            raise ValueError('Incorrect bundle identifier')
        if info.get('CFBundleShortVersionString') != version['version'] or info.get('CFBundleVersion') != str(version['build']):
            raise ValueError('Incorrect bundle version/build')
        verify_device_binary(archive.read(prefix+info['CFBundleExecutable']))
    return f'PASS: {ipa.name}: ARM64 iPhoneOS {project["bundleIdentifier"]} v{version["version"]} ({version["build"]}); runtime not tested'


if __name__ == '__main__':
    print(verify(Path(sys.argv[1])))
