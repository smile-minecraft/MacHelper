# Sourced (not run) from the repository root, after scripts/lib/env.sh, by the scripts that run
# the app's MacHelperTests bundle. Sets:
#   APP_TEST_DERIVED_DATA  where xcodebuild builds the app and its tests
#   APP_TEST_FLAGS         the xcodebuild arguments shared by every app test run
#
# The app tests run in a copy of MacHelper.app that LaunchServices starts on its own. When that
# copy sits on an external volume, macOS asks for permission before it may read the frameworks
# next to it, and the test host waits for that answer until xcodebuild gives up. So a checkout
# that is not on the startup disk builds the tests in a folder there instead of build/.
# MACHELPER_TEST_DERIVED_DATA overrides the choice.

if [ -n "${MACHELPER_TEST_DERIVED_DATA:-}" ]; then
    APP_TEST_DERIVED_DATA="$MACHELPER_TEST_DERIVED_DATA"
elif [ "$(stat -f %d "$PWD")" != "$(stat -f %d "$HOME")" ]; then
    APP_TEST_DERIVED_DATA="$HOME/Library/Developer/MacHelper/TestDerivedData/$(printf '%s' "$PWD" | shasum | cut -c1-12)"
else
    APP_TEST_DERIVED_DATA="build"
fi

APP_TEST_FLAGS=(
    -project MacHelper.xcodeproj -scheme MacHelper
    -destination "platform=macOS,arch=$(uname -m)"
    -derivedDataPath "$APP_TEST_DERIVED_DATA"
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
)
