#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for package in packages/phomemo_t02 apps/t02_demo; do
  (
    cd "$project_root/$package"
    printf '\nChecking %s\n' "$package"
    flutter pub get
    dart format --output=none --set-exit-if-changed lib test
    flutter analyze
    flutter test --reporter expanded
  )
done
