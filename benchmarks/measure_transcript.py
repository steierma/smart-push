#!/usr/bin/env python3
"""Compute anonymized token & cost deltas from JSONL session transcripts and smart-push metrics."""

import argparse
import json
from pathlib import Path

# Representative public API pricing per 1M tokens (USD) for transparent comparison
PRICING_PER_1M = {
    "flagship": {"input": 3.00, "cache_read": 0.30, "output": 15.00},
    "mini": {"input": 0.15, "cache_read": 0.0375, "output": 0.60},
}


def sum_transcript_range(jsonl_path: Path, start_step: int, end_step: int) -> dict:
    totals = {"turns": 0, "input_tokens": 0, "cache_read_tokens": 0, "output_tokens": 0, "models": set()}
    with jsonl_path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            idx = row.get("step_index", -1)
            if start_step <= idx <= end_step and row.get("type") == "PLANNER_RESPONSE":
                totals["turns"] += 1
                totals["input_tokens"] += int(row.get("input_tokens", 0))
                totals["cache_read_tokens"] += int(row.get("cache_read_tokens", 0))
                totals["output_tokens"] += int(row.get("output_tokens", 0))
                if row.get("model"):
                    totals["models"].add(row["model"])
    totals["models"] = sorted(totals["models"])
    return totals


def estimate_cost(inp: int, cache: int, out: int, tier: str) -> float:
    rates = PRICING_PER_1M[tier]
    return (inp * rates["input"] + cache * rates["cache_read"] + out * rates["output"]) / 1_000_000.0


def main() -> None:
    parser = argparse.ArgumentParser(description="Measure token usage between native agent push and /smart-push.")
    parser.add_argument("--transcript", type=Path, required=True, help="Path to session transcript.jsonl")
    parser.add_argument("--start-step", type=int, required=True, help="First step_index (inclusive)")
    parser.add_argument("--end-step", type=int, required=True, help="Last step_index (inclusive)")
    parser.add_argument("--sub-metrics", type=Path, help="Optional smart-push --metrics-json file")
    args = parser.parse_args()

    main_stats = sum_transcript_range(args.transcript, args.start_step, args.end_step)
    flagship_cost = estimate_cost(
        main_stats["input_tokens"], main_stats["cache_read_tokens"], main_stats["output_tokens"], "flagship"
    )

    sub_stats = None
    mini_cost = 0.0
    if args.sub_metrics and args.sub_metrics.exists():
        sub_stats = json.loads(args.sub_metrics.read_text(encoding="utf-8"))
        mini_cost = estimate_cost(
            int(sub_stats.get("input_tokens", 0)),
            int(sub_stats.get("cache_read_tokens", 0)),
            int(sub_stats.get("output_tokens", 0)),
            "mini",
        )

    result = {
        "main_session": main_stats,
        "sub_process": sub_stats,
        "estimated_cost_usd": round(flagship_cost + mini_cost, 6),
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
