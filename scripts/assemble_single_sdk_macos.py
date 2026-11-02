#!/usr/bin/env python3
"""Assemble macOS source/plugins into a single Flutter plugin candidate.

Native merging is deliberately isolated under build/single_sdk_candidate and
does not alter the monorepo. Run the Dart assembler first.
"""

import json
import re
import shutil
from collections import Counter
from pathlib import Path

from audit_single_pub_package import ROOT, plugin_entrypoints

OUT = ROOT / "build" / "single_sdk_candidate"


def run() -> dict:
    manifest = OUT / "pubspec.yaml"
    if not manifest.exists():
        raise ValueError("Run assemble_single_sdk_candidate.py first")
    names = json.loads((ROOT / "scripts" / "sdk_packages.json").read_text())
    native = [
        (name, plugin_entrypoints((ROOT / "packages" / name / "pubspec.yaml").read_text())["macos"])
        for name in names
        if "macos" in plugin_entrypoints((ROOT / "packages" / name / "pubspec.yaml").read_text())
    ]
    classes = OUT / "macos" / "Classes"
    resources = OUT / "macos" / "Resources"
    for generated in (classes, resources):
        if generated.exists():
            shutil.rmtree(generated)
    frameworks = set()
    pod_dependencies = set()
    files = 0
    header_counts = Counter(
        item.name for name, _ in native
        for item in (ROOT / "packages" / name / "macos").rglob("*.h")
    )
    for name, config in native:
        source = ROOT / "packages" / name / "macos"
        spec = next(source.glob("*.podspec"), None)
        if spec is not None:
            content = spec.read_text()
            for item in re.findall(r"s\.frameworks?\s*=\s*([^\n]+)", content):
                frameworks.update(re.findall(r"['\"]([^'\"]+)['\"]", item))
            pod_dependencies.update(re.findall(r"s\.dependency\s+['\"]([^'\"]+)['\"]", content))
        for item in source.rglob("*"):
            if not item.is_file():
                continue
            if item.name != "Package.swift" and item.suffix in (".swift", ".h", ".m", ".mm", ".c", ".cc", ".cpp"):
                if "test" in item.relative_to(source).parts:
                    continue
                target = classes / name / item.relative_to(source)
                if item.suffix == ".h" and header_counts[item.name] > 1:
                    target = target.with_name(f"{name}_{item.name}")
                target.parent.mkdir(parents=True, exist_ok=True)
                text = item.read_text(errors="ignore")
                if item.suffix in (".h", ".m", ".mm", ".c", ".cc", ".cpp"):
                    for header in sorted(header_counts):
                        if header_counts[header] > 1:
                            text = text.replace(
                                f'"{header}"', f'"{name}_{header}"'
                            )
                if item.suffix == ".swift":
                    # Former pod is now compiled in this very module.
                    text = re.sub(r"(?m)^import flutter_realtime_processed_video\s*$", "", text)
                    target.write_text(text)
                else:
                    target.write_text(text)
                files += 1
            elif item.suffix in (".html", ".js", ".xcprivacy", ".metallib", ".metal"):
                target = resources / name / item.name
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists():
                    # SPM and CocoaPods intentionally bundle byte-identical
                    # copies of each native WebKit JS/HTML resource. Merge
                    # them only when content matches; changed assets are an
                    # error rather than silently picking a different version.
                    if target.read_bytes() == item.read_bytes():
                        continue
                    raise ValueError(f"macOS resource collision: {target}")
                shutil.copy2(item, target)
    # Dynamically resolve the original plugin registration classes. The
    # generated Swift/ObjC files all compile in the *same* CocoaPods module.
    # Abort loudly on a missing class rather than pretending registration worked.
    classes.mkdir(parents=True, exist_ok=True)
    (classes / "FlutterRealtimeSdkPlugin.h").write_text(
        "#import <FlutterMacOS/FlutterMacOS.h>\n"
        "@interface FlutterRealtimeSdkPlugin : NSObject<FlutterPlugin>\n@end\n"
    )
    literals = ",\n      ".join(
        f'@"{config["pluginClass"]}"' for _, config in native
    )
    registrar = """#import "FlutterRealtimeSdkPlugin.h"
#import <objc/message.h>

@implementation FlutterRealtimeSdkPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  NSArray<NSString *> *pluginClasses = @[
      """ + literals + """
  ];
  for (NSString *name in pluginClasses) {
    Class plugin = NSClassFromString(name);
    if (!plugin) plugin = NSClassFromString([@"flutter_realtime_sdk." stringByAppendingString:name]);
    SEL registerSelector = @selector(registerWithRegistrar:);
    if (!plugin || ![plugin respondsToSelector:registerSelector]) {
      [NSException raise:@"FlutterRealtimeSdkPluginRegistration"
                  format:@"Missing bundled macOS plugin %@", name];
    }
    ((void (*)(id, SEL, id))objc_msgSend)(plugin, registerSelector, registrar);
  }
}
@end
"""
    (classes / "FlutterRealtimeSdkPlugin.m").write_text(registrar)
    # Internal source modules are no longer separate CocoaPods targets.
    pod_dependencies.difference_update(names)
    pod_dependencies.discard("Flutter")
    pod_dependencies.add("FlutterMacOS")
    pod_deps = "".join(f"  s.dependency '{d}'\n" for d in sorted(pod_dependencies))
    framework_names = ", ".join(f"'{f}'" for f in sorted(frameworks))
    spec = """Pod::Spec.new do |s|
  s.name = 'flutter_realtime_sdk'
  s.version = '0.1.0'
  s.summary = 'Realtime media, chat and classroom SDK'
  s.description = s.summary
  s.homepage = 'https://github.com/lengsukq/multi-video'
  s.license = { :file => '../LICENSE' }
  s.author = { 'OnePlusDream' => 'developers@oneplusdream.com' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,m,mm,swift,c,cc,cpp}'
  # Do not expose vendored Agora C++ implementation headers through the
  # generated Objective-C module umbrella (they require a C++ translation unit).
  s.public_header_files = 'Classes/FlutterRealtimeSdkPlugin.h'
  s.resources = 'Resources/**/*'
  s.platform = :osx, '12.0'
  s.swift_version = '5.9'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17'
  }
""" + pod_deps + f"  s.frameworks = {framework_names}\n" + "end\n"
    (OUT / "macos" / "flutter_realtime_sdk.podspec").write_text(spec)
    from_anchor = "flutter:\n  uses-material-design: true\n"
    data = manifest.read_text()
    if from_anchor not in data:
        raise ValueError("Unexpected pubspec format")
    if "      macos:\n        pluginClass: FlutterRealtimeSdkPlugin" not in data:
        # A prior Android assembly may already have inserted plugin:
        # platforms:; append at the platform indentation.
        if "  plugin:\n    platforms:\n" in data:
            data = data.replace(
                "  plugin:\n    platforms:\n",
                "  plugin:\n    platforms:\n      macos:\n        pluginClass: FlutterRealtimeSdkPlugin\n",
                1,
            )
        else:
            data = data.replace(
                from_anchor,
                from_anchor + "  plugin:\n    platforms:\n      macos:\n        pluginClass: FlutterRealtimeSdkPlugin\n",
                1,
            )
        manifest.write_text(data)
    return {"platform": "macos", "registrations": len(native),
            "sourceFiles": files, "podDependencies": sorted(pod_dependencies),
            "frameworks": sorted(frameworks),
            "warning": "CocoaPods compile and real-device testing required"}


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
