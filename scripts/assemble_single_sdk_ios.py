#!/usr/bin/env python3
"""Build one iOS CocoaPods plugin by bundling existing Swift bridges."""

import json
import re
import shutil
from pathlib import Path

from audit_single_pub_package import ROOT, plugin_entrypoints

OUT = ROOT / "build" / "single_sdk_candidate"


def ivs_frameworks(root: Path = ROOT) -> list[dict[str, str]]:
    """Keep official URLs and hashes identical to the source plugins' SwiftPM pins."""
    frameworks = []
    for module in ("flutter_realtime_media_ivs", "flutter_realtime_chat_ivs"):
        manifest = root / "packages" / module / "ios" / module / "Package.swift"
        binary = re.search(
            r'\.binaryTarget\(\s*name:\s*"([^"]+)",\s*'
            r'url:\s*"(https://[^"]+)",\s*checksum:\s*"([0-9a-f]{64})"',
            manifest.read_text(),
        )
        if not binary:
            raise ValueError(f"Missing pinned official IVS binary: {manifest}")
        name, url, checksum = binary.groups()
        frameworks.append({"name": name, "url": url, "sha256": checksum})
    return frameworks


def run() -> dict:
    pubspec = OUT / "pubspec.yaml"
    if not pubspec.exists():
        raise ValueError("Run assemble_single_sdk_candidate.py first")
    names = json.loads((ROOT / "scripts" / "sdk_packages.json").read_text())
    native = [
        (n, plugin_entrypoints((ROOT / "packages" / n / "pubspec.yaml").read_text())["ios"]["pluginClass"])
        for n in names
        if "ios" in plugin_entrypoints((ROOT / "packages" / n / "pubspec.yaml").read_text())
    ]
    classes = OUT / "ios" / "Classes"
    resources = OUT / "ios" / "Resources"
    for folder in (classes, resources):
        if folder.exists():
            shutil.rmtree(folder)
    files = 0
    dependencies = {"Flutter": None}
    for name, classname in native:
        original = ROOT / "packages" / name / "ios"
        podspec = next(original.glob("*.podspec"), None)
        if podspec:
            for module, constraint in re.findall(
                r"s\.dependency\s+['\"]([^'\"]+)['\"](?:\s*,\s*['\"]([^'\"]+)['\"])?",
                podspec.read_text(),
            ):
                # Internal source modules are folded into the single public
                # plugin. They are not separately available on CocoaPods.
                if module not in names:
                    dependencies[module] = constraint or None
        for item in original.rglob("*"):
            if not item.is_file() or item.name == "Package.swift":
                continue
            relative = item.relative_to(original)
            if item.suffix in (".swift", ".m", ".mm", ".h", ".c", ".cc", ".cpp"):
                if "test" in relative.parts:
                    continue
                target = classes / name / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                if item.suffix == ".swift":
                    source = item.read_text()
                    # The frame hub's Swift types live in this same module
                    # after aggregation, not in a separate dependency.
                    source = source.replace(
                        "import flutter_realtime_processed_video\n", ""
                    )
                    target.write_text(source)
                else:
                    shutil.copy2(item, target)
                files += 1
            elif item.suffix in (".xcprivacy", ".png", ".jpg", ".jpeg", ".json"):
                target = resources / name / item.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item, target)
    # IVS has no matching published Pods. Fetch its pinned official archives
    # during pod installation; no vendor binary is included in the Pub archive.
    frameworks = ivs_frameworks()
    (OUT / "ios" / "vendor_frameworks.json").write_text(
        json.dumps({"frameworks": frameworks}, indent=2) + "\n"
    )
    shutil.copy2(
        ROOT / "scripts/templates/single_sdk_ios_vendor_frameworks.rb",
        OUT / "ios" / "vendor_frameworks.rb",
    )
    shutil.copy2(
        ROOT / "scripts/templates/single_sdk_ios_podfile.rb",
        OUT / "ios" / "podfile.rb",
    )
    # Ship the host-side ReplayKit Broadcast Upload Extension source and
    # idempotent Xcode project installer with the published single SDK.
    # These are templates, NOT an extra CocoaPods target: Apple requires the
    # consuming application's signing team and App Group entitlements.
    extension_template = OUT / "ios" / "BroadcastExtensionTemplate"
    if extension_template.exists():
        shutil.rmtree(extension_template)
    shutil.copytree(
        ROOT / "scripts/templates/ios_broadcast_extension",
        extension_template,
    )
    tools = OUT / "tool"
    tools.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "scripts/setup_ios_broadcast_extension.rb", tools / "setup_ios_broadcast_extension.rb")
    # Swift must not reference the plugin class of a CocoaPods-excluded vendor.
    # Unlike renaming vendor RTC* Objective-C classes, this isolates the whole
    # official framework, so a LiveKit-based host can omit conflicting binaries.
    optional_flags = {
        "flutter_aws_chime": "FRSDK_DISABLE_CHIME",
        "flutter_realtime_media_artc": "FRSDK_DISABLE_ARTC",
    }
    registrations = "\n".join(
        (
            f"    #if !{optional_flags[name]}\n"
            f"    {classname}.register(with: registrar)\n"
            "    #endif"
        ) if name in optional_flags
        else f"    {classname}.register(with: registrar)"
        for name, classname in native
    )
    classes.mkdir(parents=True, exist_ok=True)
    (classes / "FlutterRealtimeSdkPlugin.swift").write_text(
        "import Flutter\nimport Foundation\n\n"
        "public final class FlutterRealtimeSdkPlugin: NSObject, FlutterPlugin {\n"
        "  public static func register(with registrar: FlutterPluginRegistrar) {\n"
        f"{registrations}\n"
        "  }\n}\n"
    )
    pod_lines = []
    for module, constraint in sorted(dependencies.items()):
        condition = (
            " unless disable_chime" if module.startswith("AmazonChimeSDK")
            else " unless disable_artc" if module == "AliVCSDK_ARTC"
            else ""
        )
        if constraint:
            pod_lines.append(f"  s.dependency '{module}', '{constraint}'{condition}")
        else:
            pod_lines.append(f"  s.dependency '{module}'{condition}")
    spec = """require_relative 'vendor_frameworks'
FlutterRealtimeSdk::VendorFrameworks.install!(__dir__)

# Set these in the consuming application's ios/Podfile BEFORE
# flutter_install_all_ios_pods, rather than patching or stripping vendor
# binaries at build time. These flags must match across all build configs.
disable_chime = ENV['FRSDK_IOS_DISABLE_CHIME'] == '1'
disable_artc = ENV['FRSDK_IOS_DISABLE_ARTC'] == '1'

Pod::Spec.new do |s|
  s.name = 'flutter_realtime_sdk'
  s.version = '0.1.0'
  s.summary = 'Realtime media, chat and classroom SDK'
  s.description = s.summary
  s.homepage = 'https://github.com/lengsukq/multi-video'
  s.license = { :file => '../LICENSE' }
  s.author = { 'OnePlusDream' => 'developers@oneplusdream.com' }
  s.source = { :path => '.' }
  # All provider bridges are compiled into the same CocoaPods module.
  # Their private C++/Objective-C headers must remain alongside each .mm/.m
  # file for quoted imports, but MUST NOT be copied into the framework's
  # public Headers folder or imported by its generated Swift umbrella header.
  # In particular AgoraBase.h imports <cassert>, which Swift's Clang module
  # scanner cannot parse as an Objective-C umbrella declaration.
  s.source_files = 'Classes/**/*.{swift,m,mm,c,cc,cpp}', 'Classes/**/include/**/*.h', 'Classes/**/FlutterRealtimeMediaLivekitPlugin.h'
  s.public_header_files = 'Classes/**/include/**/*.h', 'Classes/**/FlutterRealtimeMediaLivekitPlugin.h'
  excluded_sources = []
  excluded_sources << 'Classes/flutter_aws_chime/**/*' if disable_chime
  excluded_sources << 'Classes/flutter_realtime_media_artc/**/*' if disable_artc
  s.exclude_files = excluded_sources
  s.resources = 'Resources/**/*'
  s.platform = :ios, '15.0'
  s.swift_version = '5.9'
  s.static_framework = true
  s.vendored_frameworks = 'Frameworks/*.xcframework'
  s.preserve_paths = 'vendor_frameworks.rb', 'vendor_frameworks.json', 'podfile.rb'
  conditions = ['$(inherited)']
  conditions << 'FRSDK_DISABLE_CHIME' if disable_chime
  conditions << 'FRSDK_DISABLE_ARTC' if disable_artc
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => conditions.join(' '),
  }
""" + "\n".join(pod_lines) + "\nend\n"
    (OUT / "ios" / "flutter_realtime_sdk.podspec").write_text(spec)
    content = pubspec.read_text()
    marker = "  plugin:\n    platforms:\n"
    if marker not in content:
        raise ValueError("Assemble Android/macOS plugin metadata first")
    if "      ios:\n        pluginClass: FlutterRealtimeSdkPlugin" not in content:
        content = content.replace(marker, marker + "      ios:\n        pluginClass: FlutterRealtimeSdkPlugin\n", 1)
        pubspec.write_text(content)
    return {"platform": "ios", "registrations": len(native), "sourceFiles": files,
            "podDependencies": sorted(dependencies),
            "officialBinaryDependencies": frameworks,
            "warning": "Requires iOS device-target build; ARTC does not support the simulator"}


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
