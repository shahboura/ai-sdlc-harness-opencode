"""Format validation for opencode distribution files (.opencode/).

Ensures every file in the opencode plugin distribution conforms to the
format opencode expects at load time. Catches structural regressions
before they reach a user's opencode session.

Checked for each opencode artifact type:

  opencode.jsonc        valid JSONC, required fields, agent no tools: format
  .opencode/agents/     valid YAML frontmatter, permission: block, no tools:
  .opencode/commands/   valid YAML frontmatter with description/agent/model
  .opencode/skills/*/SKILL.md  valid YAML frontmatter with name/version/author
  .opencode/plugins/    default-export Plugin function, tsc --noEmit passes
  versions.json         valid JSON, version consistent with opencode.jsonc
  package.json          name/version/files fields present
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
OPCODE = ROOT / ".opencode"
AGENTS = OPCODE / "agents"
COMMANDS = OPCODE / "commands"
SKILLS = OPCODE / "skills"
PLUGINS = OPCODE / "plugins"

# ── helpers ─────────────────────────────────────────────────────────------


def strip_jsonc_comments(text: str) -> str:
    """Remove // and /* */ comments from JSONC text (single-pass regex)."""
    # Remove // line comments (not inside strings — naive but sufficient
    # for our config files which have no string-embedded // patterns)
    text = re.sub(r"(?m)^\s*//.*$", "", text)
    # Remove /* */ block comments (non-greedy, multi-line)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return text


def load_yaml_frontmatter(path: Path) -> dict | None:
    """Parse YAML frontmatter (--- ... ---) from a markdown file."""
    text = path.read_text(encoding="utf-8")
    m = re.match(r"^---\s*\n(.*?)\n---", text, re.DOTALL)
    if not m:
        return None
    return yaml.safe_load(m.group(1))


def required_subdirs(parent: Path) -> list[str]:
    """List immediate subdirectories of parent."""
    return sorted(d.name for d in parent.iterdir() if d.is_dir())


# ── tests ─────────────────────────────────────────────────────────────────


class OpencodeJsoncFormat(unittest.TestCase):
    """opencode.jsonc — project root config."""

    def setUp(self):
        self.path = ROOT / "opencode.jsonc"
        raw = strip_jsonc_comments(self.path.read_text(encoding="utf-8"))
        self.cfg = json.loads(raw)

    def test_is_valid_jsonc(self):
        self.assertTrue(isinstance(self.cfg, dict))

    def test_has_required_fields(self):
        for field in ("name", "version", "agent", "plugin"):
            self.assertIn(field, self.cfg,
                          f"opencode.jsonc missing required field '{field}'")

    def test_no_deprecated_tools_format(self):
        """Agents must use 'permission:' format, NOT the deprecated 'tools:'
        key name. See opencode agent format documentation."""
        for name, agent_cfg in self.cfg.get("agent", {}).items():
            self.assertNotIn(
                "tools", agent_cfg,
                f"agent '{name}' uses deprecated 'tools:' format — "
                f"use 'permission:' instead")

    def test_plugin_references_local_or_published(self):
        plugins = self.cfg.get("plugin", [])
        self.assertTrue(len(plugins) >= 1,
                        "opencode.jsonc must define at least one plugin")
        for p in plugins:
            self.assertIsInstance(p, str)

    def test_version_is_string(self):
        v = self.cfg.get("version", "")
        self.assertIsInstance(v, str)
        self.assertRegex(v, r"^\d+\.\d+\.\d+$",
                         "version must be semver (x.y.z)")


class VersionsJsonConsistency(unittest.TestCase):
    """versions.json — single source of truth for version numbers."""

    def setUp(self):
        versions_path = ROOT / "versions.json"
        package_path = ROOT / "package.json"
        opencode_path = ROOT / "opencode.jsonc"

        self.versions = json.loads(versions_path.read_text(encoding="utf-8"))
        self.package = json.loads(package_path.read_text(encoding="utf-8"))
        raw = strip_jsonc_comments(opencode_path.read_text(encoding="utf-8"))
        self.opencode_cfg = json.loads(raw)

    def test_versions_json_is_valid(self):
        self.assertIn("version", self.versions)

    def test_version_consistent_across_files(self):
        v = self.versions["version"]
        self.assertEqual(v, self.package["version"],
                         f"versions.json ({v}) != package.json "
                         f"({self.package['version']})")
        self.assertEqual(v, self.opencode_cfg["version"],
                         f"versions.json ({v}) != opencode.jsonc "
                         f"({self.opencode_cfg['version']})")


