"""Check the resolved signing and URL-registration contracts, without generating files."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def project(spec):
    return json.loads(subprocess.check_output(
        ["xcodegen", "dump", "--spec", str(ROOT / spec), "--type", "json"],
        text=True,
    ))["targets"]["Happier"]


class BrowserProjectTests(unittest.TestCase):
    def test_standard_build_keeps_universal_links_without_restricted_entitlement(self):
        target = project("project.yml")
        entitlements = target["entitlements"]["properties"]
        self.assertNotIn("com.apple.developer.web-browser", entitlements)
        self.assertIn("applinks:happier.nomada.cloud", entitlements["com.apple.developer.associated-domains"])
        self.assertFalse(target["info"]["properties"].get("HappierBrowserRole", False))

    def test_browser_build_registers_web_urls_and_preserves_native_links(self):
        target = project("project.browser-ios.yml")
        entitlements = target["entitlements"]["properties"]
        self.assertIs(entitlements.get("com.apple.developer.web-browser"), True)
        self.assertEqual(entitlements.get("com.apple.developer.associated-domains", []), [])
        info = target["info"]["properties"]
        schemes = {scheme for item in info["CFBundleURLTypes"] for scheme in item["CFBundleURLSchemes"]}
        self.assertTrue({"http", "https", "happier-native"}.issubset(schemes))
        self.assertIs(info.get("HappierBrowserRole"), True)
        self.assertEqual(target["supportedDestinations"], ["iOS"])
        # The browser capability must not drop push, app groups, or sandbox permissions.
        standard = project("project.yml")["entitlements"]["properties"]
        for key, value in standard.items():
            if key != "com.apple.developer.associated-domains":
                self.assertEqual(entitlements[key], value)


if __name__ == "__main__":
    unittest.main()
