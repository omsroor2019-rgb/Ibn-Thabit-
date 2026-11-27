#!/usr/bin/env bash
set -euo pipefail

# Flutter 3.50.1's Android template uses AGP 9.3.1 / Gradle 9.5.0 / KGP 2.4.20.
# Its included Flutter Gradle build still requests kotlin-dsl 6.5.7 (KGP 2.3.20),
# which can fail while resolving the included build on this toolchain.
# Align the included-build Kotlin DSL plugin with KGP 2.4.x using published 6.7.13.

FLUTTER_BIN="$(command -v flutter || true)"
if [[ -z "${FLUTTER_ROOT:-}" ]]; then
  if [[ -z "$FLUTTER_BIN" ]]; then
    echo "ERROR: flutter executable was not found and FLUTTER_ROOT is not set." >&2
    exit 1
  fi
  FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
fi

GRADLE_PLUGIN_BUILD="$FLUTTER_ROOT/packages/flutter_tools/gradle/build.gradle.kts"
if [[ ! -f "$GRADLE_PLUGIN_BUILD" ]]; then
  echo "ERROR: Flutter Gradle plugin build file not found: $GRADLE_PLUGIN_BUILD" >&2
  exit 1
fi

python3 - "$GRADLE_PLUGIN_BUILD" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding='utf-8')
pattern = re.compile(
    r'(id\(\s*[\"\']org\.gradle\.kotlin\.kotlin-dsl[\"\']\s*\)\s+version\s+[\"\'])'
    r'(?P<version>[^\"\']+)'
    r'([\"\'])'
)
matches = list(pattern.finditer(source))
if len(matches) != 1:
    raise SystemExit(
        'ERROR: Expected exactly one explicit org.gradle.kotlin.kotlin-dsl plugin version '
        f'in {path}; found {len(matches)}. Refusing to modify an unknown Flutter SDK layout.'
    )

current = matches[0].group('version')
if current == '6.7.13':
    print('Flutter Gradle Kotlin DSL plugin already aligned to 6.7.13.')
elif current == '6.5.7':
    updated = pattern.sub(lambda m: m.group(1) + '6.7.13' + m.group(3), source, count=1)
    path.write_text(updated, encoding='utf-8')
    print('Updated Flutter included-build kotlin-dsl plugin: 6.5.7 -> 6.7.13.')
else:
    raise SystemExit(
        f'ERROR: Found kotlin-dsl plugin version {current!r}, not the expected 6.5.7 or 6.7.13. '
        'Refusing to change an unknown version.'
    )
PY
