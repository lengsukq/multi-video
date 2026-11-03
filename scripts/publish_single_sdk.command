#!/usr/bin/env bash
# Manual, one-command pub.dev preview release from current SDK monorepo sources.
# Canceling the pub.dev confirmation leaves an immutable, resumable stage.
# Never uses --force or uploads without pub.dev's interactive confirmation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: bash scripts/publish_single_sdk.command 0.1.0-dev.N"
  echo "An explicit unpublished version is required; dev.15 has already shipped."
  echo "First run checks, assembles, analyzes and dry-runs a release."
  echo "Reruns verify/reuse the same staged release without rebuilding."
  echo "Only pub.dev's own interactive y/N confirmation can publish."
  exit 0
fi
if [[ -z "$VERSION" ]]; then
  echo "Specify the NEXT unpublished preview version explicitly (dev.15 is already published)." >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^0\.1\.0-dev\.[1-9][0-9]*$ ]]; then
  echo "Invalid preview version: $VERSION (expected 0.1.0-dev.N)" >&2
  exit 2
fi
if [[ ! -t 0 ]]; then
  echo "Run this script from an interactive Terminal; publishing is never automatic." >&2
  exit 2
fi
for executable in python3 flutter git; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "Missing required executable: $executable" >&2
    exit 2
  fi
done
cd "$ROOT"
STAGE="$ROOT/build/pub_release/$VERSION/flutter_realtime_sdk"
RESUMING=0
if [[ -e "$STAGE" ]]; then
  echo "==> Found previous staged $VERSION; checking all release-file SHA-256 hashes"
  python3 scripts/prepare_single_sdk_release.py --version "$VERSION" --verify
  RESUMING=1
  echo "==> Release content verified: resuming without rebuilding."
  echo "    Source edits made after staging are NOT in this release."
fi

if [[ "$RESUMING" -eq 0 ]]; then
echo "==> 1/7: SDK architecture and full internal-package checks"
python3 scripts/check_sdk_architecture.py
python3 -m unittest discover -s scripts/tests -q
python3 scripts/check_sdk_quality.py --analyze --test --timeout 100
echo "==> 2/7: Web regression for classroom action IDs (VM and Chrome)"
(
  cd packages/flutter_realtime_classroom_preset
  flutter test --no-pub test/http_classroom_repository_test.dart
  flutter test --no-pub --platform chrome test/http_classroom_repository_test.dart
)
(
  cd packages/flutter_realtime_whiteboard_core
  dart test --platform chrome test/whiteboard_test.dart
)
(
  cd packages/flutter_realtime_live_core
  dart test --platform chrome test/live_interactions_test.dart
)
(
  cd packages/flutter_realtime_sdk_runtime
  flutter test --no-pub --platform chrome test/classroom_chat_transport_test.dart
)
echo "==> 3/7: Shared-content SDK regression"
(
  cd packages/flutter_realtime_sdk_runtime
  flutter test --no-pub test/shared_content_controller_test.dart
)
(
  cd packages/flutter_realtime_media_ui
  flutter test --no-pub test/shared_content_error_strings_test.dart
)
echo "==> 4/7: Create fresh one-package distribution"
python3 scripts/assemble_single_sdk_distribution.py
echo "==> 5/7: Stage preview $VERSION"
python3 scripts/prepare_single_sdk_release.py --version "$VERSION"
fi

[[ -f "$STAGE/pubspec.yaml" ]] || { echo "Staging failed" >&2; exit 1; }
grep -Eq "^version: $VERSION$" "$STAGE/pubspec.yaml" || {
  echo "Staged version does not match requested $VERSION" >&2; exit 1;
}
if grep -R --include='*.dart' -n -F 'nextInt(1 << 32)' "$STAGE/lib"; then
  echo "The staged SDK still contains the Flutter Web random-bound bug." >&2
  exit 1
fi
python3 scripts/verify_single_sdk_web_assets.py --package "$STAGE"

echo "==> 6/7: Resolve, analyze and dry-run exact staged pub package"
cd "$STAGE"
flutter pub get
flutter analyze --no-pub
flutter pub publish --dry-run

echo
echo "==> 7/7: pub.dev interactive confirmation"
echo "Ready to publish flutter_realtime_sdk $VERSION to pub.dev."
echo "The preceding checks do NOT replace real-device testing, license review,"
echo "or acceptance tests for every RTC provider."
# No duplicate custom 'PUBLISH VERSION' prompt: pub.dev asks y/N itself.
# If the user cancels, the verified staging directory remains resumable.
flutter pub publish
