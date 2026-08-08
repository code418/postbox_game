# R8 app optimization — design

**Date:** 2026-07-24
**Status:** approved (design), pending implementation
**Scope:** Android build configuration only. No Dart, no app source, no Cloud Functions.

## Problem

Android Studio surfaced a prompt to "Enable app optimization with R8"
(https://developer.android.com/topic/performance/app-optimization/enable-app-optimization).
The task is to make sure this app's release builds are R8-optimised.

## Finding: R8 optimization is already on

Investigation shows the core of the request is already satisfied, so this work is
cleanup and the remaining opt-ins rather than a first enablement.

Flutter's own Gradle plugin enables R8 for the `release` build type by default.
In `packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt` (~lines
214–227), when `shouldShrinkResources(project)` is true (its default), it sets:

- `releaseBuildType.isMinifyEnabled = true`
- `releaseBuildType.isShrinkResources = isBuiltAsApp(project)` (true for the app module)
- adds `proguard-android-optimize.txt` and `flutter_proguard_rules.pro` to R8's config
- adds `android/app/proguard-rules.pro` **if it exists** (it does not, today)

Nothing in `android/app/build.gradle` opts out of this.

Evidence from the last release builds (not just plugin source):

| Check | State |
|---|---|
| `minify{Phone,Auto,Wear}ReleaseWithR8` tasks | all three ran |
| R8 version (`mapping.txt` header) | 8.11.18, `min_api: 24` |
| Obfuscation | 450,783 renamed symbols in `mapping.txt` |
| Dead-code removal | 89,477 entries in `usage.txt` |
| Resource shrinking | `shrunk_resources_proto_format/` present per flavour |
| Full mode (`android.enableR8.fullMode`) | AGP 8.11.1 default `true`, not overridden → on |
| `android.r8.integratedResourceShrinking` | AGP 8.11.1 default `true` → on |
| Crashlytics mapping upload | `mappingFileId.txt` written per release flavour |

Scope note: R8 only optimises the Java/Kotlin layer. The bulk of this app is Dart
compiled into `libapp.so`, which R8 never touches. Dart-side `--obfuscate
--split-debug-info` is a separate lever and is explicitly **out of scope** here.

## Changes

Three changes, all in Android build config.

### 1. `android/gradle.properties` — drop dead flag, add the remaining opt-in

Remove `android.enableR8=true`. AGP declares this option
`FeatureStage.Enforced(VERSION_7_0, "Please remove it from gradle.properties")` —
it has been a no-op for four major versions, AGP warns about it, and it misleads
readers into thinking it is the switch that controls R8 (the real switch is
Flutter's implicit default).

Add `android.r8.optimizedShrinking=true`. This is AGP 8.11's name for the flag the
Android docs call `android.r8.optimizedResourceShrinking` on AGP 8.12–8.13 (it
becomes automatic in AGP 9.0). It defaults to `false` and is
`FeatureStage.Experimental` in 8.11.1. Its documented prerequisites are both
already met here: `android.r8.integratedResourceShrinking` (default true) and
`android.nonFinalResIds` (default true). Comment it with the rename/removal path
for when we move off AGP 8.11.

### 2. `android/app/build.gradle` — regression guard (assert)

Because minify/shrink come from an implicit Flutter default rather than anything in
this repo, `flutter build --no-shrink` (`-Pshrink=false`) or a change to that
upstream default would silently ship an unoptimised release with no signal in the
repo. Add an `afterEvaluate` assertion on the `release` build type:

```groovy
// R8 code + resource shrinking on `release` is switched on by the Flutter Gradle
// plugin (FlutterPlugin.shouldShrinkResources defaults to true), which also feeds
// R8 proguard-android-optimize.txt + flutter_proguard_rules.pro. Nothing in THIS
// file enables it, so assert it rather than let `-Pshrink=false` or a change to
// that upstream default quietly ship an unoptimised release.
afterEvaluate {
    def rel = android.buildTypes.release
    if (!rel.minifyEnabled || !rel.shrinkResources) {
        throw new GradleException("release build type is not R8-optimised " +
            "(minifyEnabled=${rel.minifyEnabled}, shrinkResources=${rel.shrinkResources}).")
    }
}
```

**Chosen over** pinning `minifyEnabled true` / `shrinkResources true` directly in
`buildTypes.release`. Flutter adds the proguard files in the *same* code branch it
sets the flags, so pinning only the flags could yield minification with an empty
rule set (broken runtime) if that branch is ever skipped — partial protection that
looks total. Appending the proguard files ourselves avoids that but duplicates
entries in the merged R8 config on every normal build. The assertion has neither
problem: it changes no build output, it only fails loudly if the optimisation ever
disappears.

**Accepted trade-off:** `flutter build --no-shrink` becomes a build failure instead
of an unshrunk build. That is the intent (the app has no reason to ship unshrunk),
at the cost of that debugging escape hatch. If we later want the hatch back, gate
the assertion behind an opt-out Gradle property.

### Deliberately excluded

- **`android.r8.strictFullModeForKeepRules`** (Supported, default false). It stops a
  kept class from implicitly keeping its default constructor — a real
  runtime-breakage risk against the ~50 consumer keep-rule files that Firebase /
  Play Services / other AARs contribute to this build, and the Android doc does not
  ask for it.
- **A new `android/app/proguard-rules.pro`.** Nothing currently needs app-specific
  keep rules (no reflection-based Firestore mapping in the `auto`/`main` Kotlin;
  `flutter_local_notifications` v19+ ships its own GSON rules). Flutter picks up the
  file automatically the day one is needed.
- **Dart `--obfuscate --split-debug-info`.** Separate concern, separate spec.

## Verification

The working tree has no Android/Dart changes, so the current build outputs are a
valid before-baseline.

1. **Baseline (already on disk):**
   - phone AAB: `build/app/outputs/bundle/phoneRelease/app-phone-release.aab` = 67,768,503 B
   - wear AAB: `build/app/outputs/bundle/wearRelease/app-wear-release.aab` = 55,458,291 B
   - resource reports: `build/app/outputs/mapping/*/resources.txt`

   Copy these aside before rebuilding.

2. **Rebuild all three flavours** via `tools/release.sh` (handles JDK 17+ selection):
   - `flutter build appbundle --flavor phone --release`
   - `flutter build appbundle --flavor wear --release -t lib/main_wear.dart`
   - `flutter build apk --flavor auto --release -t lib/main.dart`

   All three must build clean (the assertion must pass, not fire).

3. **Compare** AAB/APK sizes and the shrunk-resource reports before vs after.
   Optimised resource shrinking should hold or reduce size; a size increase or a
   build failure is a regression to investigate.

4. **Runtime smoke test.** `optimizedShrinking` is a *resource* optimisation whose
   failure mode is a missing drawable/string at runtime, not a build error. Install
   the `phone` release APK on the Pixel 7a emulator and walk the resource-heavy
   paths: launch, login, Nearby map, James strip, claim quiz sheet, History, About.

## Rollback

Each change is independently revertible in `git`. If the runtime smoke test shows a
missing resource, drop `android.r8.optimizedShrinking=true` first (it is the only
behaviour-changing line); the flag removal and the assertion do not alter build
output.
