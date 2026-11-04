#!/usr/bin/env bash
# Build signed release artifacts.
#
# Three flavours share applicationId com.code418.postbox_game:
#   - phone : Google Play. Carries NO Android Auto (Play rejected the car app
#             twice under the Auto app-quality guidelines).
#   - wear  : Google Play, Wear OS. Offset +10000 in versionCode (see
#             android/app/build.gradle) so Play accepts the phone + wear AABs
#             in the same release.
#   - auto  : distributed OUTSIDE Google Play. Carries the full Android Auto
#             surface (android/app/src/auto/, Car App Library deps scoped
#             `autoImplementation`). Built as a directly-installable APK.
#
# Gradle/AGP require a JDK 17+. The system `java` may be older (e.g. 11), so
# this script selects a suitable JDK itself, preferring the Android Studio JBR.
set -euo pipefail

cd "$(dirname "$0")/.."

# --- Select a JDK 17+ (AGP/Gradle requirement) ------------------------------
java_major() {
    # Echo the major version of the java binary in $1 (e.g. 21), or nothing.
    "$1" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1
}

pick_jdk() {
    # 1) Honour a caller-provided JAVA_HOME if it is already 17+.
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        local v; v=$(java_major "${JAVA_HOME}/bin/java")
        if [[ -n "$v" && "$v" -ge 17 ]]; then echo "$JAVA_HOME"; return 0; fi
    fi
    # 2) Otherwise probe common Android Studio JBR locations (ship a JDK 17+).
    local c
    for c in \
        /snap/android-studio/current/jbr \
        "${HOME}/android-studio/jbr" \
        /opt/android-studio/jbr \
        /usr/local/android-studio/jbr \
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
        if [[ -x "${c}/bin/java" ]]; then
            local v; v=$(java_major "${c}/bin/java")
            if [[ -n "$v" && "$v" -ge 17 ]]; then echo "$c"; return 0; fi
        fi
    done
    return 1
}

if ! JAVA_HOME=$(pick_jdk); then
    echo "ERROR: a JDK 17+ is required to build (Gradle/AGP)." >&2
    echo "       Install Android Studio (bundles a JBR) or set JAVA_HOME to a JDK 17+." >&2
    exit 1
fi
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"
echo "Using JDK: ${JAVA_HOME} ($("${JAVA_HOME}/bin/java" -version 2>&1 | head -1))"
echo

# --- Build ------------------------------------------------------------------
# Play (upload both AABs to the same Play Console release):
flutter build appbundle --flavor phone --release
flutter build appbundle --flavor wear  --release -t lib/main_wear.dart
# Off-Play Android Auto build (directly-installable APK):
flutter build apk       --flavor auto  --release -t lib/main.dart

echo
echo "Built:"
echo "  Play (upload both to the same Play Console release):"
echo "    build/app/outputs/bundle/phoneRelease/app-phone-release.aab"
echo "    build/app/outputs/bundle/wearRelease/app-wear-release.aab"
echo "  Off-Play (Android Auto; distribute directly, not via Play):"
echo "    build/app/outputs/flutter-apk/app-auto-release.apk"
