#!/usr/bin/env python3
"""Generate a minimal multiplatform (iOS + macOS) Xcode project for ServerStatus."""

from __future__ import annotations

import os
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCES = sorted((ROOT / "Sources" / "ServerStatus").rglob("*.swift"))
PROJ = ROOT / "ServerStatus.xcodeproj"


def xid() -> str:
    return uuid.uuid4().hex[:24].upper()


# Stable-ish IDs for incremental friendliness
IDS = {
    "project": "A10000000000000000000001",
    "target": "A10000000000000000000002",
    "sources_phase": "A10000000000000000000003",
    "frameworks_phase": "A10000000000000000000004",
    "resources_phase": "A10000000000000000000005",
    "product_ref": "A10000000000000000000006",
    "product_group": "A10000000000000000000007",
    "main_group": "A10000000000000000000008",
    "src_group": "A10000000000000000000009",
    "pkg_citadel": "A1000000000000000000000A",
    "pkg_product": "A1000000000000000000000B",
    "config_list_project": "A1000000000000000000000C",
    "config_list_target": "A1000000000000000000000D",
    "debug_project": "A1000000000000000000000E",
    "release_project": "A1000000000000000000000F",
    "debug_target": "A10000000000000000000010",
    "release_target": "A10000000000000000000011",
}

file_entries: list[tuple[str, str, Path]] = []
for path in SOURCES:
    fid = xid()
    build_id = xid()
    rel = path.relative_to(ROOT).as_posix()
    file_entries.append((fid, build_id, path.relative_to(ROOT)))


def pbx_files() -> str:
    lines = []
    for fid, _, rel in file_entries:
        name = rel.name
        lines.append(
            f"\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{rel.as_posix()}\"; sourceTree = \"<group>\"; }};"
        )
    lines.append(
        f"\t\t{IDS['product_ref']} /* ServerStatus.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ServerStatus.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    return "\n".join(lines)


def pbx_build_files() -> str:
    lines = []
    for fid, bid, rel in file_entries:
        lines.append(
            f"\t\t{bid} /* {rel.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {rel.name} */; }};"
        )
    lines.append(
        f"\t\t{xid()} /* Citadel in Frameworks */ = {{isa = PBXBuildFile; productRef = {IDS['pkg_product']} /* Citadel */; }};"
    )
    # Keep framework build file id stable - regenerate carefully
    return "\n".join(lines)


# Fix frameworks build file to stable id
FW_BUILD = "A10000000000000000000020"


def generate() -> None:
    build_file_lines = []
    source_build_ids = []
    for fid, bid, rel in file_entries:
        build_file_lines.append(
            f"\t\t{bid} /* {rel.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {rel.name} */; }};"
        )
        source_build_ids.append(f"\t\t\t\t{bid} /* {rel.name} in Sources */,")
    build_file_lines.append(
        f"\t\t{FW_BUILD} /* Citadel in Frameworks */ = {{isa = PBXBuildFile; productRef = {IDS['pkg_product']} /* Citadel */; }};"
    )

    file_ref_lines = []
    group_children = []
    for fid, _, rel in file_entries:
        # Use just filename in group but path relative for file ref with name
        # Simpler: put all in one group with full relative path from Sources
        name = rel.name
        # path relative to group Sources/ServerStatus
        sub = rel.as_posix().removeprefix("Sources/ServerStatus/")
        file_ref_lines.append(
            f"\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{Path(sub).as_posix()}\"; sourceTree = \"<group>\"; }};"
        )
        group_children.append(f"\t\t\t\t{fid} /* {name} */,")

    # Nested groups by folder for clarity - flat is ok for Xcode
    content = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_file_lines)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_ref_lines)}
		{IDS['product_ref']} /* ServerStatus.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ServerStatus.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{IDS['frameworks_phase']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{FW_BUILD} /* Citadel in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{IDS['main_group']} = {{
			isa = PBXGroup;
			children = (
				{IDS['src_group']} /* ServerStatus */,
				{IDS['product_group']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{IDS['src_group']} /* ServerStatus */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(group_children)}
			);
			name = ServerStatus;
			path = Sources/ServerStatus;
			sourceTree = "<group>";
		}};
		{IDS['product_group']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{IDS['product_ref']} /* ServerStatus.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{IDS['target']} /* ServerStatus */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {IDS['config_list_target']} /* Build configuration list for PBXNativeTarget "ServerStatus" */;
			buildPhases = (
				{IDS['sources_phase']} /* Sources */,
				{IDS['frameworks_phase']} /* Frameworks */,
				{IDS['resources_phase']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = ServerStatus;
			packageProductDependencies = (
				{IDS['pkg_product']} /* Citadel */,
			);
			productName = ServerStatus;
			productReference = {IDS['product_ref']} /* ServerStatus.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{IDS['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{IDS['target']} = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = {IDS['config_list_project']} /* Build configuration list for PBXProject "ServerStatus" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {IDS['main_group']};
			packageReferences = (
				{IDS['pkg_citadel']} /* XCRemoteSwiftPackageReference "Citadel" */,
			);
			productRefGroup = {IDS['product_group']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{IDS['target']} /* ServerStatus */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{IDS['resources_phase']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{IDS['sources_phase']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(source_build_ids)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{IDS['debug_project']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{IDS['release_project']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 5.0;
			}};
			name = Release;
		}};
		{IDS['debug_target']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = ServerStatus;
				INFOPLIST_KEY_NSLocalNetworkUsageDescription = "用于通过 SSH 连接局域网中的 Ubuntu 服务器";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.eppen.ServerStatus;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
			}};
			name = Debug;
		}};
		{IDS['release_target']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = ServerStatus;
				INFOPLIST_KEY_NSLocalNetworkUsageDescription = "用于通过 SSH 连接局域网中的 Ubuntu 服务器";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.eppen.ServerStatus;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{IDS['config_list_project']} /* Build configuration list for PBXProject "ServerStatus" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDS['debug_project']} /* Debug */,
				{IDS['release_project']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{IDS['config_list_target']} /* Build configuration list for PBXNativeTarget "ServerStatus" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDS['debug_target']} /* Debug */,
				{IDS['release_target']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCRemoteSwiftPackageReference section */
		{IDS['pkg_citadel']} /* XCRemoteSwiftPackageReference "Citadel" */ = {{
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/eppen/Citadel.git";
			requirement = {{
				kind = upToNextMajorVersion;
				minimumVersion = 0.11.0;
			}};
		}};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{IDS['pkg_product']} /* Citadel */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {IDS['pkg_citadel']} /* XCRemoteSwiftPackageReference "Citadel" */;
			productName = Citadel;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {IDS['project']} /* Project object */;
}}
"""

    PROJ.mkdir(parents=True, exist_ok=True)
    (PROJ / "project.pbxproj").write_text(content)
    ws = PROJ / "project.xcworkspace"
    ws.mkdir(exist_ok=True)
    (ws / "contents.xcworkspacedata").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""
    )
    scheme_dir = PROJ / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / "ServerStatus.xcscheme").write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{IDS['target']}"
               BuildableName = "ServerStatus.app"
               BlueprintName = "ServerStatus"
               ReferencedContainer = "container:ServerStatus.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDS['target']}"
            BuildableName = "ServerStatus.app"
            BlueprintName = "ServerStatus"
            ReferencedContainer = "container:ServerStatus.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
"""
    )
    print(f"Generated {PROJ} with {len(file_entries)} sources")


if __name__ == "__main__":
    generate()
