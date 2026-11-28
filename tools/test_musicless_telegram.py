import unittest

import musicless_telegram as mt

ASSETS = [{"name": f"NewTube_1.17.1-musicless.5_{abi}.apk", "size": size, "url": f"https://x/{abi}"}
          for abi, size in [("universal", 131912977), ("x86", 92941651),
                            ("armeabi-v7a", 65164091), ("arm64-v8a", 84855907)]]
ASSETS.append({"name": "musicless.json", "size": 1933, "url": "https://x/json"})
RELEASE = {"tagName": "v1.17.1-musicless.5", "url": "https://x/release", "assets": ASSETS}


class MusiclessTelegramTest(unittest.TestCase):
    def test_links_every_apk_recommended_first(self):
        text = mt.message(RELEASE, ["سطر"])
        self.assertLess(text.index("https://x/arm64-v8a"), text.index("https://x/armeabi-v7a"))
        self.assertLess(text.index("https://x/universal"), text.index("https://x/x86"))
        self.assertIn("81 MB", text)
        self.assertNotIn("https://x/json", text)
        self.assertIn("https://yshalsager.github.io/newtube-musicless/", text)

    def test_notes_are_escaped(self):
        text = mt.message(RELEASE, ['زر «<b>» & "x"'])
        self.assertIn("&lt;b&gt;", text)
        self.assertIn("&amp;", text)

    def test_arabic_changelog_else_english(self):
        manifest = {"1.17.1-musicless.5": {"changelog": ["en"], "changelog_ar": ["ar"]}}
        self.assertEqual(mt.changelog(manifest, "1.17.1-musicless.5"), ["ar"])
        self.assertEqual(mt.changelog({"1.17.1-musicless.5": {"changelog": ["en"]}}, "1.17.1-musicless.5"), ["en"])
        self.assertEqual(mt.changelog({}, "1.17.1-musicless.5"), [])

    def test_long_changelog_fits_telegram(self):
        text = mt.message(RELEASE, ["س" * 300] * 30)
        self.assertLessEqual(len(text), mt.MAX_TEXT)
        self.assertIn("• …", text)
        self.assertIn("https://x/release", text)

    def test_no_changelog_still_links(self):
        text = mt.message(RELEASE, [])
        self.assertNotIn("الجديد", text)
        self.assertIn("https://x/arm64-v8a", text)


if __name__ == "__main__":
    unittest.main()
