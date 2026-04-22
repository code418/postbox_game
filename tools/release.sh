#!/usr/bin/env bash
# Build signed release AABs for both phone and Wear OS flavors.
# Both bundles share applicationId com.code418.postbox_game; the wear flavor
# is offset by +10000 in versionCode (see android/app/build.gradle) so Play
# Console accepts both in the same release.
set -euo pipefail

cd "$(dirname "$0")/.."

flutter build appbundle --flavor phone --release
flutter build appbundle --flavor wear  --release -t lib/main_wear.dart

echo
echo "Built:"
echo "  build/app/outputs/bundle/phoneRelease/app-phone-release.aab"
echo "  build/app/outputs/bundle/wearRelease/app-wear-release.aab"
echo
echo "Upload both AABs to the same Play Console release."
