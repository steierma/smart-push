#!/usr/bin/env bash
# install.sh — Install smart-push as a global Agent Skill and/or Terminal CLI.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="${REPO_DIR}/skills/smart-push"
SCRIPT_SRC="${SKILL_SRC}/scripts/smart-push.sh"

chmod +x "$SCRIPT_SRC"

install_skill_link() {
  local target_parent="$1"
  local label="$2"
  mkdir -p "$target_parent"
  ln -sfn "$SKILL_SRC" "${target_parent}/smart-push"
  echo "[install] Linked skill for ${label}: ${target_parent}/smart-push"
}

# 1. Universal Agent Skills directory (~/.agents/skills)
install_skill_link "${HOME}/.agents/skills" "Agent Skills Standard (~/.agents/skills)"

# 2. Google Antigravity global config (if ~/.gemini/config exists)
if [[ -d "${HOME}/.gemini/config" ]]; then
  install_skill_link "${HOME}/.gemini/config/skills" "Google Antigravity"
fi

# 3. Claude Code global config (if ~/.claude exists)
if [[ -d "${HOME}/.claude" ]]; then
  install_skill_link "${HOME}/.claude/skills" "Claude Code"
fi

# 4. OpenAI Codex global config (if ~/.codex exists)
if [[ -d "${HOME}/.codex" ]]; then
  install_skill_link "${HOME}/.codex/skills" "OpenAI Codex"
fi

# 5. Terminal CLI (~/.local/bin/smart-push) + git smart-push alias
mkdir -p "${HOME}/.local/bin"
ln -sfn "$SCRIPT_SRC" "${HOME}/.local/bin/smart-push"
git config --global alias.smart-push "!${HOME}/.local/bin/smart-push"

echo "[install] CLI linked: ${HOME}/.local/bin/smart-push (and 'git smart-push')"
echo "[install] Done! Use '/smart-push' inside your AI coding agent or 'git smart-push' in any terminal."
