#!/usr/bin/env bash
# smart-push.sh — Zero-context-bloat, provider-agnostic Git commit & push engine.
# Standard: https://agentskills.io | License: MIT

set -euo pipefail

VERSION="0.1.1"
SELF_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
TARGET_DIR="."
AUTO_CONFIRM=0
ALL_SUBREPOS=0
DRY_RUN=0
COMMIT_ONLY=0
NO_VERIFY=0
PROVIDER="${SMART_PUSH_PROVIDER:-auto}"
MODEL_OVERRIDE="${SMART_PUSH_MODEL:-}"
SCOPE_HINT=""
METRICS_JSON="${SMART_PUSH_METRICS_JSON:-}"
MAX_DIFF_CHARS="${SMART_PUSH_MAX_DIFF_CHARS:-12000}"

usage() {
  cat <<'EOF'
Usage: smart-push [options] [dir]

Options:
  -y, --yes                 Non-interactive mode (commit & push without confirmation)
  -d, --dir <path>          Target Git repository path (default: current directory)
      --all-subrepos        Commit & push each dirty immediate child Git repository
  -p, --provider <name>     AI provider: auto (default), gemini-api, openai-api,
                            anthropic-api, openrouter-api, ollama, agy, claude,
                            gemini-cli, codex, copilot
  -m, --model <model>       Override default low-cost model for the chosen provider
  -s, --scope <scope>       Optional Conventional Commit scope hint (e.g. auth, api)
      --commit-only         Create the commit locally without running git push
      --dry-run             Run checks & generate commit message without committing
      --no-verify           Skip optional .smart-push-check.sh quality hook
      --metrics-json <path> Write token & timing metrics as JSON to <path>
  -v, --version             Print version and exit
  -h, --help                Show this help message
EOF
}

ORIG_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_CONFIRM=1; ORIG_ARGS+=("$1"); shift ;;
    -d|--dir) TARGET_DIR="${2:?Missing argument for --dir}"; shift 2 ;;
    --all-subrepos) ALL_SUBREPOS=1; shift ;;
    -p|--provider) PROVIDER="${2:?Missing argument for --provider}"; ORIG_ARGS+=("$1" "$2"); shift 2 ;;
    -m|--model) MODEL_OVERRIDE="${2:?Missing argument for --model}"; ORIG_ARGS+=("$1" "$2"); shift 2 ;;
    -s|--scope) SCOPE_HINT="${2:?Missing argument for --scope}"; ORIG_ARGS+=("$1" "$2"); shift 2 ;;
    --commit-only) COMMIT_ONLY=1; ORIG_ARGS+=("$1"); shift ;;
    --dry-run) DRY_RUN=1; ORIG_ARGS+=("$1"); shift ;;
    --no-verify) NO_VERIFY=1; ORIG_ARGS+=("$1"); shift ;;
    --metrics-json) METRICS_JSON="${2:?Missing argument for --metrics-json}"; shift 2 ;;
    -v|--version) echo "smart-push ${VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "[smart-push] Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      # Support positional directory argument: smart-push <path>
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

START_NS="$(python3 -c 'import time; print(time.time_ns())')"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "[smart-push] Error: directory does not exist: $TARGET_DIR" >&2
  exit 1
fi

cd "$TARGET_DIR"

# Helper: discover dirty immediate child Git repositories (monorepo / multi-repo workspace support)
find_dirty_subrepos() {
  local sub
  for sub in */; do
    [[ -d "${sub}.git" || -f "${sub}.git" ]] || continue
    if [[ -n "$(git -C "$sub" status --porcelain 2>/dev/null)" ]]; then
      echo "${sub%/}"
    fi
  done
}

run_subrepos() {
  local subrepos=("$@")
  if [[ "${#subrepos[@]}" -eq 0 ]]; then
    echo "[smart-push] Nothing to commit across child repositories."
    exit 0
  fi
  local sub
  for sub in "${subrepos[@]}"; do
    echo "[smart-push] === Sub-repository: ${sub} ==="
    "$SELF_SCRIPT" "${ORIG_ARGS[@]}" --dir "$sub"
  done
  exit 0
}

