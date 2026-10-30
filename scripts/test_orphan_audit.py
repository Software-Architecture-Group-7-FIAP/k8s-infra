import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class OrphanAuditTests(unittest.TestCase):
    def run_audit(self, aws_script: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            bin_directory = Path(temporary_directory) / "bin"
            bin_directory.mkdir()
            aws_executable = bin_directory / "aws"
            aws_executable.write_bytes(aws_script.replace("\r\n", "\n").encode("utf-8"))
            aws_executable.chmod(0o700)
            bash_bin_directory = str(bin_directory)
            if os.name == "nt":
                drive, tail = os.path.splitdrive(bash_bin_directory)
                bash_bin_directory = f"/mnt/{drive[0].lower()}/{tail.replace(chr(92), '/').lstrip('/')}"

            mock_aws_path = f"{bash_bin_directory}/aws"
            isolated_path = f"{bash_bin_directory}:/usr/bin:/bin"
            shell_setup = (
                f"chmod 700 {shlex.quote(mock_aws_path)} && "
                f"export PATH={shlex.quote(isolated_path)}"
            )
            chmod_result = subprocess.run(
                ["bash", "-c", f"chmod 700 {shlex.quote(mock_aws_path)}"],
                check=False,
                capture_output=True,
                text=True,
            )
            if chmod_result.returncode != 0:
                return chmod_result

            resolved_aws = subprocess.run(
                ["bash", "-c", f"{shell_setup} && type -P aws"],
                check=False,
                capture_output=True,
                text=True,
            )
            if resolved_aws.returncode != 0 or resolved_aws.stdout.strip() != f"{bash_bin_directory}/aws":
                return subprocess.CompletedProcess(
                    args=["bash", "scripts/orphans.sh"],
                    returncode=97,
                    stdout=resolved_aws.stdout,
                    stderr="The orphan audit test did not select its isolated AWS stub.\n",
                )

            return subprocess.run(
                ["bash", "-c", f"{shell_setup} && bash scripts/orphans.sh"],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

    def test_aws_inventory_errors_fail_without_claiming_a_clean_teardown(self) -> None:
        result = self.run_audit("#!/usr/bin/env bash\necho 'AccessDenied' >&2\nexit 254\n")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to report a clean teardown", result.stderr)
        self.assertNotIn("No dynamic billable resources left", result.stdout)

    def test_successful_empty_inventory_reports_clean_teardown(self) -> None:
        result = self.run_audit("#!/usr/bin/env bash\nprintf 'None\\n'\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No dynamic billable resources left", result.stdout)


if __name__ == "__main__":
    unittest.main()
