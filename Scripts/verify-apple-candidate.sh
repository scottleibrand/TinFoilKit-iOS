#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/verify-apple-candidate.sh SIMULATOR_UDID NEW_OUTPUT_DIR
       [--ui-test TinfoilKitUITests/TEST] [--device IDENTIFIER --team TEAM_ID]
       [--install] [--lightweight]

Run the app and reader unit suites on the named simulator. Prepare any selected
UI test fixtures on that simulator first. A device and team request a signed
standard build. --install installs that build after verification. --lightweight
also builds an unsigned lightweight release and measures its ZIP.
EOF
}

fail() {
    printf '%s\n' "$1" >&2
    exit 2
}

if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
if [[ $# -lt 2 ]]; then usage >&2; exit 2; fi
simulator=$1
output=$2
shift 2
device=
team=
install=false
lightweight=false
verify_ui=false
ui_tests=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ui-test)
            [[ "${2:-}" == TinfoilKitUITests/* ]] || fail 'Use a specific TinfoilKitUITests test identifier.'
            ui_tests+=("-only-testing:$2")
            verify_ui=true
            shift 2 ;;
        --device|--team)
            [[ -n "${2:-}" && "$2" != --* ]] || fail "Provide a value for $1."
            if [[ "$1" == --device ]]; then device=$2; else team=$2; fi
            shift 2 ;;
        --install) install=true; shift ;;
        --lightweight) lightweight=true; shift ;;
        *) fail "Unknown option $1." ;;
    esac
done
[[ "$simulator" =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]] || fail 'Use an explicit simulator UDID.'
[[ -z "$device" && -z "$team" || -n "$device" && -n "$team" ]] || fail 'Supply both --device and --team for signing.'
[[ "$install" == false || -n "$device" ]] || fail '--install needs a signed device build.'
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'Apple verification needs an Apple Silicon Mac with Xcode.'
for tool in xcodebuild xcrun xcodegen cargo; do
    command -v "$tool" >/dev/null || fail "Missing required tool $tool."
done

# Keep all XCTest artifacts and build products for this invocation together.
mkdir -- "$output"
output=$(cd "$output" && pwd -P)
cd "$(dirname "$0")/.."
git rev-parse HEAD > "$output/revision.txt"
git status --short --untracked-files=no > "$output/tracked-changes.txt"

run_logged() {
    local step=$1
    shift
    printf '\n%s\n' "$step"
    "$@" 2>&1 | tee "$output/$step.log"
}

run_logged xcode-version xcodebuild -version
run_logged simulator xcrun simctl bootstatus "$simulator" -b
run_logged map-assets bash Scripts/prepare-map-assets.sh
run_logged apple-routing bash Scripts/routing/prepare-apple-routing.sh
run_logged simulator-reader bash Scripts/prepare-zim-reader.sh simulator

simulator_build=(-project TinfoilKit.xcodeproj -destination "platform=iOS Simulator,id=$simulator"
                 -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO)
run_logged app-unit-tests xcodebuild test "${simulator_build[@]}" -scheme TinfoilKit \
    -derivedDataPath "$output/app-simulator" -resultBundlePath "$output/app-unit-tests.xcresult" \
    -only-testing:MapTileTests
run_logged archive-unit-tests xcodebuild test "${simulator_build[@]}" -scheme ZIMArchive \
    -derivedDataPath "$output/archive-simulator" -resultBundlePath "$output/archive-unit-tests.xcresult" \
    -only-testing:ZIMArchiveTests
if [[ "$verify_ui" == true ]]; then
    run_logged app-ui-tests xcodebuild test "${simulator_build[@]}" -scheme TinfoilKit \
        -derivedDataPath "$output/ui-simulator" -resultBundlePath "$output/app-ui-tests.xcresult" "${ui_tests[@]}"
fi

if [[ -n "$device" || "$lightweight" == true ]]; then
    run_logged device-reader bash Scripts/prepare-zim-reader.sh device
fi
if [[ -n "$device" ]]; then
    run_logged signed-standard xcodebuild build -project TinfoilKit.xcodeproj -scheme TinfoilKit \
        -configuration Debug -destination "platform=iOS,id=$device" -derivedDataPath "$output/signed-standard" \
        "DEVELOPMENT_TEAM=$team" CODE_SIGN_STYLE=Automatic
fi
if [[ "$lightweight" == true ]]; then
    run_logged lightweight-assets bash Scripts/prepare-map-assets.sh --lightweight
    run_logged lightweight-project xcodegen generate --spec project-lightweight.yml
    run_logged lightweight-build xcodebuild build -project TinfoilKitLightweight.xcodeproj -scheme TinfoilKit \
        -configuration Release -destination generic/platform=iOS -derivedDataPath "$output/lightweight" CODE_SIGNING_ALLOWED=NO
    lightweight_app="$output/lightweight/Build/Products/Release-iphoneos/TinfoilKit.app"
    run_logged lightweight-zip ditto -c -k --keepParent "$lightweight_app" "$output/TinfoilKit-lightweight.zip"
    run_logged lightweight-size wc -c "$output/TinfoilKit-lightweight.zip"
fi
if [[ "$install" == true ]]; then
    standard_app="$output/signed-standard/Build/Products/Debug-iphoneos/TinfoilKit.app"
    run_logged device-install xcrun devicectl device install app --device "$device" "$standard_app"
fi
printf '\nVerification results are in %s\n' "$output"
