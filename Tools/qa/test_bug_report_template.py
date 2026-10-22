"""Validate the parsed GitHub bug form contract consumed by TestReportLink.

This ports the five former StrandTests/BugReportTemplateTests.swift cases to the source-audit lane.
Reading a repository path from an iOS test sandbox does not reliably reach the source checkout.
PyYAML is a source-audit dependency only; it is not part of the app or its test bundle.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / ".github/ISSUE_TEMPLATE/bug_report.yml"


class BugReportTemplateTests(unittest.TestCase):
    def setUp(self) -> None:
        with TEMPLATE.open(encoding="utf-8") as stream:
            form = yaml.safe_load(stream)
        self.assertIsInstance(form, dict, "the bug form must be a YAML mapping")
        body = form.get("body")
        self.assertIsInstance(body, list, "the bug form must have a body field list")
        self.fields: dict[str, dict] = {}
        for field in body:
            self.assertIsInstance(field, dict, "each body item must be a field mapping")
            if "id" in field:
                identity = field["id"]
                self.assertNotIn(identity, self.fields, f"duplicate form field id: {identity}")
                self.fields[identity] = field

    def field(self, identity: str, kind: str) -> dict:
        self.assertIn(identity, self.fields, f"missing form field: {identity}")
        field = self.fields[identity]
        self.assertEqual(field.get("type"), kind, f"wrong field type for {identity}")
        attributes = field.get("attributes")
        self.assertIsInstance(attributes, dict, f"missing attributes for {identity}")
        return attributes

    def test_has_test_profile_dropdown_with_id(self) -> None:
        self.field("test_profile", "dropdown")

    def test_test_profile_options_cover_all_profiles_plus_escapes(self) -> None:
        options = self.field("test_profile", "dropdown").get("options")
        self.assertIsInstance(options, list)
        expected = {
            "Sleep & Rest", "Connection & Sync", "Workouts & GPS", "Display & Performance",
            "Import & Data Ingest", "Steps", "Notifications, Alarm & Wake", "Battery & Charging",
            "Recovery (Charge)", "HRV & Autonomic", "Sources, Fusion & Metric Decode",
            "Stress & Illness", "Longevity, Cycles & Haptics", "Log everything", "Not a test-mode bug",
        }
        self.assertTrue(expected.issubset(set(options)), f"missing test_profile options: {expected - set(options)}")

    def test_source_dropdown_gains_importers(self) -> None:
        options = self.field("source", "dropdown").get("options")
        self.assertIsInstance(options, list)
        expected = {"Oura import", "Fitbit import", "Garmin import", "Xiaomi import", "FIT / GPX / TCX import"}
        self.assertTrue(expected.issubset(set(options)), f"missing source importer options: {expected - set(options)}")

    def test_log_textarea_tells_to_attach_zip_not_paste(self) -> None:
        description = self.field("log", "textarea").get("description")
        self.assertIsInstance(description, str)
        self.assertIn("Attach your exported", description)
        self.assertIn("Do NOT paste the whole log inline", description)

    def test_attach_zip_checkbox_present(self) -> None:
        options = self.field("checks", "checkboxes").get("options")
        self.assertIsInstance(options, list)
        attachment_options = [
            option for option in options if isinstance(option, dict)
            and "I attached my exported NOOP" in option.get("label", "")
            and "not a screenshot of the Live screen" in option.get("label", "")
        ]
        self.assertEqual(len(attachment_options), 1, "one attachment acknowledgment must be present")
        self.assertIs(attachment_options[0].get("required"), True, "attachment acknowledgment must be required")


if __name__ == "__main__":
    unittest.main()
