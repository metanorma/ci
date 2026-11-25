import json, os, tempfile, unittest, sys
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


if __name__ == "__main__":
    unittest.main()
