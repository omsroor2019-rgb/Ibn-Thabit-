#!/usr/bin/env bash
set -euo pipefail

# Align the Flutter SDK's included Gradle build plugin with the Flutter 3.50 toolchain.
bash tool/patch_flutter_gradle.sh

if [[ ! -d android ]]; then
  flutter create --platforms=android --org com.binthabit --project-name bin_thabit .
fi

# Flutter 3.50's generated template test is for the sample MyApp and may import
# material_ui. This app has its own targeted tests; discard only that generated sample.
if [[ -f test/widget_test.dart ]] && grep -q 'MyApp' test/widget_test.dart; then
  rm -f test/widget_test.dart
fi

python3 - <<'PY'
from pathlib import Path
manifest = Path('android/app/src/main/AndroidManifest.xml')
text = manifest.read_text(encoding='utf-8')
permission = '    <uses-permission android:name="android.permission.USE_BIOMETRIC" />\n'
if 'android.permission.USE_BIOMETRIC' not in text:
    text = text.replace('<application', permission + '    <application', 1)
text = text.replace('android:label="bin_thabit"', 'android:label="بن ثابت"')
# Disallow cleartext HTTP traffic; the app uses encrypted local storage and Android share intents.
if 'android:usesCleartextTraffic=' not in text:
    text = text.replace('<application', '<application android:usesCleartextTraffic="false"', 1)
else:
    import re
    text = re.sub(r'android:usesCleartextTraffic="[^"]*"', 'android:usesCleartextTraffic="false"', text, count=1)
# Prevent Android from restoring SQLCipher files and Keystore-backed preferences separately.
import re
for attribute, value in {
    'android:allowBackup': 'false',
    'android:fullBackupContent': '@xml/bin_thabit_backup_rules',
    'android:dataExtractionRules': '@xml/bin_thabit_data_extraction_rules',
}.items():
    pattern = rf'{re.escape(attribute)}="[^"]*"'
    if re.search(pattern, text):
        text = re.sub(pattern, f'{attribute}="{value}"', text, count=1)
    else:
        text = text.replace('<application', f'<application {attribute}="{value}"', 1)
manifest.write_text(text, encoding='utf-8')

# Keep explicit exclusion rules for legacy Android versions and Android 12+ D2D transfers.
resource_dir = Path('android/app/src/main/res/xml')
resource_dir.mkdir(parents=True, exist_ok=True)
for source, target in [
    (Path('tool/android/backup_rules.xml'), resource_dir / 'bin_thabit_backup_rules.xml'),
    (Path('tool/android/data_extraction_rules.xml'), resource_dir / 'bin_thabit_data_extraction_rules.xml'),
]:
    target.write_text(source.read_text(encoding='utf-8'), encoding='utf-8')

activity = Path('android/app/src/main/kotlin/com/binthabit/bin_thabit/MainActivity.kt')
if activity.exists():
    activity.write_text('''package com.binthabit.bin_thabit

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Hide financial screens from screenshots, screen recordings and recent-app previews.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }
}
''', encoding='utf-8')

build = Path('android/app/build.gradle.kts')
if build.exists():
    source = build.read_text(encoding='utf-8')
    source = source.replace('minSdk = flutter.minSdkVersion', 'minSdk = 24')
    if 'proguardFiles(' not in source:
        import re
        match = re.search(r'(?m)^(\s*)release\s*\{\s*$', source)
        if not match:
            raise SystemExit('Could not locate the release buildType block in build.gradle.kts')
        indent = match.group(1) + '    '
        insert_at = match.end()
        rule = indent + 'proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")\n'
        source = source[:insert_at] + '\n' + rule + source[insert_at:]
    build.write_text(source, encoding='utf-8')
PY

cat > android/app/proguard-rules.pro <<'RULES'
-keep class net.sqlcipher.** { *; }
-dontwarn net.sqlcipher.**
RULES
