# Token & Cost Benchmark: Native Agent Push vs. `smart-push`

## Test Setup

To measure real-world token impact rather than synthetic empty-chat numbers, both runs were executed inside the **same active engineering conversation** (`~105,000` tokens of accumulated coding history, rules, and tool declarations) against the **exact same repository diff**:

* **Payload:** 10 files changed, 1,001 insertions (`40,433` bytes raw `git diff`)
* **Flagship Session Model:** High-capability reasoning coding model (`~105k` active context window)
* **Sub-Process Low-Cost Model:** `gemini-3.8-flash-low` via `agy` CLI (`--effort low --disable-slash-commands`), plus comparison figures for direct REST API (`gemini-2.5-flash-lite` / `gpt-4o-mini`) and local `ollama`

To avoid cross-contaminating the context baseline, `/smart-push` was measured **before** the native push (because `/smart-push` adds virtually zero diff tokens to the conversation history), and `git reset HEAD~1` restored the byte-identical working tree for the native run.

---

## Raw Step-by-Step Measurements

### Workflow A: Native Agent Push Inside Flagship Chat

Without `smart-push`, the flagship model must inspect the diff itself before it can formulate a commit message:

1. **Turn 1 (Stage & Read Diff):** `2,729` uncached input + `105,258` cached input + `226` output tokens -> executes `git add -A && git status --short && git diff --cached`.
2. **Context Growth:** Even with 10 KB shell output middle-truncation, the tool output expands the active prompt by **`+3,604` tokens** (in agents without aggressive output truncation, `40,433` bytes of diff adds **`~10,500` tokens**).
3. **Turn 2 (Generate Message & Commit):** `3,695` uncached input + `107,896` cached input + `170` output tokens -> executes `git commit` (& `git push`).
4. **Turn 3 (Report to User):** `2,644` uncached input + `109,542` cached input + `285` output tokens.

* **Immediate Flagship Totals (3 Turns):**
  * Uncached Input: **`9,068` tokens**
  * Cached Input Read: **`322,696` tokens**
  * Output: **`681` tokens**
* **Permanent Context Pollution:** **`+3,604` to `+10,500` tokens** remain in the chat history and are re-read on every single subsequent turn in the session.

---

### Workflow B: `/smart-push` Skill Inside Flagship Chat

With `smart-push`, `SKILL.md` forbids the flagship agent from running `git diff`:

1. **Turn 1 (Invoke `smart-push.sh --yes`):** `2,448` uncached input + `102,851` cached input + `173` output tokens.
2. **Isolated Sub-Process (`smart-push.sh`):**
   * Runs local Secret Leak Guard (`0` tokens).
   * Compresses diff (`12,000` char cap, lockfiles excluded) and calls `gemini-3.8-flash-low`:
     * `input_tokens`: **`15,131`** (includes CLI base prompt; via direct `GEMINI_API_KEY` / `OPENAI_API_KEY` REST mode without CLI wrapper: **`~3,200` tokens**)
     * `output_tokens`: **`13`** (`feat: initial release of smart-push agent skill and cli tool`)
   * Commits, pushes, and returns a **single 112-character summary line** to the flagship agent.
3. **Turn 2 (Report Summary to User):** `~2,502` uncached input + `103,514` cached input + `~177` output tokens.

* **Immediate Flagship Totals (2 Turns instead of 3):**
  * Uncached Input: **`~4,950` tokens** (**`-45%`**)
  * Cached Input Read: **`~206,365` tokens** (**`-36%`** — eliminates an entire 108k-token flagship round-trip!)
  * Output: **`~350` tokens** (**`-49%`**)
* **Permanent Context Pollution:** **`~120` tokens** (**`-97%` to `-99%` reduction**).

---

### Workflow C: Terminal `git smart-push` (Zero Flagship Involvement)

Running `git smart-push` (or `smart-push -y`) directly in your terminal:

* **Flagship Tokens:** **`0`** (zero turns, zero context growth)
* **Low-Cost Model Tokens:**
  * Via Agent CLI (`agy` / `claude --model haiku`): `~15,131` mini input + `13` output tokens (`~$0.002`)
  * Via Direct API (`GEMINI_API_KEY` / `OPENAI_API_KEY`): `~3,200` mini input + `13` output tokens (`~$0.0005`)
  * Via Local `ollama` (`qwen2.5-coder:3b`): **`$0.00` (100% local & offline)**

---

## Reproducing This Benchmark

1. Capture sub-process metrics using `--metrics-json`:
   ```bash
   smart-push --yes --metrics-json .smart-push-metrics.json
   ```
2. Run [`measure_transcript.py`](./measure_transcript.py) against your agent's JSONL transcript range:
   ```bash
   python3 benchmarks/measure_transcript.py \
     --transcript /path/to/transcript.jsonl \
     --start-step <first_step> \
     --end-step <last_step> \
     --sub-metrics .smart-push-metrics.json
   ```
