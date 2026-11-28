#!/usr/bin/env python3
"""Verify Android preparation without changing the installed Flutter SDK."""
from pathlib import Path
import os
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

    # Provide a minimal Flutter SDK tree. The preparation script must not edit it.
    fake_flutter = work / 'fake_flutter'
    flutter_gradle = fake_flutter / 'packages/flutter_tools/gradle/build.gradle.kts'
    flutter_gradle.parent.mkdir(parents=True)
    original_flutter_gradle = (
        'plugins {\n'
        '    id("org.gradle.kotlin.kotlin-dsl") version "6.5.7"\n'
        '}\n'
    )
    flutter_gradle.write_text(original_flutter_gradle, encoding='utf-8')

    # Prepare a minimal Android scaffold first so this test does not invoke
    # `flutter create` or depend on network access / a globally installed SDK.
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

    env = os.environ.copy()
    env['FLUTTER_ROOT'] = str(fake_flutter)
    env['GRADLE_USER_HOME'] = str(work / 'gradle-home')
    subprocess.run(['bash', 'prepare_android.sh'], cwd=work, env=env, check=True)

    # The old check incorrectly expected a hard-coded Kotlin DSL version in
    # the Flutter SDK. The current strategy intentionally leaves that SDK file
    # untouched and configures plugin resolution through a Gradle init script.
    assert flutter_gradle.read_text(encoding='utf-8') == original_flutter_gradle, (
        'Flutter SDK Gradle files must remain unchanged'
    )

    init_script = work / 'gradle-home/init.d/00-flutter-plugin-repositories.gradle'
    assert init_script.is_file(), 'Gradle plugin repository init script was not created'
    init_text = init_script.read_text(encoding='utf-8')
    for required in (
        'gradlePluginPortal()',
        'google()',
        'mavenCentral()',
        'resolutionStrategy.eachPlugin',
        "requestedPlugin.id.id == 'org.gradle.kotlin.kotlin-dsl'",
        'details.useModule("org.gradle.kotlin:gradle-kotlin-dsl-plugins:${requestedPlugin.version}")',
    ):
        assert required in init_text, f'Missing Gradle plugin-resolution setting: {required}'

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

print('PASS: Gradle plugin repositories and Kotlin DSL module mapping are configured')
print('PASS: Flutter SDK Gradle files remain unchanged')
print('PASS: Android manifest labels, cleartext, backup exclusions and device-transfer rules')
print('PASS: generated MainActivity retains FLAG_SECURE')
print('PASS: Android minSdk and SQLCipher ProGuard configuration')
