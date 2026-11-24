import json, os, tempfile, unittest, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import html_parity as hp

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


if __name__ == "__main__":
    unittest.main()
