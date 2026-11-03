#!/usr/bin/env bash
set -euo pipefail
package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/realtime-frame-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc "$package_root/macos/flutter_realtime_media_aws_desktop/Sources/flutter_realtime_media_aws_desktop/AwsProcessedFrameFeed.swift" \
  "$package_root/test/macos_native_frame_feed_test.swift" \
  -o "$check_dir/frame-feed-test"
"$check_dir/frame-feed-test" "$package_root/macos/Resources/aws_desktop_runtime.js"
