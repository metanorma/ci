#!/usr/bin/env python3
"""Content-parity model for the two-engine HTML gate (ci#507).

The isodoc and document engines use different markup (CSS classes, wrappers,
ids, TOC, scripts, header chrome), so a markup diff is not a useful gate.
Ronald's rule on metanorma-document#114 is "nothing lost vs legacy". This
module reduces each HTML file to an ordered list of text blocks

    (type, level, text)     type: heading | li | cell | text

and reports which legacy (isodoc) blocks are missing from the document engine
output, which are extra, which only changed block type (retyped), which are
still present but split/merged/re-cased (reflowed), and whether the common
blocks keep their order. Only "missing" fails the gate.

Dropped before comparison: class/id/style/other attributes, head, script,
style, svg, button, noscript, and any subtree whose id or class matches the
skip lists (generated TOC, back-to-top, brand chrome; see DEFAULT_SKIP_*).
Inline wrappers (span, a, b, i, em, ...) are collapsed into their block's
text. MathML is canonicalized to "[math: <tokens>]".
"""
import re
import unicodedata
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from html.parser import HTMLParser

VOID = {"br", "hr", "img", "input", "meta", "link", "area", "base", "col",
        "embed", "source", "track", "wbr"}
ALWAYS_SKIP = {"head", "script", "style", "svg", "button", "noscript", "template"}
# Generated chrome, configurable on the CLI (--skip-class / --skip-id).
DEFAULT_SKIP_CLASSES = ("toc", "toc-link", "toc-list", "toc-entry", "back-to-top",
                        "skip-nav", "doc-header", "header-brand", "brand-logo",
                        "doc-footer", "sidebar", "nav-toggle")
DEFAULT_SKIP_IDS = ("toc", "toggle", "doc-header", "back-to-top",
                    "boilerplate-license-destination", "boilerplate-copyright-destination")
HEADING = re.compile(r"h([1-6])$")
BLOCK_LI, BLOCK_CELL = {"li"}, {"td", "th"}
# Elements that start a new block of plain text.
BLOCK_TEXT = {"p", "div", "dt", "dd", "caption", "figcaption", "pre", "blockquote",
              "section", "article", "aside", "header", "footer", "main", "nav",
              "ul", "ol", "dl", "table", "thead", "tbody", "tfoot", "tr", "figure",
              "details", "summary", "body", "html", "address", "fieldset", "form"}
MATH_SKIP = {"annotation", "annotation-xml"}


def clean(text):
    text = unicodedata.normalize("NFKC", text)
    text = re.sub(r"[​-‍⁠﻿]", "", text)
    return " ".join(text.split())


class _Blocks(HTMLParser):
    def __init__(self, skip_classes, skip_ids):
        super().__init__(convert_charrefs=True)
        self.skip_classes, self.skip_ids = set(skip_classes), set(skip_ids)
        self.blocks = []
        self.stack = []          # (tag, skipped)
        self.skip = 0            # depth of skipped ancestors
        self.ctx = [("text", 0)]  # block context stack
        self.buf = []
        self.math = None         # token list while inside <math>
        self.math_depth = 0

    # -- block bookkeeping
    def _flush(self):
        text = clean("".join(self.buf))
        self.buf = []
        if text:
            self.blocks.append((*self.ctx[-1], text))

    def _kind(self, tag):
        m = HEADING.match(tag)
        if m:
            return ("heading", int(m.group(1)))
        if tag in BLOCK_LI:
            return ("li", 0)
        if tag in BLOCK_CELL:
            return ("cell", 0)
        return None

    def handle_starttag(self, tag, attrs):
        if tag in VOID:
            if tag == "br" and not self.skip and self.math is None:
                self.buf.append(" ")
            return
        a = dict(attrs)
        skipped = (self.skip > 0 or tag in ALWAYS_SKIP
                   or a.get("id") in self.skip_ids
                   or bool(self.skip_classes & set((a.get("class") or "").split()))
                   or a.get("hidden") is not None
                   or a.get("aria-hidden") == "true")
        self.stack.append((tag, skipped))
        if skipped:
            self.skip += 1
            return
        if tag == "math":
            self.math, self.math_depth = [], 1
            return
        if self.math is not None:
            self.math_depth += 1
            return
        kind = self._kind(tag)
        if kind or tag in BLOCK_TEXT:
            self._flush()
            self.ctx.append(kind or ("text", 0))

    def handle_endtag(self, tag):
        if tag in VOID or not any(t == tag for t, _ in self.stack):
            return
        while self.stack:                 # pop to the matching open tag
            t, skipped = self.stack.pop()
            if skipped:
                self.skip -= 1
            elif t == "math" and self.math is not None and self.math_depth == 1:
                self.buf.append(f" [math: {''.join(self.math)}] ")
                self.math, self.math_depth = None, 0
            elif self.math is not None:
                self.math_depth -= 1
            elif self._kind(t) or t in BLOCK_TEXT:
                self._flush()
                if len(self.ctx) > 1:
                    self.ctx.pop()
            if t == tag:
                break

    def handle_data(self, data):
        if self.skip:
            return
        if self.math is not None:
            if not any(t in MATH_SKIP for t, _ in self.stack):
                self.math.append("".join(data.split()))
            return
        self.buf.append(data)


