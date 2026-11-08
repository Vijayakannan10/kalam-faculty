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
"""
if "BLUETOOTH_SCAN" not in s:
    s = re.sub(r"(<manifest[^>]*>)", lambda m: m.group(1) + perms, s, count=1)
s = re.sub(r'android:label="[^"]*"', 'android:label="Kalam Faculty"', s, count=1)
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