class OpencodeDirectoryStructure(unittest.TestCase):
    """.opencode/ directory must have expected subdirs."""

    def test_agents_dir_exists(self):
        self.assertTrue(AGENTS.is_dir())

    def test_commands_dir_exists(self):
        self.assertTrue(COMMANDS.is_dir())

    def test_skills_dir_exists(self):
        self.assertTrue(SKILLS.is_dir())

    def test_plugins_dir_exists(self):
        self.assertTrue(PLUGINS.is_dir())

    def test_agents_have_files(self):
        files = list(AGENTS.glob("*.md"))
        self.assertTrue(len(files) >= 3,  # planner, developer, reviewer
                        f".opencode/agents/ has only {len(files)} files")

    def test_commands_have_files(self):
        files = list(COMMANDS.glob("*.md"))
        self.assertTrue(len(files) >= 8,
                        f".opencode/commands/ has only {len(files)} files")

    def test_skills_have_subdirs(self):
        dirs = [d for d in SKILLS.iterdir() if d.is_dir()]
        self.assertTrue(len(dirs) >= 7,
                        f".opencode/skills/ has only {len(dirs)} subdirs")


class AgentFileFrontmatter(unittest.TestCase):
    """Every .opencode/agents/*.md must have valid YAML frontmatter with
    permission: block and no tools: key."""

    def test_all_agent_files_have_frontmatter(self):
        bad = []
        for f in sorted(AGENTS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm:
                bad.append(f.name)
        self.assertFalse(bad, f"agents missing frontmatter: {bad}")

    def test_all_have_description(self):
        bad = []
        for f in sorted(AGENTS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm or "description" not in fm:
                bad.append(f.name)
        self.assertFalse(bad, f"agents missing 'description': {bad}")

    def test_all_have_mode(self):
        bad = []
        for f in sorted(AGENTS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm or "mode" not in fm:
                bad.append(f.name)
        self.assertFalse(bad, f"agents missing 'mode': {bad}")

    def test_all_have_model(self):
        bad = []
        for f in sorted(AGENTS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm or "model" not in fm:
                bad.append(f.name)
        self.assertFalse(bad, f"agents missing 'model': {bad}")

    def test_all_have_permission_block(self):
        bad = []
        for f in sorted(AGENTS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm or "permission" not in fm:
                bad.append(f.name)
        self.assertFalse(bad, f"agents missing 'permission': {bad}")

    def test_no_deprecated_tools_format(self):
        """Agent instruction files must NOT use the deprecated 'tools:' key
        name — use 'permission:' instead."""
        bad = []
        for f in sorted(AGENTS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if fm and "tools" in fm:
                bad.append(f.name)
        self.assertFalse(
            bad, f"agents use deprecated 'tools:' (use 'permission:'): {bad}")

    def test_mode_is_primary_or_subagent(self):
        bad = []
        for f in sorted(AGENTS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if fm and fm.get("mode") not in ("primary", "subagent"):
                bad.append((f.name, fm.get("mode")))
        self.assertFalse(
            bad, f"agents have invalid mode (must be 'primary'/'subagent'): {bad}")


class CommandFileFrontmatter(unittest.TestCase):
    """Every .opencode/commands/*.md must have YAML frontmatter with
    description, agent, and model fields."""

    def test_all_command_files_have_frontmatter(self):
        bad = []
        for f in sorted(COMMANDS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm:
                bad.append(f.name)
        self.assertFalse(bad, f"commands missing frontmatter: {bad}")

    def test_all_have_description(self):
        bad = []
        for f in sorted(COMMANDS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm or "description" not in fm:
                bad.append(f.name)
        self.assertFalse(bad, f"commands missing 'description': {bad}")

    def test_all_have_agent(self):
        bad = []
        for f in sorted(COMMANDS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm or "agent" not in fm:
                bad.append(f.name)
        self.assertFalse(bad, f"commands missing 'agent': {bad}")

    def test_all_have_model(self):
        bad = []
        for f in sorted(COMMANDS.glob("*.md")):
            fm = load_yaml_frontmatter(f)
            if not fm or "model" not in fm:
                bad.append(f.name)
        self.assertFalse(bad, f"commands missing 'model': {bad}")


class SkillFileFrontmatter(unittest.TestCase):
    """Every .opencode/skills/*/SKILL.md must have YAML frontmatter with
    name, description, version, and author fields."""

    def test_all_skill_dirs_have_skilL_md(self):
        bad = []
        for d in sorted(SKILLS.iterdir()):
            if d.is_dir():
                skill_md = d / "SKILL.md"
                if not skill_md.is_file():
                    bad.append(d.name)
        self.assertFalse(bad, f"skill dirs missing SKILL.md: {bad}")

    def test_all_skilL_md_have_frontmatter(self):
        bad = []
        for d in sorted(SKILLS.iterdir()):
            if not d.is_dir():
                continue
            skill_md = d / "SKILL.md"
            if not skill_md.is_file():
                continue
            fm = load_yaml_frontmatter(skill_md)
            if not fm:
                bad.append(d.name)
        self.assertFalse(bad, f"SKILL.md files missing frontmatter: {bad}")

    def test_all_have_name(self):
        bad = []
        for d in sorted(SKILLS.iterdir()):
            if not d.is_dir():
                continue
            skill_md = d / "SKILL.md"
            if not skill_md.is_file():
                continue
            fm = load_yaml_frontmatter(skill_md)
            if not fm or "name" not in fm:
                bad.append(d.name)
        self.assertFalse(bad, f"SKILL.md missing 'name': {bad}")

    def test_all_have_description(self):
        bad = []
        for d in sorted(SKILLS.iterdir()):
            if not d.is_dir():
                continue
            skill_md = d / "SKILL.md"
            if not skill_md.is_file():
                continue
            fm = load_yaml_frontmatter(skill_md)
            if not fm or "description" not in fm:
                bad.append(d.name)
        self.assertFalse(bad, f"SKILL.md missing 'description': {bad}")

    def test_all_have_version(self):
        bad = []
        for d in sorted(SKILLS.iterdir()):
            if not d.is_dir():
                continue
            skill_md = d / "SKILL.md"
            if not skill_md.is_file():
                continue
            fm = load_yaml_frontmatter(skill_md)
            if not fm or "version" not in fm:
                bad.append(d.name)
        self.assertFalse(bad, f"SKILL.md missing 'version': {bad}")

    def test_all_have_author(self):
        bad = []
        for d in sorted(SKILLS.iterdir()):
            if not d.is_dir():
                continue
            skill_md = d / "SKILL.md"
            if not skill_md.is_file():
                continue
            fm = load_yaml_frontmatter(skill_md)
            if not fm or "author" not in fm:
                bad.append(d.name)
        self.assertFalse(bad, f"SKILL.md missing 'author': {bad}")


class PluginTypeScript(unittest.TestCase):
    """.opencode/plugins/ TypeScript files — compilation and export format."""

    def test_plugin_ts_files_exist(self):
        ts_files = list(PLUGINS.glob("*.ts"))
        self.assertTrue(len(ts_files) >= 1,
                        f".opencode/plugins/ has no .ts files")

    def test_plugin_exports_default(self):
        """Verify each plugin .ts file contains `export default`."""
        bad = []
        for f in sorted(PLUGINS.glob("*.ts")):
            text = f.read_text(encoding="utf-8")
            if "export default" not in text:
                bad.append(f.name)
        self.assertFalse(bad, f"plugin .ts files missing 'export default': {bad}")

    def test_plugin_imports_plugin_type(self):
        """Each plugin should import from @opencode-ai/plugin."""
        bad = []
        for f in sorted(PLUGINS.glob("*.ts")):
            text = f.read_text(encoding="utf-8")
            if "from \"@opencode-ai/plugin\"" not in text:
                bad.append(f.name)
        self.assertFalse(bad,
                         f"plugin .ts files must import from "
                         f"@opencode-ai/plugin: {bad}")

    def test_tsc_compiles_with_no_emit(self):
        """Run tsc --noEmit to verify all .opencode/ TypeScript compiles.
        This validates type correctness of the plugin bridge."""
        tsconfig = OPCODE / "tsconfig.json"
        if not tsconfig.is_file():
            self.skipTest("no .opencode/tsconfig.json")
        try:
            proc = subprocess.run(
                [self._tsc_bin(), "--noEmit", "--project", str(tsconfig)],
                capture_output=True, text=True, timeout=60,
                cwd=str(OPCODE),
            )
            if proc.returncode != 0:
                self.fail(
                    f"tsc --noEmit failed (exit {proc.returncode}):\n"
                    f"{proc.stdout}\n{proc.stderr}"
                )
        except FileNotFoundError:
            self.skipTest("tsc not on PATH — cannot verify compilation")

    @staticmethod
    def _tsc_bin() -> str:
        """Resolve tsc binary, preferring local node_modules."""
        local = OPCODE / "node_modules" / ".bin" / "tsc"
        if local.is_file():
            return str(local)
        # Fall back to PATH
        return "tsc"


class PackageJsonFormat(unittest.TestCase):
    """package.json — npm distribution metadata."""

    def setUp(self):
        self.path = ROOT / "package.json"
        self.pkg = json.loads(self.path.read_text(encoding="utf-8"))

    def test_has_name(self):
        self.assertIn("name", self.pkg)

    def test_has_version(self):
        self.assertIn("version", self.pkg)

    def test_has_files_include_opencode(self):
        files = self.pkg.get("files", [])
        self.assertTrue(
            any(f.startswith(".opencode/") for f in files),
            "package.json 'files' must include .opencode/ subdirectories")

    def test_files_do_not_include_node_modules(self):
        """npm pack must NOT include node_modules — they're dev deps for
        type-checking only. opencode loads .ts plugins with its own Bun
        runtime."""
        for f in self.pkg.get("files", []):
            self.assertNotIn("node_modules", f,
                             f"npm package must not include node_modules: {f}")

    def test_files_list_is_reasonable_size(self):
        """Sanity check: the files list should be specific paths, not
        a single broad glob that would pull in node_modules."""
        files = self.pkg.get("files", [])
        self.assertGreaterEqual(len(files), 5,
                                "files list should have at least 5 entries"
                                "(agents, commands, plugins, skills, etc.)")

    def test_has_repository(self):
        self.assertIn("repository", self.pkg)

    def test_has_license(self):
        self.assertIn("license", self.pkg)


if __name__ == "__main__":
    unittest.main()
