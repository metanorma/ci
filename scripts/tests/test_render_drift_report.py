import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import render_drift_report as rd

WF = "matrix:\n  samples_repo:\n    - mn-samples-a\n    - mn-samples-b\n    - mn-samples-c\n"


def put(root, repo, report):
    d = os.path.join(root, rd.PREFIX + repo)
    os.makedirs(d)
    with open(os.path.join(d, "report.json"), "w") as f:
        json.dump(report, f)


class DriftReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.wf = os.path.join(self.tmp.name, "wf.yml")
        open(self.wf, "w").write(WF)
        self.rep = os.path.join(self.tmp.name, "reports")
        os.makedirs(self.rep)

    def tearDown(self):
        self.tmp.cleanup()

    def test_expected_repos_from_matrix(self):
        self.assertEqual(rd.expected_repos(self.wf),
                         ["mn-samples-a", "mn-samples-b", "mn-samples-c"])

    def test_all_clean_exits_zero(self):
        for r in "abc":
            put(self.rep, f"mn-samples-{r}", {"changed": [], "added": [], "removed": []})
        text, bad = rd.render(self.rep, self.wf)
        self.assertFalse(bad)
        self.assertIn("| mn-samples-a | clean | 0 | 0 | 0 | 0 |", text)

    def test_regression_missing_and_accepted(self):
        put(self.rep, "mn-samples-a", {"changed": [{"path": "x.html", "class": "regression"}],
                                       "added": [], "removed": []})
        put(self.rep, "mn-samples-b", {"changed": [{"path": "y", "class": "accepted"}],
                                       "added": [], "removed": []})
        text, bad = rd.render(self.rep, self.wf, "http://run")
        self.assertTrue(bad)
        self.assertIn("| mn-samples-a | regression | 1 | 0 | 0 | 1 |", text)
        self.assertIn("| mn-samples-b | drift-accepted |", text)
        self.assertIn("| mn-samples-c | no report |", text)
        self.assertIn("- mn-samples-a: `x.html`", text)
        self.assertIn("Run: http://run", text)


if __name__ == "__main__":
    unittest.main()
