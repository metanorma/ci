#!/usr/bin/env python3
"""Two-engine HTML parity gate (ci#507, epic metanorma/metanorma#692).

Render one flavor's mn-samples manifest twice, once with
`html_engine: isodoc` and once with `html_engine: document`, normalize the
HTML, diff it per file and write a per-flavor sign-off artifact.

Usage:
  html_parity.py FLAVOR [--samples-dir DIR] [--out-dir DIR]
  html_parity.py FLAVOR --isodoc-dir DIR --document-dir DIR   (diff only)

The ci#504 harness (render-baseline.yml) hashes raw bytes and has no HTML
normalization; the normalization here (normalize_html) is the single
implementation to share with it once its canonicalizers land.
"""
import argparse, difflib, hashlib, json, os, re, subprocess, sys
from datetime import datetime, timezone
from html.parser import HTMLParser

ENGINES = ("isodoc", "document")
# {engine} and {out} are substituted. The engine-selection mechanism is
# metanorma/metanorma#680 (metanorma-core#31); override with --render-cmd
# if it lands as something other than this env var.
DEFAULT_RENDER_CMD = (
    "METANORMA_HTML_ENGINE={engine} "
    "metanorma site generate --agree-to-terms -o {out}"
)
_TS = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?")
_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


class _Norm(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lines, self.pre = [], 0

    def _vol(self, s):
        return _UUID.sub("UUID", _TS.sub("TIMESTAMP", s))

    def handle_starttag(self, tag, attrs):
        parts = []
        for k, v in sorted(attrs):
            v = self._vol(v or "")
            if k == "class":
                v = " ".join(sorted(v.split()))
            parts.append(f'{k}="{v}"')
        self.lines.append(f"<{tag}{' ' if parts else ''}{' '.join(parts)}>")
        if tag in ("pre", "textarea"):
            self.pre += 1

    def handle_endtag(self, tag):
        self.lines.append(f"</{tag}>")
        if tag in ("pre", "textarea") and self.pre:
            self.pre -= 1

    def handle_data(self, data):
        text = data if self.pre else " ".join(data.split())
        if text:
            self.lines.append(self._vol(text))

    # comments, doctype, PIs are dropped deliberately


def normalize_html(html):
    """Canonical one-token-per-line form: comments dropped, whitespace
    collapsed (except in pre), attributes and class tokens sorted, timestamps
    and UUIDs masked."""
    p = _Norm()
    p.feed(html)
    p.close()
    return "\n".join(p.lines) + "\n"


def _files(d):
    return {os.path.relpath(os.path.join(r, f), d): os.path.join(r, f)
            for r, _, fs in os.walk(d) for f in fs if f.lower().endswith((".html", ".htm"))}


def _read(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def diff_dirs(isodoc_dir, document_dir, max_diff_lines=40):
    a, b = _files(isodoc_dir), _files(document_dir)
    res = []
    for rel in sorted(set(a) | set(b)):
        if rel not in b:
            res.append({"path": rel, "status": "only-isodoc"})
        elif rel not in a:
            res.append({"path": rel, "status": "only-document"})
        else:
            na, nb = normalize_html(_read(a[rel])), normalize_html(_read(b[rel]))
            if na == nb:
                res.append({"path": rel, "status": "identical",
                            "sha256": hashlib.sha256(na.encode()).hexdigest()})
            else:
                d = list(difflib.unified_diff(na.splitlines(), nb.splitlines(),
                                              "isodoc", "document", lineterm="", n=1))
                res.append({"path": rel, "status": "differs", "diff_lines": len(d),
                            "diff": d[:max_diff_lines]})
    return res


def conclusion(files):
    if not files:
        return "no-html"
    return "parity" if all(f["status"] == "identical" for f in files) else "divergent"


def render(flavor, engine, samples_dir, out, cmd_tpl):
    os.makedirs(out, exist_ok=True)
    cmd = cmd_tpl.format(engine=engine, out=out, flavor=flavor)
    r = subprocess.run(cmd, shell=True, cwd=samples_dir)
    if r.returncode != 0:
        raise SystemExit(f"render failed (engine={engine}, rc={r.returncode}): {cmd}")


def write_signoff(flavor, files, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    counts = {}
    for f in files:
        counts[f["status"]] = counts.get(f["status"], 0) + 1
    doc = {"flavor": flavor, "engines": list(ENGINES), "conclusion": conclusion(files),
           "counts": counts, "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
           "files": files}
    jp = os.path.join(out_dir, f"{flavor}.json")
    with open(jp, "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    return doc, jp


EPILOG = """\
Sign-off artifact: <out-dir>/<flavor>.json (default out-dir: parity-signoff,
meant to be committed on the render-baselines branch next to manifests/).
  flavor       flavor name (samples repo is mn-samples-<flavor>)
  engines      ["isodoc", "document"]
  conclusion   parity | divergent | no-html     (exit 0 only for parity)
  counts       files per status
  files[]      {path, status: identical|differs|only-isodoc|only-document,
                sha256 of normalized HTML | diff_lines + diff excerpt}
Normalization: comments dropped, whitespace collapsed, attributes/classes
sorted, timestamps and UUIDs masked."""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], epilog=EPILOG,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("flavor")
    ap.add_argument("--samples-dir", default=None, help="checkout of mn-samples-<flavor> (render mode)")
    ap.add_argument("--render-cmd", default=DEFAULT_RENDER_CMD,
                    help="shell template with {engine} {out} {flavor}; default: %(default)s")
    ap.add_argument("--isodoc-dir", help="pre-rendered isodoc output (skips rendering)")
    ap.add_argument("--document-dir", help="pre-rendered document output (skips rendering)")
    ap.add_argument("--work-dir", default="parity-work")
    ap.add_argument("--out-dir", default="parity-signoff")
    a = ap.parse_args(argv)
    if a.isodoc_dir and a.document_dir:
        d = {"isodoc": a.isodoc_dir, "document": a.document_dir}
    elif a.samples_dir:
        d = {e: os.path.abspath(os.path.join(a.work_dir, a.flavor, e)) for e in ENGINES}
        for e in ENGINES:
            render(a.flavor, e, a.samples_dir, d[e], a.render_cmd)
    else:
        ap.error("give --samples-dir (render) or both --isodoc-dir and --document-dir (diff only)")
    doc, path = write_signoff(a.flavor, diff_dirs(d["isodoc"], d["document"]), a.out_dir)
    print(f"{a.flavor}: {doc['conclusion']} {doc['counts']} -> {path}")
    return 0 if doc["conclusion"] == "parity" else 1


if __name__ == "__main__":
    sys.exit(main())
