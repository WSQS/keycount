#!/usr/bin/env python3
"""zonecheck 的判据（纯 stdlib unittest）。

跑法：uv run --no-project python tools/zonecheck/test_zonecheck.py
判据全部在**临时根**上做（各自带一份 .zonecheck.json），不碰仓库里的真实文件，
也就不受本仓库 exclude 的影响 —— 这一点很关键：如果判据目标落在 exclude 里，
judge 会一律回 "未纳入区域检查范围 ⇒ allow"，端到端判据就会**静默 PASS**。
所以每条 judge 判据前面都有一次 covered 前置自检。
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zonecheck as zc  # noqa: E402

CFG_JSON = """{
  "schema": 1,
  "prefixByExt": {".py": "#"},
  "defaultPrefix": "//",
  "include": ["**/*.py"],
  "exclude": ["excluded/**"],
  "generated": ["gen/**"],
  "defaultZone": "legacy",
  "defaultZoneByFile": {},
  "policy": {"crossZone": "error", "humanTouch": "error", "markerEdit": "error", "unmarkedTouch": "warn"}
}"""


def make_root(files):
    root = tempfile.mkdtemp(prefix="zc-test-")
    with open(os.path.join(root, ".zonecheck.json"), "w", encoding="utf-8") as f:
        f.write(CFG_JSON)
    for rel, text in files.items():
        p = os.path.join(root, rel.replace("/", os.sep))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
    return root


class ParseTest(unittest.TestCase):
    def test_pair_region_counts_unmarked(self):
        text = "\n".join(["# >>> zone:human", "a", "b", "# <<<", "c"])
        r = zc.parse_text(text, "#")
        self.assertEqual(r["errors"], [])
        self.assertEqual(r["regions"], [{"zone": "human", "begin": 2, "end": 3, "depth": 0}])
        self.assertEqual(r["counts"], {"human": 2, "ai": 0, "legacy": 1, "markers": 2})
        self.assertEqual(r["unmarked"], [[5, 5]])
        self.assertEqual(sum(r["counts"].values()), 5)

    def test_nested_stack_pairing(self):
        text = "\n".join(["# >>> zone:ai", "a", "# >>> zone:human", "h", "# <<<", "b", "# <<<"])
        r = zc.parse_text(text, "#")
        self.assertEqual(r["errors"], [])
        self.assertEqual(r["regions"], [
            {"zone": "human", "begin": 4, "end": 4, "depth": 1},
            {"zone": "ai", "begin": 2, "end": 6, "depth": 0},
        ])
        self.assertEqual(r["counts"], {"human": 1, "ai": 2, "legacy": 0, "markers": 4})

    def test_unmarked_never_includes_marker_lines(self):
        text = "\n".join(["a", "# >>> zone:human", "h", "# <<<", "b"])
        r = zc.parse_text(text, "#")
        self.assertEqual(r["unmarked"], [[1, 1], [5, 5]])

    def test_unpaired_begin(self):
        r = zc.parse_text("\n".join(["# >>> zone:human", "x"]), "#")
        self.assertEqual([e["code"] for e in r["errors"]], ["unpaired-begin"])

    def test_unpaired_end(self):
        r = zc.parse_text("\n".join(["x", "# <<<"]), "#")
        self.assertEqual([e["code"] for e in r["errors"]], ["unpaired-end"])

    def test_bad_format_end_with_type(self):
        r = zc.parse_text("# <<< zone:human", "#")
        self.assertEqual([e["code"] for e in r["errors"]], ["bad-format"])

    def test_bad_format_begin_missing_zone(self):
        r = zc.parse_text("# >>>", "#")
        self.assertEqual([e["code"] for e in r["errors"]], ["bad-format"])

    def test_unknown_zone(self):
        r = zc.parse_text("# >>> zone:foo", "#")
        self.assertEqual([e["code"] for e in r["errors"]], ["unknown-zone"])


class CoveredTest(unittest.TestCase):
    def setUp(self):
        self.root = make_root({})
        self.cfg = zc.load_config(self.root)

    def test_include_exclude_generated(self):
        self.assertTrue(zc.covered("a.py", self.cfg))
        self.assertTrue(zc.covered("sub/a.py", self.cfg))
        self.assertFalse(zc.covered("excluded/a.py", self.cfg))
        self.assertFalse(zc.covered("gen/a.py", self.cfg))
        self.assertFalse(zc.covered("a.txt", self.cfg))


class JudgeTest(unittest.TestCase):
    HUMAN = "\n".join(["# >>> zone:human", "x = 1", "# <<<", "y = 2"])

    def _judge(self, files, rel, new_text, actor="ai", policy=True):
        root = make_root(files)
        cfg = zc.load_config(root)
        # 前置自检：目标必须在区域纪律内，否则 allow 是因为"没纳入"，判据会静默失效
        self.assertTrue(zc.covered(rel, cfg), f"{rel} 不在区域纪律内 —— 判据会静默 PASS")
        return zc.judge(root, cfg, rel, new_text, actor, policy)

    def test_not_covered_allows_with_reason(self):
        root = make_root({"a.txt": "hello"})
        cfg = zc.load_config(root)
        res, _ = zc.judge(root, cfg, "a.txt", "changed", "ai", True)
        self.assertEqual(res["decision"], "allow")
        self.assertIn("未纳入区域检查范围", res["reason"])

    def test_no_change_allows(self):
        res, _ = self._judge({"a.py": self.HUMAN}, "a.py", self.HUMAN)
        self.assertEqual(res["decision"], "allow")
        self.assertIn("零改动", res["reason"])

    def test_ai_touching_human_denies(self):
        new = self.HUMAN.replace("x = 1", "x = 2")
        res, code = self._judge({"a.py": self.HUMAN}, "a.py", new, actor="ai")
        self.assertEqual(res["decision"], "deny")
        self.assertEqual(code, 1)
        self.assertEqual(res["violations"][0]["code"], "human-touch")
        self.assertIn("human", res["reason"])

    def test_human_touching_human_allows(self):
        new = self.HUMAN.replace("x = 1", "x = 2")
        res, code = self._judge({"a.py": self.HUMAN}, "a.py", new, actor="human")
        self.assertEqual(res["decision"], "allow")
        self.assertEqual(code, 0)

    def test_ai_adding_marker_denies(self):
        base = "y = 2\n"
        new = "# >>> zone:ai\ny = 2\n# <<<\n"
        res, _ = self._judge({"a.py": base}, "a.py", new, actor="ai")
        self.assertEqual(res["decision"], "deny")
        self.assertIn("marker-edit", [v["code"] for v in res["violations"]])

    def test_ai_touching_only_ai_allows(self):
        base = "\n".join(["# >>> zone:ai", "x = 1", "# <<<"])
        new = base.replace("x = 1", "x = 2")
        res, code = self._judge({"a.py": base}, "a.py", new, actor="ai")
        self.assertEqual(res["decision"], "allow")
        self.assertEqual(code, 0)

    def test_legacy_touch_is_warn_not_deny(self):
        res, code = self._judge({"a.py": "a = 1\nb = 2\n"}, "a.py", "a = 1\nb = 3\n", actor="ai")
        self.assertEqual(res["decision"], "allow")
        self.assertEqual(code, 0)
        self.assertEqual(res["violations"][0]["code"], "unmarked-touch")
        self.assertEqual(res["violations"][0]["severity"], "warn")

    def test_judge_without_policy_exits_zero_even_on_deny(self):
        new = self.HUMAN.replace("x = 1", "x = 2")
        res, code = self._judge({"a.py": self.HUMAN}, "a.py", new, actor="ai", policy=False)
        self.assertEqual(res["decision"], "deny")
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
