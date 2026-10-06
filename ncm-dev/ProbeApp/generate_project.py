#!/usr/bin/env python3
"""Deterministic project, no third-party generator, packages, signing or install."""
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parent
objects = {}
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(name, value): objects[ident(name)] = value; return ident(name)
def seq(items): return '(' + ','.join(items) + ',)'
# Resolve glob relative to script, independent of caller cwd.
sources = [Path('NCMProbeApp.swift'), Path('../../ios-app/PhoneAgent/ESP32Control/PairingFlow.swift'), Path('../../ios-app/PhoneAgent/ESP32Control/ESP32ControlSettingsView.swift')] + [Path('../PhoneAgentNCM/Sources/PhoneAgentNCM') / p.name for p in sorted((root / '../PhoneAgentNCM/Sources/PhoneAgentNCM').glob('*.swift'))]
files, builds = [], []
for p in sources:
    ref = add(str(p), '{isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path="'+str(p)+'"; sourceTree="<group>";}')
    files.append(ref)
    builds.append(add('build'+str(p), '{isa=PBXBuildFile; fileRef='+ref+';}'))
product = add('product','{isa=PBXFileReference; explicitFileType=wrapper.application; path=NCMProbe.app; sourceTree=BUILT_PRODUCTS_DIR;}')
group = add('group','{isa=PBXGroup; children='+seq(files+[product])+'; sourceTree="<group>";}')
phase = add('sourcePhase','{isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files='+seq(builds)+'; runOnlyForDeploymentPostprocessing=0;}')
frameworks = add('frameworks','{isa=PBXFrameworksBuildPhase; buildActionMask=2147483647; files=(); runOnlyForDeploymentPostprocessing=0;}')
settings = '''ALWAYS_SEARCH_USER_PATHS=NO; ARCHS=arm64; HEADER_SEARCH_PATHS="$(SRCROOT)/../PhoneAgentNCM/Sources/CNCMBackend/include"; OTHER_LDFLAGS="-lphoneagent_ncm_backend -framework Security -framework SystemConfiguration"; "LIBRARY_SEARCH_PATHS[sdk=iphoneos*]"="$(SRCROOT)/../../.build/ncm-rust/aarch64-apple-ios/release"; "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]"="$(SRCROOT)/../../.build/ncm-rust/aarch64-apple-ios-sim/release"; PRODUCT_NAME=NCMProbe; PRODUCT_BUNDLE_IDENTIFIER="com.ja1chen.PhoneAgent.NCMProbe"; SDKROOT=iphoneos; IPHONEOS_DEPLOYMENT_TARGET=17.0; SWIFT_VERSION=5.0; TARGETED_DEVICE_FAMILY="1,2"; GENERATE_INFOPLIST_FILE=NO; INFOPLIST_FILE="Info.plist"; CURRENT_PROJECT_VERSION=1; MARKETING_VERSION=0.1; INFOPLIST_KEY_CFBundleDisplayName="NCM Probe"; INFOPLIST_KEY_NSLocalNetworkUsageDescription="通过直连 USB 网络检查 S3 与本机开发者服务的可达性。"; INFOPLIST_KEY_UILaunchScreen_Generation=YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation=YES; CODE_SIGNING_ALLOWED=NO; CODE_SIGN_STYLE=Automatic; CURRENT_PROJECT_VERSION=1; MARKETING_VERSION=0.1; SWIFT_EMIT_LOC_STRINGS=NO;'''
configs=[]
for name in ('Debug','Release'):
    configs.append(add('config'+name,'{isa=XCBuildConfiguration; name='+name+'; buildSettings={'+settings+' SWIFT_OPTIMIZATION_LEVEL="'+('-Onone' if name=='Debug' else '-O')+'";};}'))
cl=add('configlist','{isa=XCConfigurationList; buildConfigurations='+seq(configs)+'; defaultConfigurationIsVisible=0; defaultConfigurationName=Debug;}')
target=add('target','{isa=PBXNativeTarget; name=NCMProbe; productName=NCMProbe; productType="com.apple.product-type.application"; productReference='+product+'; buildConfigurationList='+cl+'; buildPhases='+seq([phase,frameworks])+'; buildRules=(); dependencies=();}')
project=add('project','{isa=PBXProject; attributes={LastUpgradeCheck=2700;}; buildConfigurationList='+cl+'; compatibilityVersion="Xcode 14.0"; developmentRegion=en; knownRegions=(en,Base,); mainGroup='+group+'; projectDirPath=""; projectRoot=""; targets='+seq([target])+';}')
dest=root/'NCMProbe.xcodeproj'; dest.mkdir(exist_ok=True)
(dest/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion=1; classes={}; objectVersion=56; objects={\n'+'\n'.join(k+'='+v+';' for k,v in objects.items())+'\n}; rootObject='+project+';}\n')
