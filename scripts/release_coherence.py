#!/usr/bin/env python3
"""Release-coherence verifier (metanorma/ci#515, Stage 3).

For every repository that consumes rubygems-release.yml, check that the
release surfaces agree:

  - the repository's default branch declares the PR-based flow
    (the release stub carries the pull_request trigger), and
  - a GitHub Release exists for the latest v* tag, and
  - the latest tag version equals the latest version on rubygems.org.

Drift means one of the known defects classes: a gem published without a
tag or Release (the legacy direct-push flow and the ci#515 pilot both
produced these), a synced stub missing, or a release stuck after merge.

Read-only: prints a markdown table to stdout (the workflow routes it to
$GITHUB_STEP_SUMMARY) and exits 0 — the report IS the output. Drift
rows are marked so the summary is scannable.
"""

import base64
import json
import os
import re
import subprocess
import sys
import time

ORGS = ["metanorma", "lutaml", "relaton", "fontist", "plurimath", "glossarist", "pubid"]
EXCLUDED = {"metanorma/ci", "metanorma/cimas", "metanorma/versions"}


def gh(path):
    for attempt in range(3):
        r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
        if r.returncode == 0:
            return json.loads(r.stdout)
        if "404" in r.stderr or "403" in r.stderr:
            return None
        time.sleep(20)
    return None


def population():
    repos = set()
    for org in ORGS:
        data = gh(f"search/code?q=org:{org}+rubygems-release.yml+in:file&per_page=100")
        if data:
            repos.update(i["repository"]["full_name"] for i in data.get("items", []))
        time.sleep(3)
    return sorted(repos - EXCLUDED)


def latest_tag(repo):
    r = subprocess.run(["git", "ls-remote", "--tags", f"https://github.com/{repo}.git"],
                       capture_output=True, text=True, timeout=60)
    best = None
    for line in r.stdout.splitlines():
        m = re.search(r"refs/tags/v(\d+\.\d+\.\d+)$", line.strip())
        if m:
            v = tuple(int(x) for x in m.group(1).split("."))
            if best is None or v > best[0]:
                best = (v, m.group(1))
    return best[1] if best else None


def main():
    token = os.environ.get("GH_TOKEN", "")
    rows = []
    for repo in population():
        org, name = repo.split("/", 1)
        tag = latest_tag(repo)
        row = {"repo": repo, "tag": tag or "-", "release": "?", "rubygems": "?", "synced": "?"}
        if tag:
            rel = gh(f"repos/{repo}/releases/tags/v{tag}")
            row["release"] = "yes" if rel else "MISSING"
        stub = gh(f"repos/{repo}/contents/.github/workflows/release.yml")
        if stub and isinstance(stub, dict) and stub.get("content"):
            text = base64.b64decode(stub["content"]).decode(errors="replace")
            row["synced"] = "yes" if "pull_request:" in text else "UNSYNCED"
        else:
            row["synced"] = "?"
        rg = subprocess.run(["curl", "-sf", f"https://rubygems.org/api/v1/versions/{name}.json"],
                            capture_output=True, text=True, timeout=30)
        if rg.returncode == 0 and rg.stdout:
            try:
                versions = [v["number"] for v in json.loads(rg.stdout)]
                stable = [v for v in versions if re.match(r"^\d+\.\d+\.\d+$", v)]
                row["rubygems"] = stable[0] if stable else (versions[0] if versions else "?")
            except Exception:
                row["rubygems"] = "?"
        else:
            row["rubygems"] = "n/a"
        drift = []
        if row["synced"] != "yes":
            drift.append("stub")
        if tag and row["release"] == "MISSING":
            drift.append("release")
        if tag and row["rubygems"] not in ("?", "n/a") and row["rubygems"] != tag:
            drift.append(f"version: tag {tag} vs rubygems {row['rubygems']}")
        row["drift"] = ", ".join(drift) if drift else "-"
        rows.append(row)
        time.sleep(1)

    drift_rows = [r for r in rows if r["drift"] != "-"]
    out = []
    out.append(f"## Release coherence — {len(rows)} gems, {len(drift_rows)} with drift")
    out.append("")
    out.append("| Repository | Latest tag | GitHub Release | rubygems | Stub synced | Drift |")
    out.append("|---|---|---|---|---|---|")
    for r in rows:
        if r["drift"] != "-":
            out.append(f"| **{r['repo']}** | {r['tag']} | {r['release']} | {r['rubygems']} | {r['synced']} | **{r['drift']}** |")
    clean = [r for r in rows if r["drift"] == "-"]
    if clean:
        out.append(f"| ... {len(clean)} further gems coherent | | | | | |")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
