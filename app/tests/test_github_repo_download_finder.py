import unittest

from github_repo_download_finder import (
    DownloadOption,
    RepoRef,
    ScanResult,
    best_url_option,
    format_bytes,
    normalize_github_token,
    parse_repo_input,
    sanitize_filename,
    select_best_download_option,
)


class ParseRepoInputTests(unittest.TestCase):
    def test_owner_repo_shorthand(self):
        self.assertEqual(parse_repo_input("owner/repo"), RepoRef("owner", "repo"))

    def test_https_repo_url(self):
        self.assertEqual(
            parse_repo_input("https://github.com/owner/repo/releases"),
            RepoRef("owner", "repo"),
        )

    def test_clone_url(self):
        self.assertEqual(
            parse_repo_input("https://github.com/owner/repo.git"),
            RepoRef("owner", "repo"),
        )

    def test_ssh_url(self):
        self.assertEqual(
            parse_repo_input("git@github.com:owner/repo.git"),
            RepoRef("owner", "repo"),
        )

    def test_rejects_non_github_url(self):
        with self.assertRaises(ValueError):
            parse_repo_input("https://example.com/owner/repo")


class FormattingTests(unittest.TestCase):
    def test_format_bytes(self):
        self.assertEqual(format_bytes(1024), "1.0 KB")

    def test_sanitize_filename(self):
        self.assertEqual(sanitize_filename('bad:name?.zip'), "bad_name_.zip")

    def test_normalize_github_token_removes_hidden_whitespace(self):
        self.assertEqual(normalize_github_token(" ghp_abc\r\n123\t "), "ghp_abc123")


class BestUrlTests(unittest.TestCase):
    def test_prefers_windows_installer_asset_over_checksum_and_source(self):
        options = [
            DownloadOption("Asset tool-windows-x64.exe.sha256", "https://example.com/checksum", "tool-windows-x64.exe.sha256"),
            DownloadOption("Source ZIP", "https://example.com/source.zip", "tool-v1.zip"),
            DownloadOption("Asset tool-windows-x64.exe", "https://example.com/tool.exe", "tool-windows-x64.exe"),
        ]

        self.assertEqual(select_best_download_option(options).url, "https://example.com/tool.exe")

    def test_best_url_falls_back_to_default_branch_zip(self):
        scan = ScanResult(
            repo=RepoRef("owner", "repo"),
            info={"default_branch": "main"},
            latest_release=None,
            releases=[],
            tags=[],
        )

        self.assertEqual(best_url_option(scan).filename, "repo-main.zip")


if __name__ == "__main__":
    unittest.main()