if [[ "$ALL_SUBREPOS" -eq 1 ]]; then
  mapfile -t DIRTY_SUBS < <(find_dirty_subrepos)
  run_subrepos "${DIRTY_SUBS[@]}"
fi

if ! GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  mapfile -t DIRTY_SUBS < <(find_dirty_subrepos)
  if [[ "${#DIRTY_SUBS[@]}" -gt 0 ]]; then
    if [[ "$AUTO_CONFIRM" -eq 0 && "${#DIRTY_SUBS[@]}" -eq 1 ]]; then
      printf "[smart-push] Current folder is not a Git repo, but '%s' has changes. Run there? [Y/n] " "${DIRTY_SUBS[0]}"
      read -r SUB_REPLY
      if [[ "${SUB_REPLY:-Y}" =~ ^[Yy]$|^$ ]]; then
        exec "$SELF_SCRIPT" "${ORIG_ARGS[@]}" --dir "${DIRTY_SUBS[0]}"
      fi
    fi
    echo "[smart-push] Not a Git repository ($PWD), but dirty sub-repositories were found: ${DIRTY_SUBS[*]}" >&2
    echo "[smart-push] Re-run with '--dir <subrepo>' or '--all-subrepos'." >&2
    exit 1
  fi
  echo "[smart-push] Error: not inside a Git repository ($PWD)" >&2
  exit 1
fi
cd "$GIT_ROOT"

BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD)"

# 1. Stage changes if index is currently empty; preserve partial staging if user ran git add -p.
#    Protect nested untracked Git repos from being accidentally staged as broken submodule gitlinks.
STAGED_MODE="preserved-index"
if git diff --cached --quiet; then
  if [[ -n "$(git status --porcelain)" ]]; then
    NESTED_EXCLUDES=()
    for sub in */; do
      [[ -d "${sub}.git" ]] || continue
      if git check-ignore -q "${sub%/}" 2>/dev/null; then
        continue
      fi
      if [[ ! -f .gitmodules ]] || ! grep -q "path = ${sub%/}" .gitmodules 2>/dev/null; then
        NESTED_EXCLUDES+=(":(exclude)${sub%/}")
      fi
    done
    git add -A -- . "${NESTED_EXCLUDES[@]}"
    STAGED_MODE="auto-staged-all"
  fi
fi

if git diff --cached --quiet; then
  # Check if there are unpushed local commits on current repo
  if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
    AHEAD_COUNT="$(git rev-list --count "@{u}..HEAD")"
    if [[ "$AHEAD_COUNT" -gt 0 && "$DRY_RUN" -eq 0 && "$COMMIT_ONLY" -eq 0 ]]; then
      echo "[smart-push] Working tree clean; pushing ${AHEAD_COUNT} unpushed commit(s) on ${BRANCH}..."
      git push
      exit 0
    fi
  fi
  # If root repo is clean, check whether nested sub-repositories have uncommitted changes
  mapfile -t DIRTY_SUBS < <(find_dirty_subrepos)
  if [[ "${#DIRTY_SUBS[@]}" -gt 0 ]]; then
    if [[ "$AUTO_CONFIRM" -eq 0 && "${#DIRTY_SUBS[@]}" -eq 1 ]]; then
      printf "[smart-push] Root repo is clean, but sub-repository '%s' has changes. Run there? [Y/n] " "${DIRTY_SUBS[0]}"
      read -r SUB_REPLY
      if [[ "${SUB_REPLY:-Y}" =~ ^[Yy]$|^$ ]]; then
        exec "$SELF_SCRIPT" "${ORIG_ARGS[@]}" --dir "${DIRTY_SUBS[0]}"
      fi
    fi
    echo "[smart-push] Root repository is clean, but dirty sub-repositories were found: ${DIRTY_SUBS[*]}" >&2
    echo "[smart-push] Specify '--dir <subrepo>' (or 'smart-push <subrepo>') or '--all-subrepos'." >&2
    exit 1
  fi
  echo "[smart-push] Nothing to commit (working tree clean on ${BRANCH})."
  exit 0
fi

