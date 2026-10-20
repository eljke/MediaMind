#!/usr/bin/env python3
"""Pure-Python Conventional Commits/SemVer tools. No external dependencies."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BASE=Path(__file__).resolve().parents[1]
CONF=BASE/'Config/version.json'
PATTERN=re.compile(r'^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-zA-Z0-9_.-]+\))?(!)?: .{3,}$')
VERSION=re.compile(r'^\d+\.\d+\.\d+$')

def git(*args): return subprocess.check_output(['git',*args], cwd=BASE,text=True).strip()

def commits_since_tag():
    tags=[tag for tag in git('tag','--list','v[0-9]*').splitlines() if re.match(r'^v\d+\.\d+\.\d+$',tag)]
    if not tags:
        # A fresh repository: inspect all commits; initial chore alone does not trigger release.
        source='HEAD'
    else:
        tag=max(tags,key=lambda t:tuple(map(int,t[1:].split('.'))))
        source=f'{tag}..HEAD'
    raw=git('log','--format=%s%x1f%b%x1e',source)
    return [(s.partition('\x1f')[0].strip(),s.partition('\x1f')[2]) for s in raw.split('\x1e') if s.strip()]

def level(messages):
    n=0
    for subject,body in messages:
        match=PATTERN.match(subject)
        if not match: continue
        if match.group(3) or re.search(r'(?m)^BREAKING[ -]CHANGE:',body): n=max(n,3)
        elif match.group(1)=='feat': n=max(n,2)
        elif match.group(1) in ('fix','perf'): n=max(n,1)
    return ['none','patch','minor','major'][n]

def bump(ver,kind):
    a,b,c=map(int,ver.split('.'))
    return {'major': f'{a+1}.0.0','minor':f'{a}.{b+1}.0','patch':f'{a}.{b}.{c+1}', 'none':ver}[kind]

def cmd_plan(out):
    cfg=json.loads(CONF.read_text())
    which=level(commits_since_tag())
    new=bump(cfg['version'],which)
    print(f'plan: {which} {cfg["version"]} -> {new}')
    if out:
        with open(out,'a',encoding='utf-8') as f:
            f.write(f'should_release={str(which!="none").lower()}\nversion={new}\nlevel={which}\n')

def cmd_prepare(version):
    if not VERSION.fullmatch(version): raise ValueError('Version must be n.n.n')
    cfg=json.loads(CONF.read_text())
    expected=bump(cfg['version'],level(commits_since_tag()))
    if version!=expected or version==cfg['version']:
        raise ValueError(f'Unexpected release version: requested {version}, expected {expected}')
    cfg.update(version=version,build=cfg['build']+1)
    CONF.write_text(json.dumps(cfg,ensure_ascii=False,indent=2)+'\n')
    subjects=[subject for subject,_ in commits_since_tag() if PATTERN.match(subject) and not subject.startswith('chore(release):')]
    changelog=BASE/'CHANGELOG.md'
    old=changelog.read_text() if changelog.exists() else '# Changelog\n\n'
    heading=f'## v{version}\n\n'+''.join('- '+s+'\n' for s in reversed(subjects))+'\n'
    changelog.write_text(old.replace('# Changelog\n\n','# Changelog\n\n'+heading,1))
    print(f'prepared v{version} build {cfg["build"]}')

def cmd_validate(base=None):
    if base:
        raw=git('log','--no-merges','--format=%s',f'{base}..HEAD')
    else:
        raw=git('log','-1','--format=%s')
    failures=[s for s in raw.splitlines() if s and not PATTERN.match(s)]
    if failures:
        print('Invalid Conventional Commits: '+repr(failures),file=sys.stderr)
        sys.exit(1)
    print('Conventional Commit checks passed')

p=argparse.ArgumentParser()
p.add_argument('command',choices=['plan','prepare','validate','check-message'])
p.add_argument('--output');p.add_argument('--version');p.add_argument('--base');p.add_argument('--message')
a=p.parse_args()
try:
    if a.command=='plan': cmd_plan(a.output)
    elif a.command=='prepare': cmd_prepare(a.version or '')
    elif a.command=='validate': cmd_validate(a.base)
    else:
        if not PATTERN.match(a.message or ''): raise ValueError('Conventional Commit required: type(scope): description')
except (ValueError,subprocess.CalledProcessError) as e:
    sys.exit(str(e))
