import json
import tempfile
import unittest
from pathlib import Path

from verify_session_state import StateAuditError, verify_session_state


class VerifySessionStateTests(unittest.TestCase):
    def test_persistent_private_runner_resources_are_allowed_after_teardown(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            foundation = Path(directory) / "foundation.json"
            platform = Path(directory) / "platform.json"
            resources = [
                {"mode": "managed", "type": "aws_security_group", "name": "private_eks_runner"},
                {"mode": "managed", "type": "aws_iam_role", "name": "private_eks_runner"},
                {"mode": "managed", "type": "aws_iam_role_policy", "name": "private_eks_runner"},
                {"mode": "managed", "type": "aws_cloudwatch_log_group", "name": "private_eks_runner"},
                {"mode": "managed", "type": "aws_codebuild_source_credential", "name": "private_eks_runner"},
                {"mode": "managed", "type": "aws_codebuild_project", "name": "private_eks_runner"},
                {"mode": "managed", "type": "aws_codebuild_webhook", "name": "private_eks_runner"},
                {"mode": "managed", "type": "aws_vpc", "name": "this", "module": "module.network.module.vpc"},
                {"mode": "managed", "type": "aws_ssm_parameter", "name": "this", "module": "module.contract"},
            ]
            foundation.write_text(json.dumps({"version": 4, "resources": resources}), encoding="utf-8")
            platform.write_text(json.dumps({"version": 4, "resources": []}), encoding="utf-8")

            verify_session_state(foundation, platform)

    def test_unrelated_root_resources_and_nat_still_fail_the_audit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            foundation = Path(directory) / "foundation.json"
            platform = Path(directory) / "platform.json"
            foundation.write_text(
                json.dumps(
                    {
                        "version": 4,
                        "resources": [
                            {"mode": "managed", "type": "aws_instance", "name": "unexpected"},
                            {
                                "mode": "managed",
                                "type": "aws_nat_gateway",
                                "name": "this",
                                "module": "module.network.module.vpc",
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            platform.write_text(json.dumps({"version": 4, "resources": []}), encoding="utf-8")

            with self.assertRaisesRegex(StateAuditError, "unexpected addresses"):
                verify_session_state(foundation, platform)


if __name__ == "__main__":
    unittest.main()