# 2. Built-in Pre-LLM & Pre-Commit Secret Leak Guard (blocks secrets BEFORE calling any external LLM!)
check_secrets() {
  local staged_files
  staged_files="$(git diff --cached --name-only --diff-filter=ACMR)"

  # Block accidental .env commits (allow .env.example / .env.sample / .env.template)
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local base
    base="$(basename "$file")"
    if [[ "$base" == ".env" || ( "$base" == .env.* && "$base" != *.example && "$base" != *.sample && "$base" != *.template && "$base" != *.test ) ]]; then
      echo "[smart-push] BLOCKED: Staged environment file detected: ${file}" >&2
      echo "[smart-push] Unstage it with 'git reset HEAD -- ${file}' and add it to .gitignore." >&2
      exit 1
    fi
  done <<< "$staged_files"

  # Scan added lines in staged diff for high-confidence secret patterns
  if ! git diff --cached -U0 | python3 -c '
import re, sys

PATTERNS = [
    ("Private Key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----")),
    ("GitHub Token", re.compile(r"\b(?:ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,})\b")),
    ("OpenAI Key", re.compile(r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}\b")),
    ("Anthropic Key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{32,}\b")),
    ("AWS Access Key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Slack Token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{24,}\b")),
]

current_file = "<unknown>"
line_no = 0
hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)")
findings = []
for raw in sys.stdin:
    if raw.startswith("+++ b/"):
        current_file = raw[6:].strip()
        line_no = 0
        continue
    m = hunk_re.match(raw)
    if m:
        line_no = int(m.group(1))
        continue
    if not raw.startswith("+") or raw.startswith("+++"):
        continue
    line = raw[1:]
    for label, pat in PATTERNS:
        if pat.search(line):
            findings.append((current_file, line_no, label))
    line_no += 1

if findings:
    for fname, lno, label in findings[:5]:
        print(f"[smart-push] BLOCKED: Potential {label} detected in staged changes ({fname}:{lno}).", file=sys.stderr)
    sys.exit(1)
'; then
    exit 1
  fi
}

check_secrets

# 3. Optional Project Pre-Push Quality Hook
if [[ "$NO_VERIFY" -eq 0 ]]; then
  if [[ -n "${SMART_PUSH_CHECK_CMD:-}" ]]; then
    echo "[smart-push] Running SMART_PUSH_CHECK_CMD..."
    bash -c "$SMART_PUSH_CHECK_CMD"
  elif [[ -x ".smart-push-check.sh" ]]; then
    echo "[smart-push] Running .smart-push-check.sh..."
    ./.smart-push-check.sh
  fi
fi

# 4. Build Compact, Token-Efficient Diff Payload (excludes noisy lockfile bodies)
STAT_SUMMARY="$(git diff --cached --stat)"
LOCKFILE_EXCLUDES=(
  ":(exclude)package-lock.json"
  ":(exclude)pnpm-lock.yaml"
  ":(exclude)yarn.lock"
  ":(exclude)Cargo.lock"
  ":(exclude)go.sum"
  ":(exclude)pubspec.lock"
  ":(exclude)poetry.lock"
  ":(exclude)composer.lock"
)
RAW_DIFF="$(git diff --cached --no-color --unified=2 -- . "${LOCKFILE_EXCLUDES[@]}")"
DIFF_CHARS="${#RAW_DIFF}"
if [[ "$DIFF_CHARS" -gt "$MAX_DIFF_CHARS" ]]; then
  RAW_DIFF="${RAW_DIFF:0:$MAX_DIFF_CHARS}
... [diff truncated at ${MAX_DIFF_CHARS} chars; see --stat summary above for full file list]"
fi

SCOPE_INSTRUCTION=""
if [[ -n "$SCOPE_HINT" ]]; then
  SCOPE_INSTRUCTION="Use scope '(${SCOPE_HINT})'."
fi

SYSTEM_PROMPT="You are a Git commit message generator. Output ONLY a single-line Conventional Commit message: <type>(<optional-scope>): <imperative summary>. Allowed types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert. Max 72 characters, lowercase summary, no trailing period, no markdown, no backticks, no explanation. ${SCOPE_INSTRUCTION}"

USER_PAYLOAD="Branch: ${BRANCH}
Staged summary:
${STAT_SUMMARY}

Diff:
${RAW_DIFF}"

# Metrics variables populated by provider call
USED_PROVIDER=""
USED_MODEL=""
INPUT_TOKENS=0
CACHE_READ_TOKENS=0
OUTPUT_TOKENS=0
RAW_MSG=""

