---
name: smart-push
description: Stage changes, scan for leaked secrets, generate a Conventional Commit message using a fast low-cost LLM outside the main conversation context, and push to Git. Activate when the user types /smart-push or asks to smart-push without polluting the active chat context.
license: MIT
compatibility: Requires git, bash, and python3; uses any installed AI CLI (agy, claude, gemini, codex, ollama) or API key (Gemini, OpenAI, Anthropic, OpenRouter) via curl.
metadata:
  author: steierma
  version: "0.1.0"
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

If the user specifies a target subdirectory or flags:

* Target specific repository path: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --dir "<repo-path>"`
* Force Conventional Commit scope: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --scope "<scope>"`
* Commit without pushing: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --commit-only`
* Preview message without committing: `"<SKILL_DIR>/scripts/smart-push.sh" --dry-run`
* Force a specific AI provider: `"<SKILL_DIR>/scripts/smart-push.sh" --yes --provider <auto|agy|claude|gemini-cli|codex|ollama|gemini-api|openai-api|anthropic-api|openrouter-api>`

## Error Handling

* If `smart-push.sh` exits non-zero due to the **Secret Leak Guard** or a **Quality Check Hook**, report the exact blocked file/check output to the user and stop immediately. Never bypass `--no-verify` unless the user explicitly instructs you to do so.
