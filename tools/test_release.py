#!/usr/bin/env python3
"""Release planner contract checks using a throwaway Git repo. Python stdlib only."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO=Path(__file__).resolve().parents[1]

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)
        (self.path/'tools').mkdir()
        (self.path/'Config').mkdir()
        shutil.copy2(REPO/'tools/release.py',self.path/'tools/release.py')
        (self.path/'Config/version.json').write_text('{"version":"0.1.0","build":1}\n')
        (self.path/'CHANGELOG.md').write_text('# Changelog\n\n')
        self.call('git','init','-b','master')
        self.call('git','config','user.name','Automated Test')
        self.call('git','config','user.email','test@example.invalid')
        self.commit('chore: initialize project','initial')
        self.call('git','tag','v0.1.0')

    def call(self,*args,ok=True):
        res=subprocess.run(args,cwd=self.path,text=True,capture_output=True)
        if ok: self.assertEqual(res.returncode,0,res.stderr)
        return res

    def commit(self,message,content):
        (self.path/'change.txt').write_text(content)
        self.call('git','add','.');self.call('git','commit','-m',message)

    def test_minor_then_prepare(self):
        self.commit('feat(search): allow Russian OCR','a')
        result=self.call('python3','tools/release.py','plan')
        self.assertIn('minor 0.1.0 -> 0.2.0',result.stdout)
        self.call('python3','tools/release.py','prepare','--version','0.2.0')
        self.assertEqual(json.loads((self.path/'Config/version.json').read_text()),{'version':'0.2.0','build':2})
        self.assertIn('feat(search): allow Russian OCR',(self.path/'CHANGELOG.md').read_text())

    def test_patch_and_none(self):
        self.assertIn('none',(self.call('python3','tools/release.py','plan').stdout))
        self.commit('fix(db): handle unicode strings','b')
        self.assertIn('patch 0.1.0 -> 0.1.1',(self.call('python3','tools/release.py','plan').stdout))

    def test_major_and_invalid_message(self):
        self.commit('feat(api)!: change stored data format','c')
        self.assertIn('major 0.1.0 -> 1.0.0',(self.call('python3','tools/release.py','plan').stdout))
        self.assertNotEqual(self.call('python3','tools/release.py','check-message','--message','random commit',ok=False).returncode,0)

if __name__=='__main__': unittest.main()
