import json, os, subprocess, tempfile, unittest, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import html_parity as hp
import html_content as hc

FX = os.path.join(os.path.dirname(__file__), "fixtures")


class ParityTest(unittest.TestCase):
    def test_identical_pair_is_parity(self):
        files = hp.diff_dirs(f"{FX}/same/a", f"{FX}/same/b")
        self.assertEqual([f["status"] for f in files], ["identical"])
        self.assertEqual(hp.conclusion(files), "parity")

    def test_differing_pair_is_divergent_with_diff(self):
        files = hp.diff_dirs(f"{FX}/diff/a", f"{FX}/diff/b")
        self.assertEqual(files[0]["status"], "differs")
        self.assertTrue(any("changed" in l for l in files[0]["diff"]))
        self.assertEqual(hp.conclusion(files), "divergent")

    def test_normalize_masks_volatile_and_sorts(self):
        n = hp.normalize_html('<p class="z a" id="1">t 2026-01-01T00:00:00Z</p>')
        self.assertIn('class="a z"', n)
        self.assertIn("TIMESTAMP", n)

    def test_cli_writes_signoff_and_exit_code(self):
        with tempfile.TemporaryDirectory() as out:
            rc = hp.main(["iso", "--isodoc-dir", f"{FX}/diff/a",
                          "--document-dir", f"{FX}/diff/b", "--out-dir", out])
            self.assertEqual(rc, 1)
            doc = json.load(open(os.path.join(out, "iso.json")))
            self.assertEqual(doc["conclusion"], "divergent")
            rc = hp.main(["iso", "--isodoc-dir", f"{FX}/same/a",
                          "--document-dir", f"{FX}/same/b", "--out-dir", out])
            self.assertEqual(rc, 0)


class ParityFlavorTest(unittest.TestCase):
    def _gems(self, flavor):
        script = os.path.join(os.path.dirname(__file__), "..", "parity_flavor.rb")
        code = f'require "{script}"; puts ParityFlavor.gems("{flavor}").join(" "), ParityFlavor.base("{flavor}")'
        out = subprocess.run(["ruby", "-e", code], capture_output=True, text=True, check=True)
        gems, base = out.stdout.splitlines()
        return gems.split(), base

    def test_plain_flavor_is_its_own_gem(self):
        self.assertEqual(self._gems("iec"), (["metanorma-iec"], "iec"))

    def test_tastes_load_base_flavor_and_taste_gem(self):
        for taste in ("iala", "wmo"):
            gems, base = self._gems(taste)
            self.assertEqual(base, "iho")
            self.assertEqual(gems, ["metanorma-iho", "metanorma-iso", "metanorma-taste"])


class RenderCmdTest(unittest.TestCase):
    def test_default_cmd_calls_render_engines_through_gemfile(self):
        cmd = hp.build_render_cmd(hp.DEFAULT_RENDER_CMD, "iec", "document", "/tmp/my samples", "/tmp/o ut")
        self.assertNotIn("METANORMA_HTML_ENGINE", cmd)
        self.assertIn("PARITY_FLAVOR=iec", cmd)
        self.assertIn("BUNDLE_GEMFILE=" + hp.RENDER_GEMFILE, cmd)
        self.assertIn(hp.RENDER_SCRIPT, cmd)
        self.assertIn("--engine document", cmd)
        self.assertIn("--input '/tmp/my samples'", cmd)
        self.assertIn("--out '/tmp/o ut'", cmd)
        self.assertTrue(os.path.exists(hp.RENDER_SCRIPT))
        self.assertTrue(os.path.exists(hp.RENDER_GEMFILE))

    def test_custom_template_with_old_placeholders_still_works(self):
        cmd = hp.build_render_cmd("x {engine} {flavor} {out}", "iso", "isodoc", ".", "/o")
        self.assertEqual(cmd, "x isodoc iso /o")

    def test_render_mode_runs_cmd_per_engine_in_samples_dir(self):
        with tempfile.TemporaryDirectory() as samples, tempfile.TemporaryDirectory() as work, \
                tempfile.TemporaryDirectory() as out:
            for e in ("isodoc", "document"):
                os.makedirs(os.path.join(work, "iso", e))
            tpl = "mkdir -p {out} && echo '<p>{engine}</p>' > {out}/a.html"
            rc = hp.main(["iso", "--samples-dir", samples, "--work-dir", work,
                          "--render-cmd", tpl, "--out-dir", out])
            self.assertEqual(rc, 1)  # engines differ -> divergent
            self.assertTrue(os.path.exists(os.path.join(work, "iso", "document", "a.html")))


