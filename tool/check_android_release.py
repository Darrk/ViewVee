#!/usr/bin/env python3
"""Check reflective startup constructors and the notification icon in a minified APK.

Run after `flutter build apk --release`:
    python3 tool/check_android_release.py [path/to/app-release.apk]

Uses apkanalyzer from the Android SDK. Checks the APK itself, since successful
compilation and debug launches do not detect constructors removed by R8.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ANDROID = "{http://schemas.android.com/apk/res/android}"


def find_apkanalyzer():
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    properties = ROOT / "android/local.properties"
    if not sdk and properties.exists():
        for line in properties.read_text().splitlines():
            if line.startswith("sdk.dir="):
                sdk = line.split("=", 1)[1]
                break
    if sdk:
        candidate = Path(sdk) / "cmdline-tools/latest/bin/apkanalyzer"
        if candidate.is_file():
            return str(candidate)
    analyzer = shutil.which("apkanalyzer")
    if not analyzer:
        raise RuntimeError("apkanalyzer not found; set ANDROID_HOME to your SDK")
    return analyzer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "apk", nargs="?", type=Path,
        default=ROOT / "build/app/outputs/flutter-apk/app-release.apk",
    )
    args = parser.parse_args()
    apk = args.apk.resolve()
    if not apk.is_file():
        parser.error(f"APK does not exist: {apk}")
    analyzer = find_apkanalyzer()

    def run(*arguments):
        result = subprocess.run(
            [analyzer, *arguments, str(apk)], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return result.stdout

    manifest = ET.fromstring(run("manifest", "print"))
    application = manifest.find("application")
    if application is None or application.get(ANDROID + "debuggable") == "true":
        raise RuntimeError("Expected a non-debuggable release APK")

    # These old WorkManager / Room classes use reflection without complete
    # consumer keep rules for R8 full mode.
    constructors = {
        "androidx.work.impl.WorkDatabase_Impl",
        "androidx.work.OverwritingInputMerger",
        "androidx.work.ArrayCreatingInputMerger",
    }
    for metadata in manifest.iter("meta-data"):
        name = metadata.get(ANDROID + "name", "")
        value = metadata.get(ANDROID + "value", "")
        if value == "androidx.startup":
            constructors.add(name)
        elif name.startswith("com.google.firebase.components:"):
            constructors.add(name.split(":", 1)[1])
        elif name.startswith("backend:"):
            constructors.add(name.split(":", 1)[1])
        elif name == "androidx.camera.core.impl.MetadataHolderService.DEFAULT_CONFIG_PROVIDER":
            constructors.add(value)

    def check(class_name):
        try:
            code = run("dex", "code", "--class", class_name, "--method", "<init>()V")
            if not re.search(r"^\.method public constructor <init>\(\)V$", code, re.M):
                raise RuntimeError("public no-argument constructor is missing")
            return None
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            return f"{class_name}: {error}"

    with ThreadPoolExecutor(max_workers=4) as pool:
        failures = list(filter(None, pool.map(check, sorted(constructors))))
    # The notifications plugin resolves this Dart-supplied name with
    # Resources.getIdentifier(), outside the shrinker's static references.
    configs = run("resources", "configs", "--type", "drawable").splitlines()
    if not configs:
        failures.append("No drawable resources found")
    else:
        config = "hdpi" if "hdpi" in configs else configs[0]
        names = run("resources", "names", "--type", "drawable", "--config", config)
        if "ic_launcher_foreground" not in names.splitlines():
            failures.append("Notification drawable ic_launcher_foreground is missing")
    if failures:
        print("Release reflection check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(
        f"PASS: {len(constructors)} reflective constructors and notification icon "
        f"retained in {apk.name}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
