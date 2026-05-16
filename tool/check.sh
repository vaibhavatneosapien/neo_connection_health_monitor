#!/usr/bin/env bash
#
# tool/check.sh — local + CI quality gate for neo_connection_health_monitor.
#
# Runs the three checks the package contract guarantees:
#   1. dart format --set-exit-if-changed .   (formatting drift fails the build)
#   2. dart analyze --fatal-infos            (any analyzer info/warning fails the build)
#   3. dart test                             (unit suite must pass)
#
# Invoked by .github/workflows/dart.yml and recommended as a pre-commit hook.

set -euo pipefail

echo "==> step 1: dart format --set-exit-if-changed ."
dart format --set-exit-if-changed .

echo "==> step 2: dart analyze --fatal-infos"
dart analyze --fatal-infos

echo "==> step 3: dart test"
dart test