def extract_blocks(html, skip_classes=DEFAULT_SKIP_CLASSES, skip_ids=DEFAULT_SKIP_IDS):
    """Ordered list of (type, level, text) content blocks."""
    p = _Blocks(skip_classes, skip_ids)
    p.feed(html)
    p.close()
    p._flush()
    return p.blocks


def _squash(text):
    return re.sub(r"\W+", "", text.casefold())


def compare_blocks(legacy, new, max_report=20):
    """legacy/new: block lists. Returns the per-file content comparison."""
    ca, cb = Counter(legacy), Counter(new)
    left_a, left_b = ca - cb, cb - ca             # unmatched on each side
    by_text_b = defaultdict(list)
    for (t, l, x), n in left_b.items():
        by_text_b[x].extend([(t, l)] * n)
    missing, retyped = [], []
    for (t, l, x), n in sorted(left_a.items(), key=lambda kv: legacy.index(kv[0])):
        for _ in range(n):
            if by_text_b.get(x):
                retyped.append({"text": x, "legacy": f"{t}{l or ''}",
                                "document": "{}{}".format(*[by_text_b[x].pop(0)][0])})
            else:
                missing.append({"type": t, "level": l, "text": x})
    # A block with no exact twin may still be present, split or merged with
    # neighbours or upper-cased: look for its text inside the whole document.
    haystack = _squash(" ".join(x for _, _, x in new))
    reflowed = [m for m in missing if _squash(m["text"]) in haystack]
    missing = [m for m in missing if _squash(m["text"]) not in haystack]
    extra = [{"type": t, "level": l, "text": x}
             for x, ts in by_text_b.items() for (t, l) in ts]
    # order check over the blocks both sides have
    common = ca & cb
    sa = [b for b in legacy if common.get(b)]
    sb = [b for b in new if common.get(b)]
    kept = sum(m.size for m in SequenceMatcher(None, sa, sb, autojunk=False).get_matching_blocks())
    return {"legacy_blocks": len(legacy), "document_blocks": len(new),
            "matched": sum(common.values()), "missing": len(missing),
            "extra": len(extra), "retyped": len(retyped),
            "reflowed": len(reflowed),
            "out_of_order": len(sa) - kept,
            "missing_blocks": missing[:max_report], "extra_blocks": extra[:max_report],
            "retyped_blocks": retyped[:max_report],
            "reflowed_blocks": reflowed[:max_report]}


def content_conclusion(files, max_missing=0):
    if not files:
        return "no-html"
    gone = sum(f.get("missing", 0) + (f["legacy_blocks"] if f["status"] == "only-isodoc" else 0)
               for f in files)
    return "content-parity" if gone <= max_missing else "content-missing"
