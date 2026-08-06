import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from packages.catalog import load_catalog, load_package, load_profile, load_profiles
from packages.models import PackageDefinition, PackageTarget, ProfileDefinition, ProfilePackage, ScriptDependencies, ScriptOperation
from packages.planner import PackageResolutionError, resolve_profiles
from packages.providers import plan_execution_steps, plan_provider_operations, preferred_provider
from host import HostPlatform
from system import LinuxDistro, PackageManager, detect_package_platform


class PackagePlanningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.catalog = load_catalog(root / "resources" / "packages")
        cls.profiles = load_profiles(root / "resources" / "profiles")

    def test_complete_desktop_orders_dependencies_before_dependents(self):
        plan = resolve_profiles(["complete-desktop"], self.catalog, self.profiles, "linux", ("apt",))
        self.assertEqual(
            [package.name for package in plan.packages],
            [
                "git", "curl", "ripgrep", "fastfetch", "qdirstat", "baobab", "kate", "konsole", "dolphin",
                "flatpak", "mission-center", "snapd", "bitwarden", "bw", "discord", "variety", "papirus-icon-theme",
                "github-cli", "npm", "codex-cli", "vscode", "kmines", "steam", "libreoffice", "pipx", "konsave",
            ],
        )

    def test_mattos_uses_only_explicit_mattos_profile_and_package_targets(self):
        plan = resolve_profiles(["complete-desktop"], self.catalog, self.profiles, "mattos", ("apt",))
        self.assertEqual(
            [package.name for package in plan.packages],
            ["git", "curl", "ripgrep", "snapd", "bitwarden", "bw", "flatpak", "discord", "github-cli", "npm", "codex-cli", "basalt"],
        )
        platforms_by_package = {package.name: package.target.platform for package in plan.packages}
        self.assertEqual(platforms_by_package["basalt"], "mattos")
        self.assertTrue(all(platform == "mattos" for platform in platforms_by_package.values()))
        self.assertNotIn("qdirstat", platforms_by_package)
        self.assertNotIn("steam", platforms_by_package)
        self.assertNotIn("libreoffice", platforms_by_package)

    def test_mattos_is_detected_as_an_apt_platform(self):
        platform_name = detect_package_platform(
            HostPlatform("linux", "x86_64", "x86_64"),
            LinuxDistro("mattos", "MattOS", "1.0", ("debian",)),
        )
        self.assertEqual(platform_name, "mattos")

    def test_mattos_does_not_fall_back_to_linux_target(self):
        catalog = {
            "mattos-tool": PackageDefinition(
                "mattos-tool",
                "Test MattOS package",
                (),
                ScriptDependencies((), ()),
                (
                    PackageTarget("linux", "apt", "linux-tool", (), {}),
                ),
            )
        }
        profiles = {
            "mattos-test": ProfileDefinition(
                "mattos-test",
                "Test MattOS profile",
                (),
                (),
                {
                    "mattos": (ProfilePackage("mattos-tool", True),),
                },
                (),
            )
        }
        with self.assertRaisesRegex(PackageResolutionError, "No package target is defined for mattos."):
            resolve_profiles(["mattos-test"], catalog, profiles, "mattos", ("apt",))

    def test_required_mattos_package_reports_incompatible_manager(self):
        with self.assertRaisesRegex(
            PackageResolutionError,
            "Package 'git' is not available for the dnf package manager on mattos.",
        ):
            resolve_profiles(["gaming"], self.catalog, self.profiles, "mattos", ("dnf",))

    def test_windows_excludes_linux_only_profile_packages(self):
        plan = resolve_profiles(["complete-desktop"], self.catalog, self.profiles, "windows")
        self.assertEqual(
            [package.name for package in plan.packages],
            ["git", "curl", "ripgrep", "bitwarden", "bw", "discord", "github-cli", "npm", "codex-cli"],
        )
        self.assertEqual(plan.skipped, {})
        self.assertNotIn("flatpak", [package.name for package in plan.packages])
        self.assertNotIn("konsave", [package.name for package in plan.packages])
        self.assertNotIn("steam", [package.name for package in plan.packages])
        self.assertNotIn("libreoffice", [package.name for package in plan.packages])
        self.assertNotIn("mission-center", [package.name for package in plan.packages])

    def test_required_package_without_target_is_rejected(self):
        with self.assertRaises(PackageResolutionError):
            resolve_profiles(["desktop"], self.catalog, self.profiles, "linux", ("apk",))

    def test_dnf_does_not_fall_back_to_apt_target(self):
        with self.assertRaisesRegex(
            PackageResolutionError,
            "Package 'fastfetch' is not available for the dnf package manager on linux.",
        ):
            resolve_profiles(
                ["complete-desktop"],
                self.catalog,
                self.profiles,
                "linux",
                (preferred_provider(PackageManager.DNF),),
            )

    def test_provider_plan_batches_apt_packages(self):
        plan = resolve_profiles(["complete-desktop"], self.catalog, self.profiles, "linux", ("apt",))
        operations = plan_provider_operations(plan.packages, PackageManager.APT)
        self.assertEqual(operations[0].commands[1].argv[:3], ("apt-get", "install", "-y"))
        self.assertIn("pipx", operations[0].commands[1].argv)

    def test_coding_scripts_run_before_profile_and_codex_install(self):
        plan = resolve_profiles(["coding"], self.catalog, self.profiles, "linux", ("apt",))
        steps = plan_execution_steps(plan.packages, plan.profile_scripts, PackageManager.APT)
        self.assertEqual(plan.profile_scripts, ("hello_world.py",))
        self.assertIsInstance(steps[0], ScriptOperation)
        self.assertEqual(steps[0].description, "Run profile dependency script 'hello_world.py'")
        codex_step = next(index for index, step in enumerate(steps) if getattr(step, "packages", ()) == ("codex-cli",))
        self.assertIsInstance(steps[codex_step - 1], ScriptOperation)
        self.assertEqual(steps[codex_step - 1].description, "Run pre-install script for 'codex-cli': hello_world.py")

    def test_linux_profile_removals_run_after_installations(self):
        plan = resolve_profiles(["gaming"], self.catalog, self.profiles, "linux", ("apt",))
        self.assertEqual(plan.delete_packages, (
            "plasma-vault", "krdc", "neochat", "konversation", "skanlite", "akregator", "dragonplayer", "gimp",
            "juk", "kdeconnect", "kmail", "kmouth", "konqueror", "korganizer", "kwrite", "anydesk",
            "kmahjongg", "kpat", "ksudoku", "katawa-shoujo",
        ))
        steps = plan_execution_steps(plan.packages, plan.profile_scripts, PackageManager.APT, plan.delete_packages)
        self.assertEqual(steps[-1].packages, plan.delete_packages)
        self.assertEqual(steps[-1].commands[0].argv[:2], ("bash", "-c"))

    def test_catalog_rejects_unknown_resource_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_path = root / "invalid-package.toml"
            package_path.write_text(
                "[package]\nname = 'invalid'\nunexpected = true\n\n[targets.linux.apt]\nid = 'invalid'\n",
                encoding="utf-8",
            )
            profile_path = root / "invalid-profile.toml"
            profile_path.write_text(
                "[profile]\nname = 'invalid'\nrequired_packages = []\noptional_packages = []\n\n[platforms.linix]\nrequired_packages = []\noptional_packages = []\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "unsupported fields: unexpected"):
                load_package(package_path)
            with self.assertRaisesRegex(ValueError, "unsupported platform 'linix'"):
                load_profile(profile_path)

    def test_unknown_profile_is_rejected(self):
        with self.assertRaises(PackageResolutionError):
            resolve_profiles(["does-not-exist"], self.catalog, self.profiles, "linux", ("apt",))


if __name__ == "__main__":
    unittest.main()