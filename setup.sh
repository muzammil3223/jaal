#!/usr/bin/env bash
# Is folder ke andar chalayein:  bash setup.sh
set -e
if [ -z "$SKIP_CREATE" ]; then
  mkdir -p /tmp/jaal_keep && cp lib/main.dart pubspec.yaml /tmp/jaal_keep/
  flutter create --platforms=android,ios --org com.jaal --project-name jaal .
  cp /tmp/jaal_keep/main.dart lib/main.dart && cp /tmp/jaal_keep/pubspec.yaml pubspec.yaml
fi
python3 - <<'PY'
import re, glob
# --- Android manifest permissions ---
p = 'android/app/src/main/AndroidManifest.xml'
s = open(p).read()
perms = ["INTERNET","ACCESS_NETWORK_STATE","ACCESS_WIFI_STATE","CHANGE_WIFI_STATE","CHANGE_NETWORK_STATE",
 "CHANGE_WIFI_MULTICAST_STATE","BLUETOOTH","BLUETOOTH_ADMIN","ACCESS_COARSE_LOCATION","ACCESS_FINE_LOCATION",
 "BLUETOOTH_ADVERTISE","BLUETOOTH_CONNECT","BLUETOOTH_SCAN","READ_EXTERNAL_STORAGE","RECORD_AUDIO",
 "CAMERA","MODIFY_AUDIO_SETTINGS","WAKE_LOCK","REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"]
add = ''.join('    <uses-permission android:name="android.permission.%s"/>\n' % x
              for x in perms if 'android.permission.%s"' % x not in s)
if 'NEARBY_WIFI_DEVICES' not in s:
    add += '    <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation"/>\n'
if add:
    s = s.replace('<application', add + '    <application', 1)
open(p, 'w').write(s)
# --- minSdk 23 ---
for g in glob.glob('android/app/build.gradle*'):
    t = open(g).read()
    t = re.sub(r'minSdk(Version)?\s*=?\s*flutter\.minSdkVersion', 'minSdk = 23', t)
    open(g, 'w').write(t)
# --- iOS Info.plist ---
try:
    p = 'ios/Runner/Info.plist'
    s = open(p).read()
    if 'NSLocalNetworkUsageDescription' not in s:
        add = ('\t<key>NSLocalNetworkUsageDescription</key>\n\t<string>Jaal aas-paas ke devices se baat karta hai.</string>\n'
               '\t<key>NSBonjourServices</key>\n\t<array>\n\t\t<string>_jaal._tcp</string>\n\t</array>\n'
               '\t<key>NSMicrophoneUsageDescription</key>\n\t<string>Voice call aur voice message ke liye.</string>\n'
               '\t<key>NSCameraUsageDescription</key>\n\t<string>Video call ke liye.</string>\n')
        i = s.rindex('</dict>')
        s = s[:i] + add + s[i:]
        open(p, 'w').write(s)
except FileNotFoundError:
    pass
print('Patch mukammal.')
PY
[ -f ios/Podfile ] && sed -i.bak "s/^# platform :ios.*/platform :ios, '13.0'/" ios/Podfile || true
flutter pub get
echo "Taiyar. Asli phone jorein aur chalayein:  flutter run"
