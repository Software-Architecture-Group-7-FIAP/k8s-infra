import json
import tempfile
import unittest
from argparse import Namespace
from datetime import datetime, timedelta, timezone
from pathlib import Path

from terraform_plan_artifact import (
    PlanArtifactError,
    create_attestation,
    create_manifest,
    verify_attestation,
    verify_manifest,
)


class TerraformPlanArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp_directory.name)
        self.plan_file = self.directory / "foundation.tfplan"
        self.plan_file.write_bytes(b"saved Terraform plan fixture")
        self.manifest_file = self.directory / "manifest.json"
        self.attestation_file = self.directory / "manifest.sha256"
        self.session_started_at = (datetime.now(timezone.utc) - timedelta(minutes=1)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )

    def tearDown(self) -> None:
        self.temp_directory.cleanup()

    def create(self, *, plan_id: str = "123456-1") -> None:
        create_manifest(
            Namespace(
                plan_id=plan_id,
                purpose="apply",
                aws_account_id="035611741563",
                aws_region="us-east-1",
                commit_sha="a" * 40,
                session_id="phase-3-session",
                session_started_at=self.session_started_at,
                terraform_version="1.15.8",
                output=str(self.manifest_file),
                plan=[f"foundation={self.plan_file}"],
            )
        )

    def verify(self, *, plan_id: str = "123456-1", stack: str = "foundation") -> None:
        verify_manifest(
            Namespace(
                manifest=str(self.manifest_file),
                plan_file=str(self.plan_file),
                plan_id=plan_id,
                purpose="apply",
                aws_account_id="035611741563",
                aws_region="us-east-1",
                stack=stack,
                commit_sha="a" * 40,
                session_id="phase-3-session",
                session_started_at=self.session_started_at,
                terraform_version="1.15.8",
            )
        )

    def test_round_trip_records_scope_and_verifies_checksum(self) -> None:
        self.create()

        manifest = json.loads(self.manifest_file.read_text(encoding="utf-8"))
        self.assertEqual(manifest["aws_account_id"], "035611741563")
        self.assertEqual(manifest["aws_region"], "us-east-1")
        self.assertEqual(set(manifest["plans"]), {"foundation"})
        self.verify()

    def test_rejects_a_changed_plan_file(self) -> None:
        self.create()
        self.plan_file.write_bytes(b"changed plan")

        with self.assertRaisesRegex(PlanArtifactError, "checksum"):
            self.verify()

    def test_rejects_a_different_commit(self) -> None:
        self.create()
        arguments = Namespace(
            manifest=str(self.manifest_file),
            plan_file=str(self.plan_file),
            plan_id="123456-1",
            purpose="apply",
            aws_account_id="035611741563",
            aws_region="us-east-1",
            stack="foundation",
            commit_sha="b" * 40,
            session_id="phase-3-session",
            session_started_at=self.session_started_at,
            terraform_version="1.15.8",
        )

        with self.assertRaisesRegex(PlanArtifactError, "commit_sha"):
            verify_manifest(arguments)

    def test_rejects_a_different_aws_account(self) -> None:
        self.create()
        arguments = Namespace(
            manifest=str(self.manifest_file),
            plan_file=str(self.plan_file),
            plan_id="123456-1",
            purpose="apply",
            aws_account_id="999999999999",
            aws_region="us-east-1",
            stack="foundation",
            commit_sha="a" * 40,
            session_id="phase-3-session",
            session_started_at=self.session_started_at,
            terraform_version="1.15.8",
        )

        with self.assertRaisesRegex(PlanArtifactError, "aws_account_id"):
            verify_manifest(arguments)

    def test_rejects_an_unrequested_stack_in_manifest(self) -> None:
        self.create()
        manifest = json.loads(self.manifest_file.read_text(encoding="utf-8"))
        manifest["plans"]["platform"] = {
            "file": "platform.tfplan",
            "sha256": "0" * 64,
        }
        self.manifest_file.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(PlanArtifactError, "only the requested"):
            self.verify()

    def test_rejects_a_plan_id_that_cannot_form_a_safe_s3_key(self) -> None:
        with self.assertRaisesRegex(PlanArtifactError, "plan_id"):
            self.create(plan_id="../../other-prefix")

    def test_manifest_attestation_round_trip_uses_the_exact_file_bytes(self) -> None:
        self.create()
        create_attestation(
            Namespace(manifest=str(self.manifest_file), output=str(self.attestation_file))
        )

        result = verify_attestation(
            Namespace(manifest=str(self.manifest_file), attestation=str(self.attestation_file))
        )

        self.assertEqual(result, 0)

    def test_manifest_attestation_rejects_a_replaced_manifest(self) -> None:
        self.create()
        create_attestation(
            Namespace(manifest=str(self.manifest_file), output=str(self.attestation_file))
        )
        self.manifest_file.write_text('{"plans":{}}', encoding="utf-8")

        with self.assertRaisesRegex(PlanArtifactError, "does not match"):
            verify_attestation(
                Namespace(manifest=str(self.manifest_file), attestation=str(self.attestation_file))
            )

    def test_manifest_attestation_rejects_malformed_digest(self) -> None:
        self.create()
        self.attestation_file.write_text("not-a-digest\n", encoding="ascii")

        with self.assertRaisesRegex(PlanArtifactError, "one SHA-256 digest"):
            verify_attestation(
                Namespace(manifest=str(self.manifest_file), attestation=str(self.attestation_file))
            )


if __name__ == "__main__":
    unittest.main()