# 5. Provider Execution Implementations
call_gemini_api() {
  local model="${MODEL_OVERRIDE:-gemini-2.5-flash-lite}"
  local resp
  resp="$(python3 - "$SYSTEM_PROMPT" "$USER_PAYLOAD" "$model" <<'PY'
import json, os, sys, urllib.request

sys_prompt, payload, model = sys.argv[1], sys.argv[2], sys.argv[3]
api_key = os.environ["GEMINI_API_KEY"]
url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
body = json.dumps({
    "system_instruction": {"parts": [{"text": sys_prompt}]},
    "contents": [{"parts": [{"text": payload}]}],
    "generationConfig": {"temperature": 0.1, "maxOutputTokens": 80},
}).encode("utf-8")
req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=20) as r:
    data = json.loads(r.read().decode("utf-8"))
text = data["candidates"][0]["content"]["parts"][0]["text"].strip()
usage = data.get("usageMetadata", {})
print(json.dumps({
    "msg": text,
    "model": model,
    "input_tokens": usage.get("promptTokenCount", 0),
    "cache_read_tokens": usage.get("cachedContentTokenCount", 0),
    "output_tokens": usage.get("candidatesTokenCount", 0),
}))
PY
)"
  USED_PROVIDER="gemini-api"
  parse_provider_json "$resp"
}

call_openai_compatible_api() {
  local provider_label="$1"
  local base_url="$2"
  local api_key_env="$3"
  local default_model="$4"
  local model="${MODEL_OVERRIDE:-$default_model}"
  local resp
  resp="$(python3 - "$SYSTEM_PROMPT" "$USER_PAYLOAD" "$base_url" "$api_key_env" "$model" <<'PY'
import json, os, sys, urllib.request

sys_prompt, payload, base_url, key_env, model = sys.argv[1:6]
api_key = os.environ[key_env]
url = base_url.rstrip("/") + "/chat/completions"
body = json.dumps({
    "model": model,
    "temperature": 0.1,
    "max_tokens": 80,
    "messages": [
        {"role": "system", "content": sys_prompt},
        {"role": "user", "content": payload},
    ],
}).encode("utf-8")
req = urllib.request.Request(
    url,
    data=body,
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    },
)
with urllib.request.urlopen(req, timeout=20) as r:
    data = json.loads(r.read().decode("utf-8"))
text = data["choices"][0]["message"]["content"].strip()
usage = data.get("usage", {})
print(json.dumps({
    "msg": text,
    "model": model,
    "input_tokens": usage.get("prompt_tokens", 0),
    "cache_read_tokens": 0,
    "output_tokens": usage.get("completion_tokens", 0),
}))
PY
)"
  USED_PROVIDER="$provider_label"
  parse_provider_json "$resp"
}

call_anthropic_api() {
  local model="${MODEL_OVERRIDE:-claude-3-5-haiku-latest}"
  local resp
  resp="$(python3 - "$SYSTEM_PROMPT" "$USER_PAYLOAD" "$model" <<'PY'
import json, os, sys, urllib.request

sys_prompt, payload, model = sys.argv[1], sys.argv[2], sys.argv[3]
api_key = os.environ["ANTHROPIC_API_KEY"]
body = json.dumps({
    "model": model,
    "max_tokens": 80,
    "temperature": 0.1,
    "system": sys_prompt,
    "messages": [{"role": "user", "content": payload}],
}).encode("utf-8")
req = urllib.request.Request(
    "https://api.anthropic.com/v1/messages",
    data=body,
    headers={
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    },
)
with urllib.request.urlopen(req, timeout=20) as r:
    data = json.loads(r.read().decode("utf-8"))
text = data["content"][0]["text"].strip()
usage = data.get("usage", {})
print(json.dumps({
    "msg": text,
    "model": model,
    "input_tokens": usage.get("input_tokens", 0),
    "cache_read_tokens": usage.get("cache_read_input_tokens", 0),
    "output_tokens": usage.get("output_tokens", 0),
}))
PY
)"
  USED_PROVIDER="anthropic-api"
  parse_provider_json "$resp"
}

