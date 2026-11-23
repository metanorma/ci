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

ORGS = ["metanorma", "lutaml", "relaton", "fontist", "plurimath", "glossarist", "pubid", "coridoc"]
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
    """(repo, gem) pairs. Regular consumers verify one gem named after the
    repo; monorepo consumers (monorepo-rubygems-release.yml) verify every
    directory carrying a gemspec — the monorepo workflow's own contract is
    that the gem lives at <gem_name>/ and its directory equals its name."""
    repos = set()
    for org in ORGS:
        data = gh(f"search/code?q=org:{org}+rubygems-release.yml+in:file&per_page=100")
        if data:
            repos.update(i["repository"]["full_name"] for i in data.get("items", []))
        time.sleep(3)
    pairs = []
    for repo in sorted(repos - EXCLUDED):
        org, name = repo.split("/", 1)
        stub = gh(f"repos/{repo}/contents/.github/workflows/release.yml")
        text = ""
        if stub and isinstance(stub, dict) and stub.get("content"):
            text = base64.b64decode(stub["content"]).decode(errors="replace")
        if "monorepo-rubygems-release.yml" in text:
            tree = gh(f"repos/{repo}/git/trees/HEAD?recursive=1")
            gems = sorted({
                i["path"].rsplit("/", 1)[0].rsplit("/", 1)[-1]
                for i in (tree or {}).get("tree", [])
                if i["path"].endswith(".gemspec")
                and "vendor/" not in i["path"]
            })
            pairs.extend((repo, g) for g in gems if g != name)
            if not gems:
                pairs.append((repo, name))
        else:
            pairs.append((repo, name))
        time.sleep(1)
    return pairs


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
    for repo, gem in population():
        tag = latest_tag(repo)
        # For monorepo repos the v* tags are per-gem (v<gem version>), so
        # coherence means: the tag for THIS gem's rubygems version exists,
        # not just "the newest tag in the repo".
        rg_version = None
        rg = subprocess.run(["curl", "-sf", f"https://rubygems.org/api/v1/versions/{gem}.json"],
                            capture_output=True, text=True, timeout=30)
        if rg.returncode == 0 and rg.stdout:
            try:
                versions = [v["number"] for v in json.loads(rg.stdout)]
                stable = [v for v in versions if re.match(r"^\d+\.\d+\.\d+$", v)]
                rg_version = stable[0] if stable else (versions[0] if versions else None)
            except Exception:
                pass
        row = {"repo": repo, "gem": gem, "tag": "-" if not rg_version else f"v{rg_version}",
               "release": "?", "rubygems": rg_version or "?", "synced": "?"}
        if rg_version:
            has_tag = subprocess.run(
                ["git", "ls-remote", "--tags", f"https://github.com/{repo}.git", f"refs/tags/v{rg_version}"],
                capture_output=True, text=True, timeout=60)
            row["tag"] = "yes" if f"refs/tags/v{rg_version}$" in has_tag.stdout or \
                f"refs/tags/v{rg_version}\t" in has_tag.stdout or \
                has_tag.stdout.strip().endswith(f"refs/tags/v{rg_version}") else "MISSING"
            rel = gh(f"repos/{repo}/releases/tags/v{rg_version}")
            row["release"] = "yes" if rel else "MISSING"
        stub = gh(f"repos/{repo}/contents/.github/workflows/release.yml")
        if stub and isinstance(stub, dict) and stub.get("content"):
            text = base64.b64decode(stub["content"]).decode(errors="replace")
            row["synced"] = "yes" if "pull_request:" in text else "UNSYNCED"
        else:
            row["synced"] = "?"
        drift = []
        if row["synced"] != "yes":
            drift.append("stub")
        if row["tag"] == "MISSING":
            drift.append("tag")
        if row["release"] == "MISSING":
            drift.append("release")
        row["drift"] = ", ".join(drift) if drift else "-"
        rows.append(row)
        time.sleep(1)

    drift_rows = [r for r in rows if r["drift"] != "-"]
    out = []
    out.append(f"## Release coherence — {len(rows)} gems, {len(drift_rows)} with drift")
    out.append("")
    out.append("| Repository (gem) | Latest rubygems | Tag | GitHub Release | Stub synced | Drift |")
    out.append("|---|---|---|---|---|---|")
    for r in rows:
        if r["drift"] != "-":
            out.append(f"| **{r['repo']} ({r['gem']})** | {r['rubygems']} | {r['tag']} | {r['release']} | {r['synced']} | **{r['drift']}** |")
    clean = [r for r in rows if r["drift"] == "-"]
    if clean:
        out.append(f"| ... {len(clean)} further gems coherent | | | | | |")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
