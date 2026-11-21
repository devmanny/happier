"""Check resolved signing and URL-registration contracts without modifying source plists."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
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

    def test_macos_browser_registers_web_urls_and_sets_browser_role(self):
        target = project("project.browser-macos.yml")
        info = target["info"]["properties"]
        schemes = {scheme for item in info["CFBundleURLTypes"] for scheme in item["CFBundleURLSchemes"]}
        self.assertTrue({"http", "https", "happier-native"}.issubset(schemes))
        self.assertIs(info.get("HappierBrowserRole"), True)
        self.assertEqual(target["supportedDestinations"], ["macOS"])

    def test_macos_browser_signing_adds_only_the_passkey_capability(self):
        target = project("project.browser-macos.yml")
        standard_target = project("project.yml")
        setting = "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"
        standard_path = ROOT / standard_target["settings"]["base"][setting]
        standard = plistlib.loads(standard_path.read_bytes())
        capability = "com.apple.developer.web-browser.public-key-credential"
        self.assertNotIn(capability, standard)

        with tempfile.TemporaryDirectory() as generated:
            def resolve(value):
                return value.replace("$(SRCROOT)", str(ROOT)).replace("$(DERIVED_FILE_DIR)", generated)

            # Execute the actual build-phase generator against the canonical macOS plist.
            for step in target.get("preBuildScripts", []):
                env = dict(os.environ)
                for kind in ("INPUT", "OUTPUT"):
                    for index, path in enumerate(step.get(kind.lower() + "Files", [])):
                        env[f"SCRIPT_{kind}_FILE_{index}"] = resolve(path)
                subprocess.run(["/bin/sh", "-c", step["script"]], cwd=ROOT, env=env, check=True)
            signed_path = ROOT / resolve(target["settings"]["base"][setting])
            signed = plistlib.loads(signed_path.read_bytes())

        self.assertIs(signed.get(capability), True)
        self.assertEqual({key: value for key, value in signed.items() if key != capability}, standard)
        self.assertEqual(plistlib.loads(standard_path.read_bytes()), standard)


if __name__ == "__main__":
    unittest.main()
