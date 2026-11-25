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
import argparse, difflib, hashlib, json, os, re, shlex, subprocess, sys
from datetime import datetime, timezone
from html.parser import HTMLParser

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import html_content

ENGINES = ("isodoc", "document")
# Placeholders: {engine} {out} {flavor}, plus {samples} (abs samples dir),
# {script} (scripts/render_engines.rb) and {gemfile} (gemfiles/html_parity.gemfile),
# all shell-quoted. The default calls metanorma-core's engine factory through
# render_engines.rb: no gem reads an engine env var and `metanorma site
# generate` never calls the factory, so there is no CLI switch to use.
_HERE = os.path.dirname(os.path.abspath(__file__))
RENDER_SCRIPT = os.path.join(_HERE, "render_engines.rb")
RENDER_GEMFILE = os.path.join(os.path.dirname(_HERE), "gemfiles", "html_parity.gemfile")
DEFAULT_RENDER_CMD = (
    "PARITY_FLAVOR={flavor} BUNDLE_GEMFILE={gemfile} "
    "bundle exec ruby {script} --flavor {flavor} --engine {engine} "
    "--input {samples} --out {out}"
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


def diff_dirs_content(isodoc_dir, document_dir, skip_classes=html_content.DEFAULT_SKIP_CLASSES,
                      skip_ids=html_content.DEFAULT_SKIP_IDS):
    """Content-parity per file pair (see html_content.py): isodoc is the legacy
    side, so a block present there and absent from document counts as missing."""
    a, b = _files(isodoc_dir), _files(document_dir)
    res = []
    for rel in sorted(set(a) | set(b)):
        if rel not in b:
            res.append({"path": rel, "status": "only-isodoc", "missing": 0,
                        "legacy_blocks": len(html_content.extract_blocks(_read(a[rel]), skip_classes, skip_ids))})
        elif rel not in a:
            res.append({"path": rel, "status": "only-document"})
        else:
            r = html_content.compare_blocks(html_content.extract_blocks(_read(a[rel]), skip_classes, skip_ids),
                                            html_content.extract_blocks(_read(b[rel]), skip_classes, skip_ids))
            res.append({"path": rel, "status": "content-missing" if r["missing"] else "content-ok", **r})
    return res


def conclusion(files):
    if not files:
        return "no-html"
    return "parity" if all(f["status"] == "identical" for f in files) else "divergent"


def build_render_cmd(cmd_tpl, flavor, engine, samples_dir, out):
    q = shlex.quote
    return cmd_tpl.format(engine=engine, out=q(out), flavor=q(flavor),
                          samples=q(os.path.abspath(samples_dir)),
                          script=q(RENDER_SCRIPT), gemfile=q(RENDER_GEMFILE))


def render(flavor, engine, samples_dir, out, cmd_tpl):
    os.makedirs(out, exist_ok=True)
    cmd = build_render_cmd(cmd_tpl, flavor, engine, samples_dir, out)
    r = subprocess.run(cmd, shell=True, cwd=samples_dir)
    if r.returncode != 0:
        raise SystemExit(f"render failed (engine={engine}, rc={r.returncode}): {cmd}")


def write_signoff(flavor, files, out_dir, mode="markup", max_missing=0):
    os.makedirs(out_dir, exist_ok=True)
    counts = {}
    for f in files:
        counts[f["status"]] = counts.get(f["status"], 0) + 1
    doc = {"flavor": flavor, "engines": list(ENGINES), "conclusion": conclusion(files),
           "counts": counts, "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
           "files": files}
    if mode == "content":
        totals = {k: sum(f.get(k, 0) for f in files)
                  for k in ("legacy_blocks", "matched", "missing", "extra", "retyped", "reflowed", "out_of_order")}
        doc.update(mode="content", max_missing=max_missing, totals=totals,
                   conclusion=html_content.content_conclusion(files, max_missing))
    jp = os.path.join(out_dir, f"{flavor}.json" if mode == "markup" else f"{flavor}.content.json")
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
sorted, timestamps and UUIDs masked.

--mode content compares text, not markup (see html_content.py): both sides
become ordered (block type, heading level, text) lists with class/id/style,
scripts, head, svg and generated chrome (TOC, back-to-top, header brand;
--skip-class / --skip-id) dropped and math canonicalized. Output is
<out-dir>/<flavor>.content.json with per-file and total counts:
  missing      isodoc text absent from document output (fails the gate)
  extra        document text with no isodoc counterpart
  retyped      same text, different block type/heading level
  reflowed     text present but split/merged/re-cased across blocks
  out_of_order common blocks in a different order
conclusion content-parity needs missing <= --max-missing (default 0)."""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], epilog=EPILOG,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("flavor")
    ap.add_argument("--samples-dir", default=None, help="checkout of mn-samples-<flavor> (render mode)")
    ap.add_argument("--render-cmd", default=DEFAULT_RENDER_CMD,
                    help="shell template with {engine} {out} {flavor}; default: %(default)s")
    ap.add_argument("--isodoc-dir", help="pre-rendered isodoc output (skips rendering)")
    ap.add_argument("--document-dir", help="pre-rendered document output (skips rendering)")
    ap.add_argument("--mode", choices=("markup", "content"), default="markup",
                    help="markup: normalized-HTML diff (default); content: text-block parity")
    ap.add_argument("--max-missing", type=int, default=0,
                    help="content mode: missing blocks tolerated (default 0)")
    ap.add_argument("--skip-class", action="append", default=None, metavar="CLASS",
                    help="content mode: drop elements with this class (repeatable; replaces defaults)")
    ap.add_argument("--skip-id", action="append", default=None, metavar="ID",
                    help="content mode: drop elements with this id (repeatable; replaces defaults)")
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
    if a.mode == "content":
        files = diff_dirs_content(d["isodoc"], d["document"],
                                  a.skip_class if a.skip_class is not None else html_content.DEFAULT_SKIP_CLASSES,
                                  a.skip_id if a.skip_id is not None else html_content.DEFAULT_SKIP_IDS)
        doc, path = write_signoff(a.flavor, files, a.out_dir, "content", a.max_missing)
        print(f"{a.flavor}: {doc['conclusion']} {doc['totals']} -> {path}")
        return 0 if doc["conclusion"] == "content-parity" else 1
    doc, path = write_signoff(a.flavor, diff_dirs(d["isodoc"], d["document"]), a.out_dir)
    print(f"{a.flavor}: {doc['conclusion']} {doc['counts']} -> {path}")
    return 0 if doc["conclusion"] == "parity" else 1


if __name__ == "__main__":
    sys.exit(main())
