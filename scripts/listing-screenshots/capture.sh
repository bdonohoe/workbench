#!/bin/zsh
# Captures the iPhone app's demo mode in the simulator for the App Store
# screenshots. Debug builds only: BENCH_OPEN_PROJECT and BENCH_OPEN_SCREEN
# jump straight to a screen. Then run compose.py.
set -euo pipefail
cd "$(dirname "$0")/../.."
SIM=${SIM:-"iPhone 17 Pro Max"}
U=$(xcrun simctl list devices available -j | python3 -c "
import json,sys; d=json.load(sys.stdin)['devices']
print(next(x['udid'] for k,v in d.items() if 'iOS-27' in k for x in v if x['name']=='$SIM'))")
# For the Duo's inner display: open the device flat in Device Hub (simctl
# can't change poses), then SIM="iPhone Duo" DISPLAY_ID=3 OUT=fastlane/screenshots/raw-duo.
OUT=${OUT:-fastlane/screenshots/raw}
DISPLAY_ARG=${DISPLAY_ID:+--display=$DISPLAY_ID}
mkdir -p $OUT

xcodegen generate -q
xcodebuild -project Bench.xcodeproj -scheme BenchPhone -configuration Debug \
    -destination "platform=iOS Simulator,id=$U" -derivedDataPath build/phonesim build -quiet
xcrun simctl boot $U 2>/dev/null || true
xcrun simctl bootstatus $U -b >/dev/null
xcrun simctl status_bar $U override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl install $U build/phonesim/Build/Products/Debug-iphonesimulator/Bench.app

# name, appearance, project, screen, seconds to wait
cap() {
    xcrun simctl ui $U appearance $2
    xcrun simctl terminate $U me.birchtree.BenchPhone 2>/dev/null || true
    SIMCTL_CHILD_BENCH_DEMO=1 SIMCTL_CHILD_BENCH_OPEN_PROJECT="$3" SIMCTL_CHILD_BENCH_OPEN_SCREEN="$4" \
        xcrun simctl launch $U me.birchtree.BenchPhone -checklistExpanded YES >/dev/null
    sleep $5
    xcrun simctl io $U screenshot ${=DISPLAY_ARG} $OUT/$1.png >/dev/null 2>&1
    echo $OUT/$1.png
}
cap list light "" "" 5
cap list-dark dark "" "" 5
cap permission-dark dark Website "" 5
cap working light Recipes "" 5
cap agent light dark-mode "" 5
cap diff-agent light dark-mode diff 8

xcrun simctl terminate $U me.birchtree.BenchPhone || true
xcrun simctl ui $U appearance light
xcrun simctl status_bar $U clear
