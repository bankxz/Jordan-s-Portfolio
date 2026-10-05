#!/usr/bin/env bash
# Installs the RBX Pulse skill packs into Claude Code (project scope).
# .claude/settings.json already declares them; trusting the project in Claude Code
# prompts the same install. Use this script for a non-interactive setup.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v claude >/dev/null 2>&1; then
  echo "error: Claude Code CLI ('claude') not found on PATH" >&2
  exit 1
fi

claude plugin marketplace add Prisma-Labs-Dev/apple-skills
claude plugin marketplace add mtfum/openai-build-ios-skills

claude plugin install apple-skills@apple-skills --scope project
claude plugin install build-ios-apps@openai-build-ios-skills --scope project

if [[ "$(uname)" != "Darwin" ]]; then
  echo "note: not macOS — XcodeBuildMCP / ios-debugger-agent, ETTrace and memgraph skills need macOS + Xcode."
elif ! command -v xcodebuild >/dev/null 2>&1; then
  echo "note: xcodebuild not found — install Xcode for Simulator-based skills."
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "note: npx not found — install Node.js; build-ios-apps starts XcodeBuildMCP via npx."
fi

echo "Done. Run 'claude plugin list' to confirm."
