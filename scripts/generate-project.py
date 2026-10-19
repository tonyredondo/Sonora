#!/usr/bin/env python3
"""Regenerate the Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def oid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def add(identity, isa, **values):
    key = oid(identity)
    objects[key] = dict(isa=isa, **values)
    return key

app = oid('app')
tests = oid('tests')
ui_tests = oid('ui-tests')
app_product = add('app-product', 'PBXFileReference', explicitFileType='wrapper.application', path='Sonora.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = add('test-product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='SonoraTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
ui_product = add('ui-product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='SonoraUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
exception = add('app-exception', 'PBXFileSystemSynchronizedBuildFileExceptionSet', membershipExceptions=['Info.plist', 'CarPlay.entitlements'], target=app)
app_group = add('app-group', 'PBXFileSystemSynchronizedRootGroup', exceptions=[exception], path='Sonora', sourceTree='<group>')
test_group = add('test-group', 'PBXFileSystemSynchronizedRootGroup', path='SonoraTests', sourceTree='<group>')
ui_group = add('ui-group', 'PBXFileSystemSynchronizedRootGroup', path='SonoraUITests', sourceTree='<group>')
products = add('products', 'PBXGroup', children=[app_product, test_product, ui_product], name='Products', sourceTree='<group>')
main = add('main-group', 'PBXGroup', children=[app_group, test_group, ui_group, products], sourceTree='<group>')
sfb = add('sfb-package', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/sbooth/SFBAudioEngine', requirement={'kind':'exactVersion','version':'0.14.0'})
core = add('core-package', 'XCLocalSwiftPackageReference', relativePath='Packages/SonoraCore')
taglib = add('taglib-package', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/sbooth/CXXTagLib', requirement={'kind':'exactVersion','version':'2.3.2'})
chroma = add('chromaprint-package', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/wallisch/ChromaSwift', requirement={'kind':'revision','revision':'900b29aff4129541c19e5e2b91f9cd4068afd19d'})
deps = [add('sfb-product', 'XCSwiftPackageProductDependency', package=sfb, productName='SFBAudioEngine'), add('core-product', 'XCSwiftPackageProductDependency', package=core, productName='SonoraCore'), add('taglib-product', 'XCSwiftPackageProductDependency', package=taglib, productName='taglib'), add('chromaprint-product', 'XCSwiftPackageProductDependency', package=chroma, productName='ChromaSwift')]
frameworks = [add('link-'+d, 'PBXBuildFile', productRef=d) for d in deps]
configs = {}
for mode in ['Debug','Release']:
    settings = dict(DEVELOPMENT_TEAM='HNF8XS7V57', IPHONEOS_DEPLOYMENT_TARGET='17.0', SDKROOT='iphoneos', CLANG_ENABLE_MODULES='YES', SWIFT_VERSION='5.0', SWIFT_STRICT_CONCURRENCY='complete', DEBUG_INFORMATION_FORMAT='dwarf' if mode=='Debug' else 'dwarf-with-dsym')
    if mode=='Debug': settings.update(SWIFT_OPTIMIZATION_LEVEL='-Onone', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', ENABLE_TESTABILITY='YES', ONLY_ACTIVE_ARCH='YES')
    else: settings.update(SWIFT_COMPILATION_MODE='wholemodule')
    configs[mode] = add('project-'+mode, 'XCBuildConfiguration', name=mode, buildSettings=settings)
project_configs = add('project-configs', 'XCConfigurationList', buildConfigurations=list(configs.values()), defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

def target_config(name, identifier, extra):
    refs=[]
    for mode in ['Debug','Release']:
        settings=dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER=identifier, TARGETED_DEVICE_FAMILY='1', CODE_SIGN_STYLE='Automatic', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', GENERATE_INFOPLIST_FILE='NO', CURRENT_PROJECT_VERSION='1', MARKETING_VERSION='0.1.0')
        settings.update(extra)
        if name=='app':
            settings.update(SWIFT_OBJC_BRIDGING_HEADER='Sonora/Sonora-Bridging-Header.h', CLANG_CXX_LANGUAGE_STANDARD='c++17')
            # Pin the explicit App ID profile; automatic signing can select the
            # team's wildcard profile while CarPlay approval is pending.
            settings['CODE_SIGN_STYLE[sdk=iphoneos*]']='Manual'
            settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]']='Apple Development'
            settings['PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]']='Sonora Development'
            # Simulator can use an ad-hoc CarPlay entitlement. Device builds keep
            # ordinary signing until Apple grants CarPlay for this App ID; pass
            # CODE_SIGN_ENTITLEMENTS=Sonora/CarPlay.entitlements after approval.
            settings['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]']='Sonora/CarPlay.entitlements'
        refs.append(add(name+'-'+mode, 'XCBuildConfiguration', name=mode, buildSettings=settings))
    return add(name+'-configs', 'XCConfigurationList', buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

app_phases=[add('app-sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0),add('app-frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=frameworks,runOnlyForDeploymentPostprocessing=0),add('app-resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)]
test_phases=[add('test-sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0),add('test-frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0),add('test-resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)]
proxy=add('test-proxy','PBXContainerItemProxy',containerPortal=oid('project'),proxyType=1,remoteGlobalIDString=app,remoteInfo='Sonora')
dependency=add('test-dependency','PBXTargetDependency',target=app,targetProxy=proxy)
add('app','PBXNativeTarget',name='Sonora',productName='Sonora',productType='com.apple.product-type.application',productReference=app_product,buildConfigurationList=target_config('app','com.tonyredondo.Sonora',dict(INFOPLIST_FILE='Sonora/Info.plist',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon')),buildPhases=app_phases,buildRules=[],dependencies=[],packageProductDependencies=deps,fileSystemSynchronizedGroups=[app_group])
add('tests','PBXNativeTarget',name='SonoraTests',productName='SonoraTests',productType='com.apple.product-type.bundle.unit-test',productReference=test_product,buildConfigurationList=target_config('tests','com.tonyredondo.SonoraTests',dict(GENERATE_INFOPLIST_FILE='YES',TEST_HOST='$(BUILT_PRODUCTS_DIR)/Sonora.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Sonora',BUNDLE_LOADER='$(TEST_HOST)',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks @loader_path/Frameworks')),buildPhases=test_phases,buildRules=[],dependencies=[dependency],fileSystemSynchronizedGroups=[test_group])
ui_phases=[add('ui-sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0),add('ui-frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)]
add('ui-tests','PBXNativeTarget',name='SonoraUITests',productName='SonoraUITests',productType='com.apple.product-type.bundle.ui-testing',productReference=ui_product,buildConfigurationList=target_config('ui-tests','com.tonyredondo.SonoraUITests',dict(GENERATE_INFOPLIST_FILE='YES',TEST_TARGET_NAME='Sonora',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks @loader_path/Frameworks')),buildPhases=ui_phases,buildRules=[],dependencies=[dependency],fileSystemSynchronizedGroups=[ui_group])
add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2700','TargetAttributes':{tests:{'TestTargetID':app},ui_tests:{'TestTargetID':app}}},buildConfigurationList=project_configs,compatibilityVersion='Xcode 16.0',developmentRegion='es',knownRegions=['es','en','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app,tests,ui_tests],packageReferences=[sfb,core,taglib,chroma],preferredProjectObjectVersion=77)

def plist(value, depth=0):
    if isinstance(value,dict): return '{\n'+''.join('\t'*(depth+1)+json.dumps(str(k))+' = '+plist(v,depth+1)+';\n' for k,v in value.items())+'\t'*depth+'}'
    if isinstance(value,list): return '('+', '.join(plist(v,depth) for v in value)+')'
    return str(value) if isinstance(value,int) else json.dumps(value)

project=ROOT/'Sonora.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+plist(dict(archiveVersion=1,classes={},objectVersion=77,objects=objects,rootObject=oid('project')))+'\n')
scheme_dir=project/'xcshareddata'/'xcschemes'
scheme_dir.mkdir(parents=True,exist_ok=True)
ref=lambda target,name:f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Sonora.xcodeproj"/>'
(scheme_dir/'Sonora.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app,'Sonora.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(tests,'SonoraTests.xctest')}</TestableReference><TestableReference skipped="NO">{ref(ui_tests,'SonoraUITests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'Sonora.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'Sonora.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
