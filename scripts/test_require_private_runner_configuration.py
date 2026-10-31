import unittest

from require_private_runner_configuration import RunnerConfigurationError, validate_runner_configuration


class PrivateRunnerConfigurationTests(unittest.TestCase):
    def test_non_foundation_operations_do_not_require_runner_bootstrap_inputs(self) -> None:
        validate_runner_configuration(stack="hml", enabled="false", group_id="0", connection_arn="")

    def test_foundation_operations_require_runner_enabled(self) -> None:
        with self.assertRaisesRegex(RunnerConfigurationError, "ENABLE_PRIVATE_EKS_RUNNER=true"):
            validate_runner_configuration(stack="foundation", enabled="false", group_id="12", connection_arn="")

    def test_foundation_operations_require_custom_runner_group(self) -> None:
        with self.assertRaisesRegex(RunnerConfigurationError, "greater than the default group ID"):
            validate_runner_configuration(
                stack="foundation",
                enabled="true",
                group_id="1",
                connection_arn="arn:aws:codeconnections:us-east-1:035611741563:connection/abc123",
            )

    def test_foundation_operations_require_a_connection_arn(self) -> None:
        with self.assertRaisesRegex(RunnerConfigurationError, "AWS_CODECONNECTION_ARN"):
            validate_runner_configuration(stack="foundation", enabled="true", group_id="12", connection_arn="")

    def test_valid_foundation_runner_configuration_passes(self) -> None:
        validate_runner_configuration(
            stack="foundation",
            enabled="true",
            group_id="12",
            connection_arn="arn:aws:codeconnections:us-east-1:035611741563:connection/abc123",
        )

    def test_connection_must_belong_to_expected_account_and_region(self) -> None:
        with self.assertRaisesRegex(RunnerConfigurationError, "valid CodeConnections connection ARN"):
            validate_runner_configuration(
                stack="foundation",
                enabled="true",
                group_id="12",
                connection_arn="arn:aws:codeconnections:us-west-2:123456789012:connection/abc123",
            )


if __name__ == "__main__":
    unittest.main()
