#!/usr/bin/env python3
"""Generate deterministic native Xcode project without XcodeGen dependencies."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parents[1]
NAME = json.loads((BASE/"Config/project.json").read_text())["name"]
FILES = sorted((BASE/'Sources').rglob('*.swift'))
TEST_FILES = sorted((BASE/'Tests/App').glob('*.swift'))
VERSION = json.loads((BASE/'Config/version.json').read_text())
assert FILES, 'No Swift files found'

def oid(value):
    return hashlib.sha256((NAME+':'+value).encode('utf-8')).hexdigest().upper()[:24]

def ref(value):
    return f'{oid(value)} /* {value.split("/")[-1]} */'

def quote(value):
    return '"' + str(value).replace('\\','\\\\').replace('"','\\"') + '"'

objects = []
def add(name, statements, comment=None):
    body = ''.join('\t\t\t'+s+'\n' for s in statements)
    objects.append(f'\t\t{oid(name)} /* {comment or name.split("/")[-1]} */ = {{\n'+body+'\t\t};\n')

for f in FILES:
    path=f.relative_to(BASE).as_posix()
    add('file/'+path,['isa = PBXFileReference;','lastKnownFileType = sourcecode.swift;',f'path = {quote(f.name)};','sourceTree = "<group>";'],f.name)
    add('build/'+path,['isa = PBXBuildFile;',f'fileRef = {ref("file/"+path)};'],f.name+' in Sources')
for fn,kind in [('Assets.xcassets','folder.assetcatalog'),('Sources/App/Info.plist','text.plist.xml')]:
    add('file/'+fn,['isa = PBXFileReference;',f'lastKnownFileType = {kind};',f'path = {quote(Path(fn).name)};','sourceTree = "<group>";'],Path(fn).name)
add('build/assets',['isa = PBXBuildFile;',f'fileRef = {ref("file/Assets.xcassets")};'],'Assets in Resources')
add('product',['isa = PBXFileReference;','explicitFileType = wrapper.application;','includeInIndex = 0;',f'path = {NAME}.app;','sourceTree = BUILT_PRODUCTS_DIR;'],NAME+'.app')
for folder in ['App','Core']:
    child=[f for f in FILES if f.parent.name == folder]
    if folder=='App': child_extra=[ref('file/Sources/App/Info.plist')]
    else: child_extra=[]
    add('group/'+folder,['isa = PBXGroup;','children = (']+[f'\t{ref("file/"+f.relative_to(BASE).as_posix())},' for f in child]+[f'\t{r},' for r in child_extra]+[');',f'path = {quote(folder)};','sourceTree = "<group>";'],folder)
add('group/Sources',['isa = PBXGroup;','children = (',f'\t{ref("group/App")},',f'\t{ref("group/Core")},',');','path = Sources;','sourceTree = "<group>";'],'Sources')
add('group/root',['isa = PBXGroup;','children = (',f'\t{ref("group/Sources")},',f'\t{ref("group/tests")},',f'\t{ref("file/Assets.xcassets")},',f'\t{ref("group/products")},',');','sourceTree = "<group>";'],'Root')
add('group/products',['isa = PBXGroup;','children = (',f'\t{ref("product")},',f'\t{ref("product/tests")},',');','name = Products;','sourceTree = "<group>";'],'Products')
add('phase/sources',['isa = PBXSourcesBuildPhase;','buildActionMask = 2147483647;','files = (']+[f'\t{ref("build/"+f.relative_to(BASE).as_posix())},' for f in FILES]+[');','runOnlyForDeploymentPostprocessing = 0;'],'Sources')
add('phase/resources',['isa = PBXResourcesBuildPhase;','buildActionMask = 2147483647;','files = (',f'\t{ref("build/assets")},',');','runOnlyForDeploymentPostprocessing = 0;'],'Resources')
add('phase/frameworks',['isa = PBXFrameworksBuildPhase;','buildActionMask = 2147483647;','files = ();','runOnlyForDeploymentPostprocessing = 0;'],'Frameworks')
for mode in ['Debug','Release']:
    add('config/project/'+mode,['isa = XCBuildConfiguration;','buildSettings = {',
        '\tALWAYS_SEARCH_USER_PATHS = NO;','\tCLANG_ENABLE_MODULES = YES;','\tCLANG_ENABLE_OBJC_ARC = YES;',
        '\tSDKROOT = iphoneos;','\tSWIFT_VERSION = 5.0;','\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;',
        '\tTARGETED_DEVICE_FAMILY = "1,2";','\tENABLE_USER_SCRIPT_SANDBOXING = YES;',
        '\tSWIFT_OPTIMIZATION_LEVEL = '+quote('-Onone' if mode=='Debug' else '-O')+';',
        '\tENABLE_TESTABILITY = '+('YES' if mode=='Debug' else 'NO')+';',
        '\tDEBUG_INFORMATION_FORMAT = dwarf-with-dsym;','};',f'name = {mode};'],'Project '+mode)
    add('config/app/'+mode,['isa = XCBuildConfiguration;','buildSettings = {',
        '\tPRODUCT_NAME = "$(TARGET_NAME)";','\tPRODUCT_BUNDLE_IDENTIFIER = '+json.loads((BASE/'Config/project.json').read_text())['bundleIdentifier']+';',
        '\tGENERATE_INFOPLIST_FILE = NO;','\tINFOPLIST_FILE = Sources/App/Info.plist;',
        '\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;','\tSWIFT_VERSION = 5.0;',
        '\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;','\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";',
        '\tTARGETED_DEVICE_FAMILY = "1,2";',
        '\tMARKETING_VERSION = '+VERSION['version']+';',
        '\tCURRENT_PROJECT_VERSION = '+str(VERSION['build'])+';',
        '\tCODE_SIGN_STYLE = Automatic;',
        '\tOTHER_LDFLAGS = ("$(inherited)", "-lsqlite3");',
        '\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = '+quote('DEBUG' if mode=='Debug' else '')+';',
        '};',f'name = {mode};'],'App '+mode)
for ty in ['project','app']:
    add('configs/'+ty,['isa = XCConfigurationList;','buildConfigurations = (',f'\t{ref("config/"+ty+"/Debug")},',f'\t{ref("config/"+ty+"/Release")},',');','defaultConfigurationIsVisible = 0;','defaultConfigurationName = Release;'],ty+' configs')
add('target',['isa = PBXNativeTarget;',f'buildConfigurationList = {ref("configs/app")};',
   'buildPhases = (',f'\t{ref("phase/sources")},',f'\t{ref("phase/frameworks")},',f'\t{ref("phase/resources")},',');',
   'buildRules = ();','dependencies = ();',f'name = {NAME};',f'productReference = {ref("product")};',f'productName = {NAME};',
   'productType = "com.apple.product-type.application";'],NAME)
for f in TEST_FILES:
    path = f.relative_to(BASE).as_posix()
    add('file/'+path,['isa = PBXFileReference;','lastKnownFileType = sourcecode.swift;',f'path = {quote(f.name)};','sourceTree = "<group>";'],f.name)
    add('build/'+path,['isa = PBXBuildFile;',f'fileRef = {ref("file/"+path)};'],f.name+' in Sources')
add('group/tests',['isa = PBXGroup;','children = (']+[f'\t{ref("file/"+f.relative_to(BASE).as_posix())},' for f in TEST_FILES]+[');','path = Tests/App;','sourceTree = "<group>";'],'App tests')
add('product/tests',['isa = PBXFileReference;','explicitFileType = wrapper.cfbundle;','includeInIndex = 0;',f'path = {NAME}AppTests.xctest;','sourceTree = BUILT_PRODUCTS_DIR;'],'App tests')
add('phase/tests',['isa = PBXSourcesBuildPhase;','buildActionMask = 2147483647;','files = (']+[f'\t{ref("build/"+f.relative_to(BASE).as_posix())},' for f in TEST_FILES]+[');','runOnlyForDeploymentPostprocessing = 0;'],'App test sources')
for mode in ['Debug','Release']:
    add('config/tests/'+mode,['isa = XCBuildConfiguration;','buildSettings = {',
        f'\tPRODUCT_NAME = {NAME}AppTests;',
        f'\tPRODUCT_BUNDLE_IDENTIFIER = {json.loads((BASE/"Config/project.json").read_text())["bundleIdentifier"]}.tests;',
        '\tGENERATE_INFOPLIST_FILE = YES;','\tSWIFT_VERSION = 5.0;',
        '\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;',
        '\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";',
        '\tTARGETED_DEVICE_FAMILY = "1,2";',
        f'\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/{NAME}.app/{NAME}";',
        '\tBUNDLE_LOADER = "$(TEST_HOST)";',
        '};',f'name = {mode};'],'App tests '+mode)
add('configs/tests',['isa = XCConfigurationList;','buildConfigurations = (',f'\t{ref("config/tests/Debug")},',f'\t{ref("config/tests/Release")},',');','defaultConfigurationIsVisible = 0;','defaultConfigurationName = Debug;'],'App test configs')
add('proxy/app',['isa = PBXContainerItemProxy;',f'containerPortal = {ref("project")};','proxyType = 1;',f'remoteGlobalIDString = {oid("target")};',f'remoteInfo = {NAME};'],'Test host proxy')
add('dependency/app',['isa = PBXTargetDependency;',f'target = {ref("target")};',f'targetProxy = {ref("proxy/app")};'],'Test host')
add('target/tests',['isa = PBXNativeTarget;',f'buildConfigurationList = {ref("configs/tests")};','buildPhases = (',f'\t{ref("phase/tests")},',');','buildRules = ();','dependencies = (',f'\t{ref("dependency/app")},',');',f'name = {NAME}AppTests;',f'productName = {NAME}AppTests;',f'productReference = {ref("product/tests")};','productType = "com.apple.product-type.bundle.unit-test";'],'App tests')
add('project',['isa = PBXProject;',f'buildConfigurationList = {ref("configs/project")};',
   'compatibilityVersion = "Xcode 14.0";','developmentRegion = ru;','hasScannedForEncodings = 0;',
   'knownRegions = (ru, en, Base);',f'mainGroup = {ref("group/root")};',f'productRefGroup = {ref("group/products")};',
   'projectDirPath = "";','projectRoot = "";','targets = (',f'\t{ref("target")},',f'\t{ref("target/tests")},',');',
   'attributes = {','\tBuildIndependentTargetsInParallel = YES;',
   f'\tTargetAttributes = {{ {oid("target")} = {{ CreatedOnToolsVersion = 16.0; }}; }};','};'],'Project')
proj='// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n'
proj+=''.join(objects)+'\t};\n'+f'\trootObject = {ref("project")};\n'+'}\n'
out=BASE/(NAME+'.xcodeproj')/'project.pbxproj'
out.parent.mkdir(exist_ok=True)
out.write_text(proj, newline='\n')
scheme = BASE/(NAME+'.xcodeproj')/'xcshareddata/xcschemes'/(NAME+'.xcscheme')
import re
text = scheme.read_text()
test_action = f'''<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
  <Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid('target/tests')}" BuildableName="{NAME}AppTests.xctest" BlueprintName="{NAME}AppTests" ReferencedContainer="container:{NAME}.xcodeproj"/></TestableReference></Testables>
 </TestAction>'''
text = re.sub(r'<TestAction\b[^>]*(?:/>|>.*?</TestAction>)', lambda _: test_action, text, flags=re.S)
scheme.write_text(text, newline='\n')
print(f'Generated {out} with {len(FILES)} Swift files: v{VERSION["version"]} ({VERSION["build"]})')
