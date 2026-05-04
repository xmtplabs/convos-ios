#!/usr/bin/env bash

# Builds the convos-shared metrics gradle project, which generates the
# NavigationMetrics Swift package, and mirrors it to a stable location
# under the repo root so SPM can reference it via a fixed path.
#
# Gradle output (volatile, cleared by `gradle clean`):
#   convos-shared/metrics/descriptors/build/generated/ksp/main/resources/swift/
#
# Stable mirror (consumed by ConvosCore/Package.swift):
#   NavigationMetrics/
#     Package.swift
#     Sources/NavigationMetrics/*.swift

set -e
set -o pipefail

if [ -n "${SRCROOT}" ]; then
    REPO_ROOT="${SRCROOT}"
else
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

SUBMODULE_DIR="${REPO_ROOT}/convos-shared"
METRICS_DIR="${SUBMODULE_DIR}/metrics"
GRADLE_OUTPUT="${METRICS_DIR}/descriptors/build/generated/ksp/main/resources/swift"
DEST_DIR="${REPO_ROOT}/NavigationMetrics"

if [ ! -f "${METRICS_DIR}/settings.gradle.kts" ]; then
    echo "convos-shared submodule not initialized; running git submodule update --init"
    git -C "${REPO_ROOT}" submodule update --init --recursive convos-shared
fi

if [ ! -x "${METRICS_DIR}/gradlew" ]; then
    echo "error: ${METRICS_DIR}/gradlew not found or not executable" >&2
    exit 1
fi

(cd "${METRICS_DIR}" && ./gradlew :descriptors:build --console=plain)

if [ ! -f "${GRADLE_OUTPUT}/Package.swift" ]; then
    echo "error: gradle build did not produce ${GRADLE_OUTPUT}/Package.swift" >&2
    exit 1
fi

mkdir -p "${DEST_DIR}/Sources/NavigationMetrics"
rsync -a --delete \
    "${GRADLE_OUTPUT}/Package.swift" \
    "${DEST_DIR}/Package.swift"
rsync -a --delete \
    "${GRADLE_OUTPUT}/Sources/NavigationMetrics/" \
    "${DEST_DIR}/Sources/NavigationMetrics/"