class ContentParityTest(unittest.TestCase):
    def blocks(self, rel):
        with open(os.path.join(FX, "content", rel)) as fh:
            return hc.extract_blocks(fh.read())

    def test_extract_drops_markup_chrome_and_canonicalizes_math(self):
        b = self.blocks("ok/b/doc.html")
        texts = [x[2] for x in b]
        self.assertEqual(texts, ["1 Scope", "This document applies to rice.", "Mass",
                                 "[math: m=2]", "First item"])
        self.assertEqual(b[0][:2], ("heading", 1))

    def test_different_markup_same_content_is_parity(self):
        files = hp.diff_dirs_content(f"{FX}/content/ok/a", f"{FX}/content/ok/b")
        self.assertEqual(files[0]["status"], "content-ok")
        self.assertEqual(files[0]["missing"], 0)
        self.assertEqual(hp.html_content.content_conclusion(files), "content-parity")
        # the markup gate sees these two as different
        self.assertEqual(hp.conclusion(hp.diff_dirs(f"{FX}/content/ok/a", f"{FX}/content/ok/b")), "divergent")

    def test_missing_retyped_extra_are_counted(self):
        f = hp.diff_dirs_content(f"{FX}/content/lost/a", f"{FX}/content/lost/b")[0]
        self.assertEqual((f["missing"], f["retyped"], f["extra"]), (1, 1, 1))
        self.assertEqual(f["missing_blocks"][0]["text"], "Lost sentence about moisture.")
        self.assertEqual(f["retyped_blocks"][0]["document"], "heading3")

    def test_reflowed_text_is_not_missing(self):
        a = [("text", 0, "Part 1: Rice")]
        b = [("text", 0, "Cereals - PART 1: RICE")]
        r = hc.compare_blocks(a, b)
        self.assertEqual((r["missing"], r["reflowed"]), (0, 1))

    def test_order_changes_are_reported(self):
        a = [("text", 0, "one"), ("text", 0, "two"), ("text", 0, "three")]
        r = hc.compare_blocks(a, [a[2], a[0], a[1]])
        self.assertEqual((r["missing"], r["out_of_order"]), (0, 1))

    def test_threshold_and_exit_codes(self):
        with tempfile.TemporaryDirectory() as out:
            args = ["iec", "--mode", "content", "--isodoc-dir", f"{FX}/content/lost/a",
                    "--document-dir", f"{FX}/content/lost/b", "--out-dir", out]
            self.assertEqual(hp.main(args), 1)
            doc = json.load(open(os.path.join(out, "iec.content.json")))
            self.assertEqual(doc["conclusion"], "content-missing")
            self.assertEqual(doc["totals"]["missing"], 1)
            self.assertEqual(hp.main(args + ["--max-missing", "1"]), 0)
            self.assertEqual(hp.main(["iec", "--mode", "content", "--isodoc-dir", f"{FX}/content/ok/a",
                                      "--document-dir", f"{FX}/content/ok/b", "--out-dir", out]), 0)

    def test_skip_class_is_configurable(self):
        h = '<div class="brand"><p>Logo text</p></div><p>Body</p>'
        self.assertEqual(len(hc.extract_blocks(h)), 2)
        self.assertEqual(len(hc.extract_blocks(h, skip_classes=["brand"])), 1)

    def test_iec_profile_adds_to_defaults(self):
        c, i = hp.resolve_skips("iec")
        for k in ("fn-popup", "variant-title-toc", "coverpage_docnumber", "toc"):
            self.assertIn(k, c)
        self.assertIn("toc", i)
        c2, _ = hp.resolve_skips("rice")          # no profile: defaults only
        self.assertEqual(c2, list(hc.DEFAULT_SKIP_CLASSES))
        c3, _ = hp.resolve_skips("iec", use_profile=False)
        self.assertNotIn("fn-popup", c3)
        self.assertEqual(hp.resolve_skips("iec", skip_class=["x"])[0], ["x"])

    def test_profile_changes_cli_result(self):
        with tempfile.TemporaryDirectory() as t:
            a, b = os.path.join(t, "a"), os.path.join(t, "b")
            os.makedirs(a); os.makedirs(b)
            open(os.path.join(a, "d.html"), "w").write('<p>Body</p><p class="variant-title-toc">Hidden FR</p>')
            open(os.path.join(b, "d.html"), "w").write("<p>Body</p>")
            args = ["iec", "--mode", "content", "--isodoc-dir", a, "--document-dir", b, "--out-dir", t]
            self.assertEqual(hp.main(args), 0)
            self.assertEqual(hp.main(args + ["--no-profile"]), 1)
            custom = os.path.join(t, "p.json")
            open(custom, "w").write('{"skip_classes": ["variant-title-toc"]}')
            self.assertEqual(hp.main(["rice"] + args[1:] + ["--profile", custom]), 0)

    def test_title_block_plus_body_equals_legacy_label_body(self):
        legacy = [("text", 0, "WARNING — Direct contact can cause lesions.")]
        new = [("text", 0, "WARNING"), ("text", 0, "Direct contact can cause lesions.")]
        r = hc.compare_blocks(legacy, new)
        self.assertEqual((r["matched"], r["missing"], r["reflowed"]), (1, 0, 0))

    def test_title_block_with_different_body_is_still_missing(self):
        legacy = [("text", 0, "WARNING — Direct contact can cause lesions.")]
        new = [("text", 0, "WARNING"), ("text", 0, "Something else entirely.")]
        r = hc.compare_blocks(legacy, new)
        self.assertEqual((r["matched"], r["missing"]), (0, 1))

    def test_footnote_aside_equals_fn_popup_text(self):
        legacy = [("text", 0, "1)Withdrawn."), ("text", 0, "↩"), ("text", 0, "Body.")]
        html = '<p>Body.<span class="fn-popup">Withdrawn.</span></p>'
        r = hc.compare_blocks(legacy, hc.extract_blocks(html, ["fn-popup"]),
                              popups=hc.extract_popups(html))
        self.assertEqual((r["matched"], r["missing"], r["reflowed"]), (2, 0, 0))

    def test_footnote_with_different_popup_text_is_still_missing(self):
        legacy = [("text", 0, "1)Withdrawn.")]
        html = '<p>Body.<span class="fn-popup">Under preparation.</span></p>'
        r = hc.compare_blocks(legacy, hc.extract_blocks(html, ["fn-popup"]),
                              popups=hc.extract_popups(html))
        self.assertEqual(r["missing"], 1)

    def test_footnote_popup_is_used_once(self):
        legacy = [("text", 0, "1)Withdrawn."), ("text", 0, "2)Withdrawn.")]
        html = '<p>A<span class="fn-popup">Withdrawn.</span></p>'
        r = hc.compare_blocks(legacy, hc.extract_blocks(html, ["fn-popup"]),
                              popups=hc.extract_popups(html))
        self.assertEqual(r["missing"], 1)


if __name__ == "__main__":
    unittest.main()
