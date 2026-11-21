---
name: smart-push
description: Stage changes, scan for leaked secrets, generate a Conventional Commit message using a fast low-cost LLM outside the main conversation context, and push to Git. Activate when the user types /smart-push or asks to smart-push without polluting the active chat context.
license: MIT
compatibility: Requires git, bash, and python3; uses any installed AI CLI (agy, claude, gemini, codex, ollama) or API key (Gemini, OpenAI, Anthropic, OpenRouter) via curl.
metadata:
  author: steierma
  version: "0.1.1"
---

# Smart Push (`/smart-push`)

Commit and push Git changes using an isolated, low-cost model call **outside** your active flagship agent context window.

## Critical Context-Saving Rules (MANDATORY)

1. **NEVER run `git diff` or read modified files in the main conversation** before or during `/smart-push`. Reading diffs into the main session defeats the entire purpose of `smart-push` by permanently bloating your conversation history.
2. **Execute the bundled script in a single shell command** with `--yes` (non-interactive mode). The script handles repository root resolution, staging, secret scanning, diff compression, cheap-model commit generation, `git commit`, and `git push`.
3. **Report only the concise summary** printed by `smart-push.sh` back to the user.

## Execution

Locate `scripts/smart-push.sh` inside this skill's directory and run it against the target repository:

```bash
"<SKILL_DIR>/scripts/smart-push.sh" --yes
```

### Monorepo & Multi-Repository Workspace Rules

* **Single Active Sub-Repository:** If the workspace root is a meta-repo / multi-repo folder (containing multiple independent Git sub-repositories) and you worked on files inside a specific sub-repository during this session, **automatically pass `--dir "<subrepo-path>"`** even when the user only typed `/smart-push` without a path.
* **Multiple Modified Sub-Repositories:** If the current task modified files across multiple independent Git sub-repositories, invoke `smart-push.sh --yes --dir "<subrepo>"` separately for each modified sub-repository (never mix independent repositories).
* **Ambiguous Meta-Repo Root:** If `smart-push.sh` reports dirty sub-repositories when run from a clean parent directory and no sub-repository was active in this conversation, ask the user which listed sub-repository to push (or pass `--all-subrepos` if the user explicitly asks to push all).

### Optional Flags

* Target specific repository path: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --dir "<repo-path>"`
* Push all dirty immediate sub-repositories: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --all-subrepos`
* Force Conventional Commit scope: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --scope "<scope>"`
* Commit without pushing: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --commit-only`
* Preview message without committing: `"<SKILL_DIR>/scripts/smart-push.sh" --dry-run`
* Force a specific AI provider: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --provider <auto|agy|claude|gemini-cli|codex|ollama|gemini-api|openai-api|anthropic-api|openrouter-api>`

## Error Handling

* If `smart-push.sh` exits non-zero due to the **Secret Leak Guard** or a **Quality Check Hook**, report the exact blocked file/check output to the user and stop immediately. Never bypass `--no-verify` unless the user explicitly instructs you to do so.