call_ollama() {
  local host="${OLLAMA_HOST:-http://127.0.0.1:11434}"
  local model="${MODEL_OVERRIDE:-qwen2.5-coder:3b}"
  local resp
  resp="$(python3 - "$SYSTEM_PROMPT" "$USER_PAYLOAD" "$host" "$model" <<'PY'
import json, sys, urllib.request

sys_prompt, payload, host, model = sys.argv[1:5]
url = host.rstrip("/") + "/api/generate"
body = json.dumps({
    "model": model,
    "system": sys_prompt,
    "prompt": payload,
    "stream": False,
    "options": {"temperature": 0.1, "num_predict": 80},
}).encode("utf-8")
req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=30) as r:
    data = json.loads(r.read().decode("utf-8"))
print(json.dumps({
    "msg": data.get("response", "").strip(),
    "model": model,
    "input_tokens": data.get("prompt_eval_count", 0),
    "cache_read_tokens": 0,
    "output_tokens": data.get("eval_count", 0),
}))
PY
)"
  USED_PROVIDER="ollama"
  parse_provider_json "$resp"
}

call_agy_cli() {
  local model="${MODEL_OVERRIDE:-gemini-3.8-flash-low}"
  local full_prompt="${SYSTEM_PROMPT}
CRITICAL: Do NOT call any tools or shell commands. Everything you need is below. Reply immediately in 1 turn with ONLY the commit message line.

${USER_PAYLOAD}"
  local json_out
  json_out="$(agy -p "$full_prompt" --model "$model" --effort low --disable-slash-commands --output-format json)"
  local parsed
  parsed="$(python3 - "$json_out" "$model" <<'PY'
import json, sys
raw, model = sys.argv[1], sys.argv[2]
# Locate final JSON line in case spinner characters preceded stdout
lines = [ln.strip() for ln in raw.splitlines() if ln.strip().startswith("{")]
data = json.loads(lines[-1])
usage = data.get("usage", {})
print(json.dumps({
    "msg": data.get("response", "").strip(),
    "model": model,
    "input_tokens": usage.get("input_tokens", 0),
    "cache_read_tokens": usage.get("cache_read_tokens", 0),
    "output_tokens": usage.get("output_tokens", 0),
}))
PY
)"
  USED_PROVIDER="agy"
  parse_provider_json "$parsed"
}

call_claude_cli() {
  local model="${MODEL_OVERRIDE:-haiku}"
  local full_prompt="${SYSTEM_PROMPT}
CRITICAL: Do NOT use any tools. Reply immediately with ONLY the single-line commit message.

${USER_PAYLOAD}"
  local out
  out="$(claude -p "$full_prompt" --model "$model" --tools "")"
  USED_PROVIDER="claude"
  USED_MODEL="$model"
  RAW_MSG="$out"
}

call_gemini_cli() {
  local model="${MODEL_OVERRIDE:-gemini-2.5-flash}"
  local full_prompt="${SYSTEM_PROMPT}

${USER_PAYLOAD}"
  local out
  out="$(gemini -p "$full_prompt" -m "$model")"
  USED_PROVIDER="gemini-cli"
  USED_MODEL="$model"
  RAW_MSG="$out"
}

call_codex_cli() {
  local full_prompt="${SYSTEM_PROMPT}

${USER_PAYLOAD}"
  local out
  out="$(codex exec "$full_prompt")"
  USED_PROVIDER="codex"
  USED_MODEL="${MODEL_OVERRIDE:-codex-mini}"
  RAW_MSG="$out"
}

call_copilot_cli() {
  local model="${MODEL_OVERRIDE:-gpt-4.1}"
  local full_prompt="${SYSTEM_PROMPT}
CRITICAL: Do NOT call any tools or shell commands. Everything you need is below. Reply immediately in 1 turn with ONLY the single-line commit message.

${USER_PAYLOAD}"
  local out
  if [[ -n "$MODEL_OVERRIDE" ]]; then
    out="$(copilot -p "$full_prompt" --model "$model" --silent)"
  elif ! out="$(copilot -p "$full_prompt" --model "$model" --silent 2>/dev/null)" || [[ -z "${out//[$' \t\r\n']/}" ]]; then
    out="$(copilot -p "$full_prompt" --silent)"
    model="default"
  fi
  USED_PROVIDER="copilot"
  USED_MODEL="$model"
  RAW_MSG="$out"
}

