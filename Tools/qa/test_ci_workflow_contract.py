"""Workflow behavior checks, including execution of the shipped selector shell.

These tests need Python and PyYAML only. No Xcode, simulator, or hosted runner is used.
"""
from __future__ import annotations

import json
import importlib.util
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


def workflow(name: str) -> dict:
    # BaseLoader keeps GitHub's `on` key a string (YAML 1.1 treats it as a boolean).
    return yaml.load((ROOT / ".github/workflows" / name).read_text(), Loader=yaml.BaseLoader)


def step(identity: str) -> dict:
    return next(item for item in workflow("app-build.yml")["jobs"]["build-and-test"]["steps"]
                if item.get("id") == identity)


class CIWorkflowContractTests(unittest.TestCase):
    def test_pr_checks_run_for_all_paths_and_ready_transition(self) -> None:
        for name in ("app-build.yml", "swift-packages.yml"):
            with self.subTest(workflow=name):
                data = workflow(name)
                self.assertNotIn("paths", data["on"]["pull_request"])
                self.assertIn("ready_for_review", data["on"]["pull_request"]["types"])
                self.assertNotIn("push", data["on"], "PR validation must not run again after merge")
                self.assertEqual(data["permissions"]["contents"], "read")
                self.assertNotIn("pull_request_target", data["on"])

    def test_required_legacy_names_and_docs_use_linux(self) -> None:
        data = workflow("app-build.yml")
        self.assertIn("source-audits", data["jobs"])
        build = data["jobs"]["build-and-test"]
        self.assertIn("ubuntu-latest", build["runs-on"])
        self.assertIn("run_app == 'true'", build["runs-on"])
        self.assertIn("always()", build["if"])
        self.assertIn("Validate app decision", [item.get("name") for item in build["steps"]])
        self.assertEqual(data["jobs"]["source-audits"]["runs-on"], "ubuntu-latest")

    def test_build_products_are_reused_on_one_runner(self) -> None:
        build = step("build")["run"]
        ui_build = step("ui_build")["run"]
        self.assertEqual(build.count("build-for-testing"), 1)
        self.assertEqual(ui_build.count("build-for-testing"), 1)
        self.assertIn("-scheme NOOPiOS", build)
        self.assertIn("-scheme NOOPCoachUI", ui_build)
        for identity in ("build", "native", "ui_build", "ui"):
            script = step(identity)["run"]
            self.assertIn('-derivedDataPath "$RUNNER_TEMP/noop-derived-data"', script)
        self.assertIn("test-without-building", step("native")["run"])
        self.assertIn("test-without-building", step("ui")["run"])
        self.assertNotIn("swift test", (ROOT / ".github/workflows/app-build.yml").read_text())

    def test_full_reuses_one_app_and_one_package_pass(self) -> None:
        data = workflow("noop-full-validation.yml")
        self.assertIn("schedule", data["on"])
        self.assertIn("workflow_dispatch", data["on"])
        self.assertIn("release", data["on"])
        self.assertEqual(data["jobs"]["app"]["uses"], "./.github/workflows/app-build.yml")
        self.assertEqual(data["jobs"]["packages"]["uses"], "./.github/workflows/swift-packages.yml")
        self.assertEqual(data["jobs"]["app"]["with"]["full"], "true")
        self.assertEqual(data["jobs"]["packages"]["with"]["full"], "true")
        gate = data["jobs"]["full-gate"]
        self.assertIn("always()", gate["if"])
        script = "\n".join(item.get("run", "") for item in gate["steps"])
        self.assertIn("validate_gate.py", script)
        self.assertIn('--run-id "$GITHUB_RUN_ID"', script)
        self.assertIn("packages / ", script)

    def test_shadow_gate_observes_actual_jobs_and_package_workflow(self) -> None:
        data = workflow("app-build.yml")
        gate = data["jobs"]["ci-gate"]
        self.assertEqual(gate["name"], "NOOP CI Gate")
        self.assertIn("always()", gate["if"])
        results = data["jobs"]["app-results"]
        self.assertIn("always()", results["if"])
        script = "\n".join(item.get("run", "") for item in results["steps"])
        for result in ("source-audits.result", "build-and-test.result"):
            self.assertIn(result, json.dumps(results))
        self.assertIn('"steps"', script)
        gate_script = "\n".join(item.get("run", "") for item in gate["steps"])
        self.assertIn("wait_for_packages.py", gate_script)
        self.assertIn("validate_gate.py", gate_script)

    def test_result_artifact_binds_attempt_and_preserves_missing_or_failed_outcomes(self) -> None:
        result_steps = workflow("app-build.yml")["jobs"]["app-results"]["steps"]
        script = next(item["run"] for item in result_steps if "run" in item)
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, HEAD_SHA="a" * 40, GITHUB_SHA="b" * 40, GITHUB_EVENT_NAME="pull_request",
                               GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2", PLAN_HASH="fixture-hash",
                               GITHUB_WORKFLOW_REF="eastonplace/noop-ios/.github/workflows/app-build.yml@refs/pull/76/merge",
                               PLAN_RESULT="success", SOURCE_RESULT="success", APP_RESULT="failure",
                               BUILD="success", NATIVE="failure", UI="", SAFETY="success")
            process = subprocess.run(["bash", "-euo", "pipefail", "-c", script], cwd=directory,
                                     env=environment, text=True, capture_output=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            result = json.loads(Path(directory, "qa-artifacts/app-results.json").read_text())
            self.assertEqual((result["run_id"], result["run_attempt"]), (123, 2))
            self.assertEqual(result["workflow_path"], ".github/workflows/app-build.yml")
            self.assertEqual(result["jobs"]["build-and-test"], "failure")
            self.assertEqual(result["steps"]["ui"], "missing")
            self.assertEqual(result["steps"]["native"], "failure")
        for name in ("app-build.yml", "noop-full-validation.yml"):
            for job in workflow(name)["jobs"].values():
                for item in job.get("steps", []):
                    if item.get("uses", "").startswith(("actions/upload-artifact@", "actions/download-artifact@")):
                        self.assertIn("github.run_attempt", item["with"]["name"], "reruns must not consume a previous attempt artifact")

    def run_selector(self, identity: str, selectors: list[str], exit_code: int = 0) -> tuple[subprocess.CompletedProcess, list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            (temporary / "qa-artifacts").mkdir()
            (temporary / "qa-artifacts/change-plan.json").write_text(json.dumps({
                "native_tests": selectors if identity == "native" else ["NOOPiOSTests"],
                "ui_tests": selectors if identity == "ui" else [],
            }))
            binary = temporary / "xcodebuild"
            binary.write_text(f"#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$CAPTURE_ARGS\"\nexit {exit_code}\n")
            binary.chmod(0o755)
            environment = dict(os.environ, RUNNER_TEMP=directory, SIMULATOR_UDID="fixture-phone",
                               CAPTURE_ARGS=str(temporary / "arguments"), PATH=f"{directory}:{os.environ['PATH']}")
            process = subprocess.run(["bash", "-euo", "pipefail", "-c", step(identity)["run"]],
                                     cwd=directory, env=environment, text=True, capture_output=True)
            arguments = (temporary / "arguments").read_text().splitlines() if (temporary / "arguments").exists() else []
            return process, arguments

    def test_native_shell_preserves_exact_selected_scope(self) -> None:
        selectors = ["NOOPiOSTests/BLELinkEpitaphTests/testFailedConnectAttemptEmitsNothing"]
        process, arguments = self.run_selector("native", selectors)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual([arg for arg in arguments if arg.startswith("-only-testing:")],
                         [f"-only-testing:{selector}" for selector in selectors])
        self.assertIn("test-without-building", arguments)

    def test_full_ui_shell_does_not_freeze_a_historical_class_allowlist(self) -> None:
        selectors = []
        for source in sorted((ROOT / "StrandiOSUITests").glob("*.swift")):
            text = source.read_text()
            match = re.search(r"final class\s+(\w+)\s*:\s*XCTestCase", text)
            if match:
                selectors.extend(f"NOOPCoachUITests/{match.group(1)}/{method}"
                                 for method in re.findall(r"\bfunc\s+(test\w+)\s*\(", text))
        self.assertEqual(len(selectors), 49, "update this deliberate inventory check when UI coverage changes")
        process, arguments = self.run_selector("ui", selectors)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual([arg for arg in arguments if arg.startswith("-only-testing:")],
                         [f"-only-testing:{selector}" for selector in selectors])

    def test_selector_shell_fails_before_xcode_for_empty_or_injected_scope(self) -> None:
        for identity, selectors in (("native", []), ("ui", []),
                                    ("native", ["NOOPiOSTests\n-skip-testing:NOOPiOSTests"]),
                                    ("ui", ["AnotherTarget/Unknown/testNoop"])):
            with self.subTest(identity=identity, selectors=selectors):
                process, arguments = self.run_selector(identity, selectors)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(arguments, [])

    def test_xcode_failure_survives_logging_pipeline(self) -> None:
        process, arguments = self.run_selector("ui", ["NOOPCoachUITests/ApprovedDashboardUITests/testTodayNormal"], exit_code=42)
        self.assertEqual(process.returncode, 42)
        self.assertEqual(len([arg for arg in arguments if arg.startswith("-only-testing:")]), 1)

    def test_native_failure_stops_expensive_ui_work(self) -> None:
        self.assertIn("steps.native.outcome == 'success'", step("ui")["if"])
        self.assertIn("steps.native.outcome == 'success'", step("ui_build")["if"])
        self.assertIn("steps.ui_build.outcome == 'success'", step("ui")["if"])

    def test_each_scheme_executes_before_another_build_can_replace_its_host(self) -> None:
        """The UI scheme changes static/dynamic package linkage in the shared app host."""
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            (temporary / "qa-artifacts").mkdir()
            (temporary / "qa-artifacts/change-plan.json").write_text(json.dumps({
                "native_tests": ["NOOPiOSTests"],
                "ui_tests": ["NOOPCoachUITests/ApprovedDashboardUITests/testTodayNormal"],
            }))
            binary = temporary / "xcodebuild"
            binary.write_text('''#!/bin/bash
set -euo pipefail
scheme=''
action=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -scheme) scheme=$2; shift ;;
    build-for-testing|test-without-building) action=$1 ;;
  esac
  shift
done
printf '%s %s\\n' "$scheme" "$action" >> "$RUNNER_TEMP/commands"
if [[ "$action" == build-for-testing ]]; then
  printf '%s' "$scheme" > "$RUNNER_TEMP/host-built-for"
elif [[ "$(cat "$RUNNER_TEMP/host-built-for")" != "$scheme" ]]; then
  echo 'The shared test host was overwritten by another scheme' >&2
  exit 77
fi
''')
            binary.chmod(0o755)
            environment = dict(os.environ, RUNNER_TEMP=directory, SIMULATOR_UDID="fixture-phone",
                               UI_TESTS='["NOOPCoachUITests/ApprovedDashboardUITests/testTodayNormal"]',
                               PATH=f"{directory}:{os.environ['PATH']}")
            steps = workflow("app-build.yml")["jobs"]["build-and-test"]["steps"]
            for item in steps:
                if item.get("id") not in {"build", "native", "ui_build", "ui"}:
                    continue
                process = subprocess.run(["bash", "-euo", "pipefail", "-c", item["run"]], cwd=directory,
                                         env=environment, text=True, capture_output=True)
                self.assertEqual(process.returncode, 0, f"{item['id']}: {process.stderr}")
            self.assertEqual((temporary / "commands").read_text().splitlines(), [
                "NOOPiOS build-for-testing", "NOOPiOS test-without-building",
                "NOOPCoachUI build-for-testing", "NOOPCoachUI test-without-building",
            ])

    def test_gate_executes_protected_pair_and_rejects_partial_policy(self) -> None:
        gate_steps = workflow("app-build.yml")["jobs"]["ci-gate"]["steps"]
        script = next(item["run"] for item in gate_steps if "run" in item)
        marker = 'python3 -I "$gate_policy_dir/wait_for_packages.py"'
        self.assertIn(marker, script)
        extraction = script.split(marker, 1)[0]
        for protected in ((), ("validate_gate.py",), ("validate_gate.py", "wait_for_packages.py")):
            with self.subTest(protected=protected), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                def git(*arguments: str) -> str:
                    return subprocess.run(["git", *arguments], cwd=directory, check=True,
                                          text=True, capture_output=True).stdout.strip()
                git("init", "-q")
                (temporary / "README").write_text("fixture")
                tools = temporary / "Tools/ci"
                tools.mkdir(parents=True)
                for filename in protected:
                    (tools / filename).write_text("protected base policy\n")
                git("add", ".")
                git("-c", "user.name=CI Test", "-c", "user.email=ci@example.invalid", "commit", "-qm", "base")
                base = git("rev-parse", "HEAD")
                for filename in ("validate_gate.py", "wait_for_packages.py"):
                    (tools / filename).write_text("PR working tree policy\n")
                environment = dict(os.environ, RUNNER_TEMP=directory, BASE_SHA=base)
                process = subprocess.run(["bash", "-euo", "pipefail", "-c", extraction], cwd=directory,
                                         env=environment, text=True, capture_output=True)
                if len(protected) == 1:
                    self.assertNotEqual(process.returncode, 0, "a partial protected policy must not bootstrap")
                else:
                    self.assertEqual(process.returncode, 0, process.stderr)
                    expected = "protected base policy\n" if protected else "PR working tree policy\n"
                    for filename in ("validate_gate.py", "wait_for_packages.py"):
                        self.assertEqual((temporary / "noop-protected-gate" / filename).read_text(), expected)

    def test_app_skip_requires_validated_docs_plan_and_successful_audits(self) -> None:
        valid_plan = {"mode": "docs", "run_app": False, "native_level": "none", "native_tests": [], "ui_tests": [],
                      "head_sha": "a" * 40, "tested_sha": "b" * 40}
        cases = [({}, {}, True), ({"mode": "ui"}, {}, False),
                 ({"ui_tests": ["NOOPCoachUITests/SomeTests/testRequired"]}, {}, False),
                 ({}, {"PLAN_RESULT": "failure"}, False), ({}, {"AUDIT_RESULT": "cancelled"}, False),
                 ({"tested_sha": "c" * 40}, {}, False), ({}, {"CHECKOUT_SHA": "c" * 40}, False)]
        decision = next(item for item in workflow("app-build.yml")["jobs"]["build-and-test"]["steps"]
                        if item.get("name") == "Validate app decision")["run"]
        for edits, overrides, passes in cases:
            with self.subTest(edits=edits, overrides=overrides), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                plan = dict(valid_plan, **edits)
                digest = hashlib.sha256(json.dumps(plan, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
                plan['plan_hash'] = digest
                (temporary / "qa-artifacts").mkdir()
                (temporary / "qa-artifacts/change-plan.json").write_text(json.dumps(plan))
                git = temporary / "git"
                git.write_text('#!/bin/bash\nprintf "%s\\n" "$CHECKOUT_SHA"\n')
                git.chmod(0o755)
                environment = dict(os.environ, PLAN_RESULT="success", AUDIT_RESULT="success", EXPECTED_RUN_APP="false",
                                   EXPECTED_HASH=digest, EXPECTED_HEAD="a" * 40, GITHUB_SHA="b" * 40,
                                   CHECKOUT_SHA="b" * 40, PATH=f"{directory}:{os.environ['PATH']}")
                environment.update(overrides)
                process = subprocess.run(["bash", "-euo", "pipefail", "-c", decision], cwd=directory,
                                         env=environment, text=True, capture_output=True)
                self.assertEqual(process.returncode == 0, passes, process.stderr)

    def test_every_embedded_shell_parses(self) -> None:
        for name in ("app-build.yml", "noop-full-validation.yml"):
            for job in workflow(name)["jobs"].values():
                for item in job.get("steps", []):
                    if "run" in item:
                        process = subprocess.run(["bash", "-n"], input=item["run"], text=True, capture_output=True)
                        self.assertEqual(process.returncode, 0, f"{name}: {item.get('name')}: {process.stderr}")

    def test_source_audit_rejects_duplicate_or_missing_authoritative_package_pass(self) -> None:
        spec = importlib.util.spec_from_file_location("source_contract_audit", ROOT / "Tools/qa/source_contract_audit.py")
        audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(audit)
        app = (ROOT / ".github/workflows/app-build.yml").read_text()
        packages = (ROOT / ".github/workflows/swift-packages.yml").read_text()
        self.assertEqual(audit.ci_workflow_findings(app, packages), [])
        duplicate = yaml.load(app, Loader=yaml.BaseLoader)
        duplicate['jobs']['build-and-test']['steps'].append({'run': 'swift test --package-path Packages/WhoopStore'})
        self.assertTrue(audit.ci_workflow_findings(yaml.safe_dump(duplicate), packages))
        self.assertTrue(audit.ci_workflow_findings(app, packages.replace("swift test", "echo skipped")))
        self.assertTrue(audit.ci_workflow_findings(app.replace("wait_for_packages.py", "unobserved.py"), packages))


if __name__ == "__main__":
    unittest.main()
