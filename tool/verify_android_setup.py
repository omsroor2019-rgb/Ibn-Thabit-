#!/usr/bin/env python3
"""Exercise the Android preparation script against a minimal Flutter scaffold."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='bin-thabit-android-check-') as temp:
    work = Path(temp)
    (work / 'tool').mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'tool/prepare_android.sh', work / 'prepare_android.sh')
    shutil.copy2(ROOT / 'tool/patch_flutter_gradle.sh', work / 'tool/patch_flutter_gradle.sh')
    shutil.copytree(ROOT / 'tool/android', work / 'tool/android')

    # Simulate the Flutter SDK Gradle build file used by Flutter 3.50.1.
    fake_flutter = work / 'fake_flutter'
    flutter_gradle = fake_flutter / 'packages/flutter_tools/gradle/build.gradle.kts'
    flutter_gradle.parent.mkdir(parents=True)
    flutter_gradle.write_text('plugins {\n    id(\"org.gradle.kotlin.kotlin-dsl\") version \"6.5.7\"\n}\n', encoding='utf-8')

    manifest = work / 'android/app/src/main/AndroidManifest.xml'
    manifest.parent.mkdir(parents=True)
    manifest.write_text('''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.binthabit.bin_thabit">
    <application android:label="bin_thabit">
        <activity android:name=".MainActivity" />
    </application>
</manifest>
''', encoding='utf-8')

    activity = work / 'android/app/src/main/kotlin/com/binthabit/bin_thabit/MainActivity.kt'
    activity.parent.mkdir(parents=True)
    activity.write_text('package com.binthabit.bin_thabit\n', encoding='utf-8')

    build = work / 'android/app/build.gradle.kts'
    build.parent.mkdir(parents=True, exist_ok=True)
    build.write_text('''android {
    defaultConfig { minSdk = flutter.minSdkVersion }
    buildTypes {
        release {
        }
    }
}
''', encoding='utf-8')

    import os
    env = os.environ.copy()
    env['FLUTTER_ROOT'] = str(fake_flutter)
    subprocess.run(['bash', 'prepare_android.sh'], cwd=work, env=env, check=True)

    assert 'version \"6.7.13\"' in flutter_gradle.read_text(encoding='utf-8')

    tree = ET.parse(manifest)
    app = tree.getroot().find('application')
    assert app is not None
    ns = '{http://schemas.android.com/apk/res/android}'
    assert app.attrib[ns + 'allowBackup'] == 'false'
    assert app.attrib[ns + 'fullBackupContent'] == '@xml/bin_thabit_backup_rules'
    assert app.attrib[ns + 'dataExtractionRules'] == '@xml/bin_thabit_data_extraction_rules'
    assert app.attrib[ns + 'usesCleartextTraffic'] == 'false'
    assert app.attrib[ns + 'label'] == 'بن ثابت'

    for name in ('bin_thabit_backup_rules.xml', 'bin_thabit_data_extraction_rules.xml'):
        ET.parse(work / 'android/app/src/main/res/xml' / name)

    kotlin = activity.read_text(encoding='utf-8')
    assert 'FLAG_SECURE' in kotlin
    gradle = build.read_text(encoding='utf-8')
    assert 'minSdk = 24' in gradle and 'proguardFiles(' in gradle
    proguard = work / 'android/app/proguard-rules.pro'
    assert proguard.exists() and 'net.sqlcipher' in proguard.read_text(encoding='utf-8')

print('PASS: Android manifest labels, cleartext, backup exclusions and device-transfer rules')
print('PASS: generated MainActivity retains FLAG_SECURE')
print('PASS: Android minSdk and SQLCipher ProGuard configuration')
print('PASS: Flutter 3.50.1 included Gradle Kotlin DSL plugin alignment')
