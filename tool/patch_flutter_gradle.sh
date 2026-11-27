#!/usr/bin/env bash
set -euo pipefail

# Flutter 3.50 uses the `kotlin-dsl` plugin alias in its included Gradle build.
# The alias resolves to org.gradle.kotlin.kotlin-dsl with the version tied to
# the Gradle distribution. Do not rewrite Flutter SDK files or force a different
# Kotlin DSL version. Resolve the implementation module directly to avoid a
# failing plugin-marker lookup, using only official Google/Maven Central/Gradle
# Plugin Portal repositories.

GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
INIT_DIR="$GRADLE_USER_HOME/init.d"
INIT_FILE="$INIT_DIR/00-flutter-plugin-repositories.gradle"

mkdir -p "$INIT_DIR"

cat > "$INIT_FILE" <<'GRADLE'
gradle.beforeSettings { settings ->
    settings.pluginManagement.repositories {
        // Official repositories. Plugin Portal first for Gradle-owned plugins.
        gradlePluginPortal()
        google()
        mavenCentral()
    }

    settings.pluginManagement.resolutionStrategy.eachPlugin { details ->
        def requestedPlugin = details.requested
        if (requestedPlugin.id.id == 'org.gradle.kotlin.kotlin-dsl' &&
            requestedPlugin.version != null &&
            !requestedPlugin.version.trim().isEmpty()) {
            // Resolve the implementation module directly, keeping the exact
            // version selected by the active Gradle distribution.
            details.useModule("org.gradle.kotlin:gradle-kotlin-dsl-plugins:${requestedPlugin.version}")
        }
    }
}
GRADLE

printf 'Configured official Gradle Kotlin DSL plugin resolution in %s\n' "$INIT_FILE"
printf 'The Flutter SDK is not modified and no plugin version is overridden.\n'
