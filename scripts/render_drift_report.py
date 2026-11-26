#!/usr/bin/env python3
"""Aggregate render-drift-weekly per-repo reports into one markdown table (ci#506).

Usage: render_drift_report.py REPORTS_DIR WORKFLOW_YML [--run-url URL]

REPORTS_DIR holds one subdirectory per downloaded artifact named
render-diff-report-<repo>, each with report.json written by
render-baseline.yml (keys changed/added/removed, entries carry "class").
The expected repo list is the matrix in WORKFLOW_YML, so a repo whose
render or baseline fetch failed shows up as "no report" instead of
vanishing. Prints markdown; exits 1 if any repo regressed or is missing.
"""
import json
import os
import re
import sys

PREFIX = "render-diff-report-"


def expected_repos(workflow_path):
    with open(workflow_path) as f:
        return sorted(set(re.findall(r"^\s*-\s+(mn-samples-[A-Za-z0-9-]+)\s*$", f.read(), re.M)))


def load_report(reports_dir, repo):
    path = os.path.join(reports_dir, PREFIX + repo, "report.json")
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return json.load(f)


def summarize(report):
    entries = [e for k in ("changed", "added", "removed") for e in report.get(k, [])]
    reg = [e for e in entries if e.get("class") == "regression"]
    acc = [e for e in entries if e.get("class") == "accepted"]
    if reg:
        verdict = "regression"
    elif acc:
        verdict = "drift-accepted"
    else:
        verdict = "clean"
    return {
        "verdict": verdict,
        "changed": len(report.get("changed", [])),
        "added": len(report.get("added", [])),
        "removed": len(report.get("removed", [])),
        "regressions": reg,
    }


def render(reports_dir, workflow_path, run_url=""):
    rows, bad = [], False
    lines = []
    for repo in expected_repos(workflow_path):
        report = load_report(reports_dir, repo)
        if report is None:
            rows.append(f"| {repo} | no report | - | - | - | - |")
            bad = True
            continue
        s = summarize(report)
        bad = bad or s["verdict"] == "regression"
        rows.append(f"| {repo} | {s['verdict']} | {s['changed']} | {s['added']} | "
                    f"{s['removed']} | {len(s['regressions'])} |")
        for e in s["regressions"][:10]:
            lines.append(f"- {repo}: `{e['path']}`")
    out = ["| samples repo | verdict | changed | added | removed | regressions |",
           "|---|---|---|---|---|---|"] + rows
    if lines:
        out += ["", "First regressions per repo (max 10):"] + lines
    if run_url:
        out += ["", f"Run: {run_url}"]
    return "\n".join(out) + "\n", bad


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    run_url = ""
    if "--run-url" in argv:
        run_url = argv[argv.index("--run-url") + 1]
        args = [a for a in args if a != run_url]
    text, bad = render(args[0], args[1], run_url)
    sys.stdout.write(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
