#!/usr/bin/env python3
"""Reject simulator archives and malformed device binaries."""
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile
from verify_ipa import BASE, verify, verify_device_binary


def binary(platform=2, cpu=0x0100000C):
    header = struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
    return header + struct.pack('<6I', 0x32, 24, platform, 0x110000, 0x1B0000, 0)


class IPATests(unittest.TestCase):
    def test_device_and_simulator(self):
        verify_device_binary(binary())
        for invalid in [binary(platform=7), binary(platform=1), binary(cpu=0x01000007), binary()[:40], b'PK\x03\x04']:
            with self.subTest(binary=invalid), self.assertRaises(ValueError):
                verify_device_binary(invalid)

    def test_malformed_commands(self):
        for size in [0, 4, 16, 25, 64]:
            data = bytearray(binary())
            struct.pack_into('<I', data, 36, size)
            with self.subTest(size=size), self.assertRaises(ValueError):
                verify_device_binary(data)

    def test_archive_metadata(self):
        project = json.loads((BASE/'Config/project.json').read_text())
        version = json.loads((BASE/'Config/version.json').read_text())
        info = dict(CFBundleExecutable=project['name'], CFBundleSupportedPlatforms=['iPhoneOS'], CFBundleIdentifier=project['bundleIdentifier'], CFBundleShortVersionString=version['version'], CFBundleVersion=str(version['build']))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'test.ipa'
            def write(metadata):
                with zipfile.ZipFile(path, 'w') as archive:
                    prefix = f'Payload/{project["name"]}.app/'
                    archive.writestr(prefix+'Info.plist', plistlib.dumps(metadata))
                    archive.writestr(prefix+project['name'], binary())
            write(info)
            self.assertIn('ARM64 iPhoneOS', verify(path))
            for key, value in [('CFBundleSupportedPlatforms',['iPhoneSimulator']), ('CFBundleVersion','9999999'), ('CFBundleIdentifier','invalid')]:
                write(dict(info, **{key:value}))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    verify(path)


if __name__ == '__main__':
    unittest.main()
