#!/usr/bin/env python3
"""Release planner contract checks using a throwaway Git repo. Python stdlib only."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
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
        result=self.call(sys.executable,'tools/release.py','plan')
        self.assertIn('minor 0.1.0 -> 0.2.0',result.stdout)
        self.call(sys.executable,'tools/release.py','prepare','--version','0.2.0')
        self.assertEqual(json.loads((self.path/'Config/version.json').read_text()),{'version':'0.2.0','build':2})
        self.assertIn('feat(search): allow Russian OCR',(self.path/'CHANGELOG.md').read_text())

    def test_patch_and_none(self):
        self.assertIn('none',(self.call(sys.executable,'tools/release.py','plan').stdout))
        self.commit('fix(db): handle unicode strings','b')
        self.assertIn('patch 0.1.0 -> 0.1.1',(self.call(sys.executable,'tools/release.py','plan').stdout))

    def test_major_and_invalid_message(self):
        self.commit('feat(api)!: change stored data format','c')
        self.assertIn('major 0.1.0 -> 1.0.0',(self.call(sys.executable,'tools/release.py','plan').stdout))
        self.assertNotEqual(self.call(sys.executable,'tools/release.py','check-message','--message','random commit',ok=False).returncode,0)

    def test_beta_lifecycle(self):
        (self.path/'Config/release.json').write_text('{"baseVersion":"1.0.0","channel":"beta"}\n')
        self.commit('feat(backup): preserve library','beta')
        output=self.path/'outputs.txt'
        self.call(sys.executable,'tools/release.py','plan','--output',str(output))
        self.assertIn('tag=1.0.0-beta.1',output.read_text())
        self.assertIn('prerelease=true',output.read_text())
        self.call(sys.executable,'tools/release.py','prepare','--version','1.0.0','--tag','1.0.0-beta.1')
        self.assertEqual(json.loads((self.path/'Config/version.json').read_text()),{'version':'1.0.0','build':2})
        self.assertIn('## v1.0.0-beta.1',(self.path/'CHANGELOG.md').read_text())
        self.commit('chore(release): v1.0.0-beta.1','released')
        self.call('git','tag','v1.0.0-beta.1')
        self.assertIn('plan: none',self.call(sys.executable,'tools/release.py','plan').stdout)
        self.commit('fix(backup): handle missing files','next')
        output.unlink()
        self.call(sys.executable,'tools/release.py','plan','--output',str(output))
        self.assertIn('tag=1.0.0-beta.2',output.read_text())
        self.call(sys.executable,'tools/release.py','prepare','--version','1.0.0','--tag','1.0.0-beta.2')
        self.assertEqual(json.loads((self.path/'Config/version.json').read_text())['build'],3)

if __name__=='__main__': unittest.main()
