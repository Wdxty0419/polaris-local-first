#!/usr/bin/env bash
set -euo pipefail

echo "===== 1. install deps ====="
npm install
npm install @capacitor/background-runner

echo "===== 2. write runner ====="
mkdir -p public/runners
cat > public/runners/wake-probe.js <<'RUNNER_EOF'
addEventListener('wakeProbe', (resolve, reject, args) => {
  try {
    const now = Date.now();
    let log = [];
    try {
      const raw = CapacitorKV.get('wake_probe_log').value;
      if (raw) log = JSON.parse(raw);
    } catch (e) { log = []; }
    log.push(now);
    if (log.length > 500) log = log.slice(-500);
    CapacitorKV.set('wake_probe_log', JSON.stringify(log));
    CapacitorKV.set('wake_probe_last', String(now));
    console.log('[wake-probe] tick #' + log.length + ' at ' + new Date(now).toISOString());
    resolve();
  } catch (err) { reject(err); }
});
RUNNER_EOF

echo "===== 3. patch capacitor.config.ts ====="
python3 - <<'PY_EOF'
import io
p = 'capacitor.config.ts'
s = io.open(p, encoding='utf-8').read()
if 'BackgroundRunner' in s:
    print('already patched')
else:
    anchor = "LocalNotifications: { presentationOptions: ['badge', 'sound', 'banner', 'list'] }"
    if anchor not in s:
        raise SystemExit('ANCHOR MISSING in capacitor.config.ts')
    add = anchor + ", BackgroundRunner: { label: 'com.polaris.wakeprobe', src: 'runners/wake-probe.js', event: 'wakeProbe', repeat: true, interval: 15, autoStart: true }"
    io.open(p, 'w', encoding='utf-8').write(s.replace(anchor, add))
    print('patched')
PY_EOF
cat capacitor.config.ts

echo "===== 4. patch build.gradle ====="
python3 - <<'PY_EOF'
import io
p = 'android/app/build.gradle'
s = io.open(p, encoding='utf-8').read()
if 'background-runner' in s:
    print('already patched')
else:
    anchor = "'../capacitor-cordova-android-plugins/src/main/libs', 'libs' }"
    if anchor not in s:
        raise SystemExit('ANCHOR MISSING in build.gradle')
    add = "'../capacitor-cordova-android-plugins/src/main/libs', 'libs', '../../node_modules/@capacitor/background-runner/android/src/main/libs' }"
    io.open(p, 'w', encoding='utf-8').write(s.replace(anchor, add))
    print('patched')
PY_EOF

echo "===== 5. build ====="
npm run build
npx cap sync android

echo "===== 6. apk ====="
cd android
chmod +x gradlew
./gradlew assembleDebug --no-daemon
cd ..

echo "===== 7. verify ====="
unzip -l android/app/build/outputs/apk/debug/app-debug.apk | grep -i wake-probe || echo "WARNING: runner not found in APK"
