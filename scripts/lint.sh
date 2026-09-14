#!/usr/bin/env bash
# Formatting check with the toolchain's swift-format (config: .swift-format). `--fix` rewrites in place.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [ "${1:-}" = "--fix" ]; then
  swift format format --in-place --recursive Sources Tests Package.swift
fi
swift format lint --strict --recursive Sources Tests Package.swift
