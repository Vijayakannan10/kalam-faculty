"""Adds Bluetooth/Location permissions and build settings to the Android files
that `flutter create` generates. Run from the project root (the GitHub build does this)."""
import pathlib
import re

root = pathlib.Path(".")

# 1. Permissions + app name
manifest = root / "android/app/src/main/AndroidManifest.xml"
s = manifest.read_text()
perms = """
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
"""
if "BLUETOOTH_SCAN" not in s:
    s = re.sub(r"(<manifest[^>]*>)", lambda m: m.group(1) + perms, s, count=1)
s = re.sub(r'android:label="[^"]*"', 'android:label="Kalam Finder"', s, count=1)
service = """        <service
            android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:foregroundServiceType="connectedDevice"
            android:exported="false" />
    </application>"""
if "flutter_foreground_task.service.ForegroundService" not in s:
    s = s.replace("</application>", service, 1)
manifest.write_text(s)
print("Manifest patched")

# 2. minSdk 23 (needed by Firebase)
for name in ["android/app/build.gradle", "android/app/build.gradle.kts"]:
    p = root / name
    if not p.exists():
        continue
    t = p.read_text()
    t2 = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 23", t)
    t2 = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 23", t2)
    p.write_text(t2)
    print(f"{name}: minSdk set to 23" if t2 != t else f"{name}: minSdk line not found (left as is)")

# 3. Newer Kotlin (Firebase libraries need it)
for name in ["android/settings.gradle", "android/settings.gradle.kts"]:
    p = root / name
    if not p.exists():
        continue
    t = p.read_text()
    t2 = re.sub(r'(org\.jetbrains\.kotlin\.android"\)?\s+version\s+")[\d.]+', r"\g<1>1.9.24", t)
    p.write_text(t2)
    print(f"{name}: Kotlin set to 1.9.24" if t2 != t else f"{name}: Kotlin line not found (left as is)")

# 4. Fixed signing key, so every new build installs over the previous one
for name in ["android/app/build.gradle", "android/app/build.gradle.kts"]:
    p = root / name
    if not p.exists():
        continue
    t = p.read_text()
    if "kalam-release.jks" in t:
        continue
    if name.endswith(".kts"):
        block = '''    signingConfigs {
        create("kalam") {
            storeFile = file("../../android-signing/kalam-release.jks")
            storePassword = "kalamfinder"
            keyAlias = "kalam"
            keyPassword = "kalamfinder"
        }
    }

    buildTypes {'''
        t2 = t.replace("    buildTypes {", block, 1)
        t2 = t2.replace('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("kalam")')
    else:
        block = '''    signingConfigs {
        kalam {
            storeFile file("../../android-signing/kalam-release.jks")
            storePassword "kalamfinder"
            keyAlias "kalam"
            keyPassword "kalamfinder"
        }
    }

    buildTypes {'''
        t2 = t.replace("    buildTypes {", block, 1)
        t2 = t2.replace("signingConfig = signingConfigs.debug", "signingConfig = signingConfigs.kalam")
        t2 = t2.replace("signingConfig signingConfigs.debug", "signingConfig signingConfigs.kalam")
    p.write_text(t2)
    print(f"{name}: fixed signing key added" if "signingConfigs.kalam" in t2 or 'getByName("kalam")' in t2 else f"{name}: signing line not found")
