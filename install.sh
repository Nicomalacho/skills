#!/usr/bin/env bash
# Install a skill from this repo into ~/.claude/skills/.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Nicomalacho/skills/main/install.sh | bash
#     → installs the default skill (babysit-pr-stack)
#
#   curl -fsSL https://raw.githubusercontent.com/Nicomalacho/skills/main/install.sh | bash -s <skill-name>
#     → installs the named skill
#
#   SKILL=<skill-name> bash install.sh
#     → same, when running locally

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Nicomalacho/skills.git}"
SKILL="${1:-${SKILL:-babysit-pr-stack}}"
TARGET="${HOME}/.claude/skills/${SKILL}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Cloning ${REPO_URL}…"
git clone --depth=1 --quiet "${REPO_URL}" "${TMP}"

if [[ ! -d "${TMP}/${SKILL}" ]]; then
  echo "✗ Skill '${SKILL}' not found in repo. Available skills:" >&2
  find "${TMP}" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -exec basename {} \; | sed 's/^/    /' >&2
  exit 1
fi

mkdir -p "${HOME}/.claude/skills"

if [[ -e "${TARGET}" || -L "${TARGET}" ]]; then
  echo "→ Existing ${TARGET} — backing up to ${TARGET}.bak.$(date +%s)"
  mv "${TARGET}" "${TARGET}.bak.$(date +%s)"
fi

cp -R "${TMP}/${SKILL}" "${TARGET}"

echo "✓ Installed '${SKILL}' → ${TARGET}"
echo
echo "Restart Claude Code (or start a new session) for the skill to be picked up."
echo "Verify with: ls ${TARGET}"
