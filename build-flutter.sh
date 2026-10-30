#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

case "$(uname -s)" in
    Darwin)
        flutter build ipa --obfuscate --split-debug-info=build/app/outputs/symbols
        ./ios/Pods/FirebaseCrashlytics/upload-symbols -ai 1:742142459888:ios:f4b3f0ecc0737d8350a735 --platform ios -- ./build/app/outputs/
        ;;
    Linux)
        flutter build appbundle --obfuscate --split-debug-info=build/app/outputs/symbols
        firebase crashlytics:symbols:upload --app=1:742142459888:android:a068937b3b88140850a735 build/app/outputs/symbols
        ;;
    *)
        echo "Unsupported platform: $(uname -s). Use macOS for iOS or Linux for Android." >&2
        exit 1
        ;;
esac
