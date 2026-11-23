#!/usr/bin/env bash
# Automated test suite for smart-push.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMART_PUSH="${REPO_ROOT}/skills/smart-push/scripts/smart-push.sh"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1" >&2; exit 1; }

setup_fixture_repo() {
  local dir="$1"
  local remote="${dir}-remote.git"
  git init --bare -b main "$remote" >/dev/null
  git init -b main "$dir" >/dev/null
  git -C "$dir" config user.name "Test Bot"
  git -C "$dir" config user.email "bot@example.com"
  git -C "$dir" remote add origin "$remote"
}

# Test 1: Commit + Push with mock provider & metrics JSON
T1="${TMP_BASE}/t1"
setup_fixture_repo "$T1"
echo "export const add = (a, b) => a + b;" > "${T1}/math.js"
SMART_PUSH_MOCK_MSG='```
feat(math): add addition helper.
```' "$SMART_PUSH" --yes --dir "$T1" --provider mock --metrics-json "${T1}/metrics.json" >/dev/null

LAST_MSG="$(git -C "$T1" log -1 --pretty=%s)"
[[ "$LAST_MSG" == "feat(math): add addition helper" ]] || fail "Expected sanitized message, got: $LAST_MSG"
REMOTE_HEAD="$(git --git-dir="${T1}-remote.git" log -1 --pretty=%s)"
[[ "$REMOTE_HEAD" == "feat(math): add addition helper" ]] || fail "Expected remote push, got: $REMOTE_HEAD"
[[ -f "${T1}/metrics.json" ]] || fail "Expected metrics.json to be written"
pass "Sanitizes markdown/period, commits, pushes to origin, and writes metrics JSON"

# Test 2: Secret Leak Guard blocks staged GitHub token BEFORE calling provider
T2="${TMP_BASE}/t2"
setup_fixture_repo "$T2"
# Construct synthetic token at runtime so static secret scanners do not flag this test file
FAKE_PAT="ghp_$(printf '1%.0s' {1..36})"
echo "TOKEN=${FAKE_PAT}" > "${T2}/config.txt"
if "$SMART_PUSH" --yes --dir "$T2" --provider mock >/dev/null 2>&1; then
  fail "Expected secret leak guard to block fake GitHub PAT"
fi
pass "Secret Leak Guard blocks staged tokens before LLM call or commit"

# Test 3: Secret Leak Guard blocks .env files while allowing .env.example
T3="${TMP_BASE}/t3"
setup_fixture_repo "$T3"
echo "API_URL=https://api.example.com" > "${T3}/.env.example"
"$SMART_PUSH" --yes --dir "$T3" --provider mock >/dev/null
echo "SECRET=topsecret" > "${T3}/.env"
if "$SMART_PUSH" --yes --dir "$T3" --provider mock >/dev/null 2>&1; then
  fail "Expected .env file to be blocked"
fi
pass "Secret Leak Guard allows .env.example and blocks .env"

# Test 4: Preserves partial staging when user already ran git add
T4="${TMP_BASE}/t4"
setup_fixture_repo "$T4"
echo "staged" > "${T4}/a.txt"
echo "unstaged" > "${T4}/b.txt"
git -C "$T4" add a.txt
SMART_PUSH_MOCK_MSG="feat: add file a" "$SMART_PUSH" --yes --dir "$T4" --provider mock >/dev/null
[[ -z "$(git -C "$T4" ls-files b.txt)" ]] || fail "Expected unstaged b.txt not to be committed when index was non-empty"
pass "Preserves partial git index when files are already staged"

# Test 5: Multi-repo / Monorepo safety & --all-subrepos support
T5="${TMP_BASE}/t5-meta"
setup_fixture_repo "$T5"
echo "/*
!/.gitignore" > "${T5}/.gitignore"
SMART_PUSH_MOCK_MSG="chore: init meta repo" "$SMART_PUSH" --yes --dir "$T5" --provider mock >/dev/null

setup_fixture_repo "${T5}/service-a"
setup_fixture_repo "${T5}/service-b"
echo "package a" > "${T5}/service-a/main.go"
echo "package b" > "${T5}/service-b/main.go"

# Running in --yes mode on clean parent must NOT silently guess; it must report dirty sub-repos
if "$SMART_PUSH" --yes --dir "$T5" --provider mock >/dev/null 2>&1; then
  fail "Expected clean meta-repo root with dirty subrepos to prompt/exit in non-interactive mode without --dir"
fi

# Positional subrepo path works: smart-push <path>
SMART_PUSH_MOCK_MSG="feat(a): init service a" "$SMART_PUSH" --yes --provider mock "${T5}/service-a" >/dev/null
[[ "$(git --git-dir="${T5}/service-a-remote.git" log -1 --pretty=%s)" == "feat(a): init service a" ]] || fail "Positional path push failed"

# --all-subrepos commits & pushes remaining dirty child repos independently
SMART_PUSH_MOCK_MSG="feat(b): init service b" "$SMART_PUSH" --yes --dir "$T5" --all-subrepos --provider mock >/dev/null
[[ "$(git --git-dir="${T5}/service-b-remote.git" log -1 --pretty=%s)" == "feat(b): init service b" ]] || fail "--all-subrepos push failed"
pass "Handles multi-repo / monorepo boundaries, positional paths, and --all-subrepos safely"

# Test 6: SKILL.md frontmatter is strict, flat, and Copilot-compatible
SKILL_MD="${REPO_ROOT}/skills/smart-push/SKILL.md"
python3 - "$SKILL_MD" <<'PY' || fail "SKILL.md frontmatter validation failed"
import pathlib
import re
import sys

skill_path = pathlib.Path(sys.argv[1])
raw = skill_path.read_bytes()

assert raw.startswith(b"---\n"), "SKILL.md must start at byte 0 with '---\\n' (no BOM, whitespace, or CRLF)"
assert b"\r\n" not in raw, "SKILL.md must use LF line endings, not CRLF"

text = raw.decode("utf-8")
lines = text.splitlines()
end_idx = None
for i in range(1, len(lines)):
    if lines[i] == "---":
        end_idx = i
        break
assert end_idx is not None, "Missing closing '---' frontmatter delimiter"

fm_lines = lines[1:end_idx]
assert fm_lines, "Frontmatter must not be empty"

fields = {}
for line in fm_lines:
    assert not line.startswith((" ", "\t")), f"Indented/nested YAML line not allowed for Copilot compatibility: {line!r}"
    assert ":" in line, f"Malformed frontmatter line (missing ':'): {line!r}"
    key, val = line.split(":", 1)
    key = key.strip()
    val = val.strip()
    assert val != "", f"Empty-value block header not allowed in frontmatter: {key!r}"
    fields[key] = val

parent_dir = skill_path.parent.name
name = fields.get("name", "").strip("\"'")
assert name == parent_dir, f"name {name!r} must match parent directory {parent_dir!r}"
assert len(name) <= 64, "name must be <= 64 chars"
assert re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name), f"Invalid kebab-case name: {name!r}"

desc = fields.get("description", "")
assert desc, "description is required"
unquoted_desc = desc.strip("\"'")
assert 0 < len(unquoted_desc) <= 1024, "description must be 1..1024 chars"
if not ((desc.startswith('"') and desc.endswith('"')) or (desc.startswith("'") and desc.endswith("'"))):
    assert ": " not in desc, "Unquoted description must not contain ': '"

if "compatibility" in fields:
    compat = fields["compatibility"]
    assert len(compat.strip("\"'")) <= 500, "compatibility must be <= 500 chars"
    if not ((compat.startswith('"') and compat.endswith('"')) or (compat.startswith("'") and compat.endswith("'"))):
        assert ": " not in compat, "Unquoted compatibility must not contain ': '"

try:
    import yaml  # type: ignore
except ImportError:
    yaml = None

if yaml is not None:
    parsed = yaml.safe_load("\n".join(fm_lines))
    assert isinstance(parsed, dict), "PyYAML must parse frontmatter as a mapping"
    assert parsed.get("name") == name, "PyYAML parsed name mismatch"
    assert parsed.get("description") == unquoted_desc, "PyYAML parsed description mismatch"
PY
pass "SKILL.md frontmatter is flat, UTF-8 without BOM, and Copilot-compatible"

# Test 7: GitHub Copilot CLI provider support (explicit, --model override, fallback, and auto)
COPILOT_BIN="${TMP_BASE}/copilot-only-bin"
mkdir -p "$COPILOT_BIN"
for cmd in env bash dirname basename python3 git grep; do
  resolved="$(command -v "$cmd")"
  ln -s "$resolved" "${COPILOT_BIN}/${cmd}"
done

cat > "${COPILOT_BIN}/copilot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

has_prompt=0
has_silent=0
model=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prompt)
      has_prompt=1
      shift 2
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --silent|-s)
      has_silent=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$has_prompt" -ne 1 || "$has_silent" -ne 1 ]]; then
  echo "copilot stub: missing -p or --silent" >&2
  exit 2
fi

if [[ -n "${COPILOT_LOG:-}" ]]; then
  echo "model=${model:-<none>} silent=${has_silent}" >> "$COPILOT_LOG"
fi

if [[ -n "${COPILOT_FAIL_MODEL:-}" && "$model" == "${COPILOT_FAIL_MODEL}" ]]; then
  echo "copilot stub: model ${model} unavailable" >&2
  exit 1
fi

echo "${COPILOT_MOCK_MSG:-feat(copilot): generate commit via copilot cli}"
EOF
chmod +x "${COPILOT_BIN}/copilot"

T7="${TMP_BASE}/t7"
setup_fixture_repo "$T7"

# 7a: Explicit --provider copilot uses default gpt-4.1
echo "console.log('a');" > "${T7}/a.js"
COPILOT_LOG="${T7}/copilot.log" PATH="$COPILOT_BIN" \
  "$SMART_PUSH" --yes --dir "$T7" --provider copilot --metrics-json "${T7}/metrics-7a.json" >/dev/null
[[ "$(git -C "$T7" log -1 --pretty=%s)" == "feat(copilot): generate commit via copilot cli" ]] || fail "7a: local commit mismatch"
[[ "$(git --git-dir="${T7}-remote.git" log -1 --pretty=%s)" == "feat(copilot): generate commit via copilot cli" ]] || fail "7a: remote commit mismatch"
grep -q "model=gpt-4.1 silent=1" "${T7}/copilot.log" || fail "7a: expected --model gpt-4.1 and --silent in copilot call"
python3 - "${T7}/metrics-7a.json" <<'PY' || fail "7a: metrics.json mismatch"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["provider"] == "copilot", d
assert d["model"] == "gpt-4.1", d
PY

# 7b: Explicit --model override
echo "console.log('b');" > "${T7}/b.js"
COPILOT_LOG="${T7}/copilot-7b.log" COPILOT_MOCK_MSG="feat(copilot): use custom model" PATH="$COPILOT_BIN" \
  "$SMART_PUSH" --yes --dir "$T7" --provider copilot --model gpt-5-mini --metrics-json "${T7}/metrics-7b.json" >/dev/null
grep -q "model=gpt-5-mini silent=1" "${T7}/copilot-7b.log" || fail "7b: expected --model gpt-5-mini"
python3 - "${T7}/metrics-7b.json" <<'PY' || fail "7b: metrics.json mismatch"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["provider"] == "copilot", d
assert d["model"] == "gpt-5-mini", d
PY

# 7c: Default model fallback when gpt-4.1 fails and no --model override was passed
echo "console.log('c');" > "${T7}/c.js"
COPILOT_LOG="${T7}/copilot-7c.log" COPILOT_FAIL_MODEL="gpt-4.1" COPILOT_MOCK_MSG="feat(copilot): fallback to default model" PATH="$COPILOT_BIN" \
  "$SMART_PUSH" --yes --dir "$T7" --provider copilot --metrics-json "${T7}/metrics-7c.json" >/dev/null
grep -q "model=<none> silent=1" "${T7}/copilot-7c.log" || fail "7c: expected fallback call without --model"
python3 - "${T7}/metrics-7c.json" <<'PY' || fail "7c: metrics.json mismatch"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["provider"] == "copilot", d
assert d["model"] == "default", d
PY

# 7d: --provider auto auto-detects copilot when only copilot is available and API keys are unset
echo "console.log('d');" > "${T7}/d.js"
(
  unset GEMINI_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
  COPILOT_LOG="${T7}/copilot-7d.log" PATH="$COPILOT_BIN" \
    "$SMART_PUSH" --yes --dir "$T7" --dry-run --metrics-json "${T7}/metrics-7d.json" >/dev/null
)
python3 - "${T7}/metrics-7d.json" <<'PY' || fail "7d: metrics.json mismatch"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["provider"] == "copilot", d
assert d["model"] == "gpt-4.1", d
PY
pass "Supports copilot CLI provider (default model, --model override, fallback, and auto-detection)"

# Test 8: Skips gitignored nested repos in exclude pathspecs during auto-staging
T8="${TMP_BASE}/t8-ignored-nested"
setup_fixture_repo "$T8"
printf "/*\n!/.gitignore\n!/root-file.txt\n" > "${T8}/.gitignore"
SMART_PUSH_MOCK_MSG="chore: init root" "$SMART_PUSH" --yes --dir "$T8" --provider mock >/dev/null

setup_fixture_repo "${T8}/ignored-sub"
echo "hello" > "${T8}/ignored-sub/file.txt"
echo "updated" > "${T8}/root-file.txt"
SMART_PUSH_MOCK_MSG="chore: update root file" "$SMART_PUSH" --yes --dir "$T8" --provider mock >/dev/null
[[ "$(git -C "$T8" log -1 --pretty=%s)" == "chore: update root file" ]] || fail "T8: local commit mismatch"
[[ "$(git --git-dir="${T8}-remote.git" log -1 --pretty=%s)" == "chore: update root file" ]] || fail "T8: remote commit mismatch"
[[ -z "$(git -C "$T8" ls-files ignored-sub)" ]] || fail "T8: ignored-sub should not be tracked"
pass "Skips gitignored nested repos in exclude pathspecs during auto-staging"

echo "All tests passed."