call_mock_provider() {
  USED_PROVIDER="mock"
  USED_MODEL="mock-deterministic"
  INPUT_TOKENS=120
  CACHE_READ_TOKENS=0
  OUTPUT_TOKENS=8
  RAW_MSG="${SMART_PUSH_MOCK_MSG:-chore: update repository files}"
}

parse_provider_json() {
  local json_payload="$1"
  eval "$(python3 - "$json_payload" <<'PY'
import json, shlex, sys
d = json.loads(sys.argv[1])
print(f"RAW_MSG={shlex.quote(d.get('msg', ''))}")
print(f"USED_MODEL={shlex.quote(str(d.get('model', '')))}")
print(f"INPUT_TOKENS={int(d.get('input_tokens', 0))}")
print(f"CACHE_READ_TOKENS={int(d.get('cache_read_tokens', 0))}")
print(f"OUTPUT_TOKENS={int(d.get('output_tokens', 0))}")
PY
)"
}

select_and_generate() {
  case "$PROVIDER" in
    mock) call_mock_provider ;;
    gemini-api) call_gemini_api ;;
    openai-api) call_openai_compatible_api "openai-api" "${OPENAI_BASE_URL:-https://api.openai.com/v1}" "OPENAI_API_KEY" "gpt-4o-mini" ;;
    openrouter-api) call_openai_compatible_api "openrouter-api" "https://openrouter.ai/api/v1" "OPENROUTER_API_KEY" "google/gemini-2.5-flash-lite" ;;
    anthropic-api) call_anthropic_api ;;
    ollama) call_ollama ;;
    agy) call_agy_cli ;;
    claude) call_claude_cli ;;
    gemini-cli) call_gemini_cli ;;
    codex) call_codex_cli ;;
    copilot) call_copilot_cli ;;
    auto)
      if [[ -n "${GEMINI_API_KEY:-}" ]]; then
        call_gemini_api
      elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
        call_openai_compatible_api "openai-api" "${OPENAI_BASE_URL:-https://api.openai.com/v1}" "OPENAI_API_KEY" "gpt-4o-mini"
      elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        call_anthropic_api
      elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
        call_openai_compatible_api "openrouter-api" "https://openrouter.ai/api/v1" "OPENROUTER_API_KEY" "google/gemini-2.5-flash-lite"
      elif command -v agy >/dev/null 2>&1; then
        call_agy_cli
      elif command -v claude >/dev/null 2>&1; then
        call_claude_cli
      elif command -v gemini >/dev/null 2>&1; then
        call_gemini_cli
      elif command -v codex >/dev/null 2>&1; then
        call_codex_cli
      elif command -v copilot >/dev/null 2>&1; then
        call_copilot_cli
      elif command -v ollama >/dev/null 2>&1; then
        call_ollama
      else
        echo "[smart-push] Error: No AI CLI (agy, claude, gemini, codex, copilot, ollama) or API key (GEMINI_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, OPENROUTER_API_KEY) found." >&2
        exit 1
      fi
      ;;
    *)
      echo "[smart-push] Error: Unsupported provider '${PROVIDER}'." >&2
      exit 2
      ;;
  esac
}

select_and_generate

# 6. Sanitize & Enforce Conventional Commit Format
COMMIT_MSG="$(python3 - "$RAW_MSG" "$SCOPE_HINT" <<'PY'
import re, sys

raw = sys.argv[1].strip()
scope_hint = sys.argv[2].strip()

# Strip markdown fences and surrounding quotes/backticks
lines = [ln.strip().strip("`\"'") for ln in raw.splitlines() if ln.strip() and not ln.strip().startswith("```")]
candidate = lines[0] if lines else ""

cc_re = re.compile(r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_./-]+\))?!?:\s+.+")
if not cc_re.match(candidate):
    # Extract if embedded later in lines
    for ln in lines:
        if cc_re.match(ln):
            candidate = ln
            break
    else:
        prefix = f"chore({scope_hint})" if scope_hint else "chore"
        cleaned = re.sub(r"\s+", " ", candidate).strip(" .") or "update project files"
        candidate = f"{prefix}: {cleaned[:60]}"

