#!/bin/sh
set -eu

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_dir="$package_dir/macos/test"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/aws-processed-frame-integration.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT INT TERM

swiftc \
  "$package_dir/macos/flutter_realtime_media_aws_desktop/Sources/flutter_realtime_media_aws_desktop/AwsProcessedFrameFeed.swift" \
  "$test_dir/AwsProcessedFrameFeedIntegration.swift" \
  -framework AppKit \
  -framework CoreImage \
  -framework CoreVideo \
  -framework Foundation \
  -framework ImageIO \
  -framework WebKit \
  -o "$build_dir/aws-processed-frame-integration"

"$build_dir/aws-processed-frame-integration" \
  "$package_dir/macos/Resources/aws_desktop_runtime.js"