# Enforce max 72 chars cleanly without trailing period
candidate = candidate.rstrip(".")
if len(candidate) > 72:
    candidate = candidate[:69].rstrip() + "..."

print(candidate)
PY
)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  END_NS="$(python3 -c 'import time; print(time.time_ns())')"
  DURATION_MS=$(( (END_NS - START_NS) / 1000000 ))
  echo "[smart-push] Dry-run (${USED_PROVIDER}/${USED_MODEL}, ${DURATION_MS}ms, in=${INPUT_TOKENS} cache=${CACHE_READ_TOKENS} out=${OUTPUT_TOKENS}):"
  echo "  ${COMMIT_MSG}"
  if [[ -n "$METRICS_JSON" ]]; then
    python3 - "$METRICS_JSON" "$USED_PROVIDER" "$USED_MODEL" "$DURATION_MS" "$DIFF_CHARS" "$INPUT_TOKENS" "$CACHE_READ_TOKENS" "$OUTPUT_TOKENS" "" "$COMMIT_MSG" <<'PY'
import json, sys
path, prov, mod, dur, dchars, inp, cache, out, sha, msg = sys.argv[1:11]
with open(path, "w", encoding="utf-8") as f:
    json.dump({
        "dry_run": True,
        "provider": prov,
        "model": mod,
        "duration_ms": int(dur),
        "diff_chars": int(dchars),
        "input_tokens": int(inp),
        "cache_read_tokens": int(cache),
        "output_tokens": int(out),
        "commit_sha": sha,
        "commit_message": msg,
    }, f, indent=2)
PY
  fi
  exit 0
fi

# 7. Interactive Confirmation (unless --yes)
if [[ "$AUTO_CONFIRM" -eq 0 ]]; then
  echo "[smart-push] Proposed commit (${USED_PROVIDER}/${USED_MODEL}):"
  echo "  ${COMMIT_MSG}"
  printf "Proceed with commit%s? [Y/n/e(dit)] " "$( [[ "$COMMIT_ONLY" -eq 1 ]] && echo "" || echo " & push" )"
  read -r REPLY
  case "${REPLY:-Y}" in
    [Yy]*|"") ;;
    [Ee]*)
      printf "Enter commit message: "
      read -r EDITED_MSG
      [[ -n "$EDITED_MSG" ]] && COMMIT_MSG="$EDITED_MSG"
      ;;
    *)
      echo "[smart-push] Aborted."
      exit 1
      ;;
  esac
fi

git commit -m "$COMMIT_MSG" >/dev/null
COMMIT_SHA="$(git rev-parse --short HEAD)"

PUSH_STATE="local-only"
if [[ "$COMMIT_ONLY" -eq 0 ]]; then
  if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
    git push >/dev/null 2>&1
  else
    git push -u origin "$BRANCH" >/dev/null 2>&1
  fi
  PUSH_STATE="pushed -> origin/${BRANCH}"
fi

END_NS="$(python3 -c 'import time; print(time.time_ns())')"
DURATION_MS=$(( (END_NS - START_NS) / 1000000 ))

if [[ -n "$METRICS_JSON" ]]; then
  python3 - "$METRICS_JSON" "$USED_PROVIDER" "$USED_MODEL" "$DURATION_MS" "$DIFF_CHARS" "$INPUT_TOKENS" "$CACHE_READ_TOKENS" "$OUTPUT_TOKENS" "$COMMIT_SHA" "$COMMIT_MSG" <<'PY'
import json, sys
path, prov, mod, dur, dchars, inp, cache, out, sha, msg = sys.argv[1:11]
with open(path, "w", encoding="utf-8") as f:
    json.dump({
        "dry_run": False,
        "provider": prov,
        "model": mod,
        "duration_ms": int(dur),
        "diff_chars": int(dchars),
        "input_tokens": int(inp),
        "cache_read_tokens": int(cache),
        "output_tokens": int(out),
        "commit_sha": sha,
        "commit_message": msg,
    }, f, indent=2)
PY
fi

echo "[smart-push] ${COMMIT_SHA} (${PUSH_STATE}, ${USED_PROVIDER}/${USED_MODEL}, ${DURATION_MS}ms): ${COMMIT_MSG}"
