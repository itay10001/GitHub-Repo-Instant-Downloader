#!/usr/bin/env python3
"""Find GitHub release download links and latest release notes.

Run without arguments for an interactive prompt, or pass a GitHub URL / owner/repo:

    python github_repo_download_finder.py https://github.com/owner/repo
"""

from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import sys
import textwrap
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


API_ROOT = "https://api.github.com"
APP_USER_AGENT = "github-repo-download-finder/1.0"
CHANGELOG_CANDIDATES = (
    "CHANGELOG.md",
    "CHANGELOG",
    "CHANGES.md",
    "HISTORY.md",
    "RELEASES.md",
    "docs/CHANGELOG.md",
)


class GitHubError(Exception):
    """A clean, user-facing GitHub/API error."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class RepoRef:
    owner: str
    repo: str

    @property
    def full_name(self) -> str:
        return f"{self.owner}/{self.repo}"


@dataclass(frozen=True)
class DownloadOption:
    label: str
    url: str
    filename: str


@dataclass
class ScanResult:
    repo: RepoRef
    info: dict[str, Any]
    latest_release: dict[str, Any] | None
    releases: list[dict[str, Any]]
    tags: list[dict[str, Any]]


def parse_repo_input(value: str) -> RepoRef:
    """Accept GitHub web/SSH URLs or owner/repo shorthand."""

    raw = value.strip()
    if not raw:
        raise ValueError("Please enter a GitHub repository URL or owner/repo.")

    shorthand = re.fullmatch(r"([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:\.git)?", raw)
    if shorthand:
        return RepoRef(shorthand.group(1), _clean_repo_name(shorthand.group(2)))

    ssh = re.fullmatch(r"(?:git@|ssh://git@)github\.com[:/]([^/]+)/(.+?)(?:\.git)?/?", raw)
    if ssh:
        return RepoRef(ssh.group(1), _clean_repo_name(ssh.group(2).split("/")[0]))

    parsed = urlparse(raw)
    if parsed.netloc.lower() not in {"github.com", "www.github.com"}:
        raise ValueError("That does not look like a github.com repository URL.")

    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 2:
        raise ValueError("That GitHub URL does not include both an owner and repo name.")

    return RepoRef(parts[0], _clean_repo_name(parts[1]))


def _clean_repo_name(repo: str) -> str:
    repo = repo.strip()
    if repo.endswith(".git"):
        repo = repo[:-4]
    return repo


class GitHubClient:
    def __init__(self, token: str | None = None, timeout: int = 25) -> None:
        self.token = token or os.environ.get("GITHUB_TOKEN")
        self.timeout = timeout

    def get_json(self, path_or_url: str, *, allow_404: bool = False) -> Any:
        url = path_or_url if path_or_url.startswith("http") else f"{API_ROOT}{path_or_url}"
        try:
            body, _headers = self._request(url, accept="application/vnd.github+json")
        except GitHubError as exc:
            if allow_404 and exc.status == 404:
                return None
            raise
        try:
            return json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise GitHubError(f"GitHub returned invalid JSON for {url}: {exc}") from exc

    def get_repo(self, repo: RepoRef) -> dict[str, Any]:
        return self.get_json(f"/repos/{repo.owner}/{repo.repo}")

    def get_latest_release(self, repo: RepoRef) -> dict[str, Any] | None:
        return self.get_json(f"/repos/{repo.owner}/{repo.repo}/releases/latest", allow_404=True)

    def get_releases(self, repo: RepoRef, limit: int) -> list[dict[str, Any]]:
        data = self.get_json(f"/repos/{repo.owner}/{repo.repo}/releases?per_page={min(limit, 100)}")
        return data if isinstance(data, list) else []

    def get_tags(self, repo: RepoRef, limit: int) -> list[dict[str, Any]]:
        data = self.get_json(f"/repos/{repo.owner}/{repo.repo}/tags?per_page={min(limit, 100)}")
        return data if isinstance(data, list) else []

    def get_file_text(self, repo: RepoRef, path: str, ref: str) -> str | None:
        encoded_path = quote(path, safe="/")
        encoded_ref = quote(ref, safe="")
        item = self.get_json(
            f"/repos/{repo.owner}/{repo.repo}/contents/{encoded_path}?ref={encoded_ref}",
            allow_404=True,
        )
        if not item or item.get("type") != "file":
            return None

        if item.get("encoding") == "base64" and item.get("content"):
            raw = base64.b64decode(item["content"])
            return raw.decode("utf-8", errors="replace")

        download_url = item.get("download_url")
        if download_url:
            body, _headers = self._request(download_url, accept="text/plain")
            return body.decode("utf-8", errors="replace")
        return None

    def download(self, option: DownloadOption, output_dir: Path) -> Path:
        output_dir.mkdir(parents=True, exist_ok=True)
        target = unique_path(output_dir / sanitize_filename(option.filename))
        request = self._make_request(option.url, accept="application/octet-stream")

        try:
            with urlopen(request, timeout=self.timeout) as response, target.open("wb") as file:
                while True:
                    chunk = response.read(1024 * 256)
                    if not chunk:
                        break
                    file.write(chunk)
        except HTTPError as exc:
            message = self._read_error_message(exc)
            raise GitHubError(f"Download failed ({exc.code}): {message}", exc.code) from exc
        except URLError as exc:
            raise GitHubError(f"Could not download from GitHub: {exc.reason}") from exc

        return target

    def _request(self, url: str, *, accept: str) -> tuple[bytes, Any]:
        request = self._make_request(url, accept=accept)
        try:
            with urlopen(request, timeout=self.timeout) as response:
                return response.read(), response.headers
        except HTTPError as exc:
            message = self._read_error_message(exc)
            if exc.code == 403 and "rate limit" in message.lower() and not self.token:
                message += " Set a GITHUB_TOKEN environment variable to raise the limit."
            raise GitHubError(f"GitHub request failed ({exc.code}): {message}", exc.code) from exc
        except URLError as exc:
            raise GitHubError(f"Could not reach GitHub: {exc.reason}") from exc

    def _make_request(self, url: str, *, accept: str) -> Request:
        headers = {
            "Accept": accept,
            "User-Agent": APP_USER_AGENT,
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return Request(url, headers=headers)

    @staticmethod
    def _read_error_message(exc: HTTPError) -> str:
        body = exc.read().decode("utf-8", errors="replace")
        if not body:
            return exc.reason
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            return body[:500]
        return parsed.get("message") or body[:500]


def scan_repo(client: GitHubClient, repo: RepoRef, limit: int) -> ScanResult:
    info = client.get_repo(repo)
    latest_release = client.get_latest_release(repo)
    releases = client.get_releases(repo, limit=limit)

    if latest_release is None and releases:
        latest_release = releases[0]

    tags = client.get_tags(repo, limit=limit)
    return ScanResult(repo=repo, info=info, latest_release=latest_release, releases=releases, tags=tags)


def print_summary(scan: ScanResult) -> None:
    info = scan.info
    print()
    print(f"Repository: {info.get('full_name', scan.repo.full_name)}")
    if info.get("description"):
        print(f"About:      {info['description']}")
    print(f"URL:        {info.get('html_url', f'https://github.com/{scan.repo.full_name}')}")
    print(f"Default:    {info.get('default_branch', 'unknown')}")
    print(f"Releases:   {len(scan.releases)} found in this scan")
    print(f"Tags:       {len(scan.tags)} found in this scan")

    default_branch = info.get("default_branch")
    if default_branch:
        print(f"Branch ZIP: {branch_archive_url(scan.repo, default_branch, 'zip')}")

    if scan.latest_release:
        latest = scan.latest_release
        print()
        print(f"Latest release: {release_label(latest)}")
        print(f"Release page:   {latest.get('html_url', 'not available')}")
    elif scan.tags:
        print()
        print(f"No GitHub releases found. Newest tag: {scan.tags[0].get('name', 'unknown')}")
    else:
        print()
        print("No GitHub releases or tags found. Use the default branch ZIP link above.")


def print_latest_download_links(scan: ScanResult) -> None:
    print()
    if scan.latest_release:
        print(f"Download links for {release_label(scan.latest_release)}")
        print_download_options(release_download_options(scan.repo, scan.latest_release))
        return

    if scan.tags:
        tag = scan.tags[0]
        print(f"Download links for newest tag: {tag.get('name', 'unknown')}")
        print_download_options(tag_download_options(scan.repo, tag))
        return

    default_branch = scan.info.get("default_branch")
    if default_branch:
        print("Download link for the default branch")
        print(f"  Source ZIP: {branch_archive_url(scan.repo, default_branch, 'zip')}")
        print(f"  Source TAR: {branch_archive_url(scan.repo, default_branch, 'tar.gz')}")


def print_download_options(options: list[DownloadOption]) -> None:
    for option in options:
        print(f"  {option.label}: {option.url}")


def print_versions(scan: ScanResult, limit: int) -> None:
    print()
    if scan.releases:
        print(f"Releases / versions (showing up to {min(limit, len(scan.releases))})")
        for index, release in enumerate(scan.releases[:limit], start=1):
            print(f"  {index:>2}. {release_label(release)}")
    else:
        print("No GitHub releases found.")

    if scan.tags:
        print()
        print(f"Tags (showing up to {min(limit, len(scan.tags))})")
        for index, tag in enumerate(scan.tags[:limit], start=1):
            print(f"  {index:>2}. {tag.get('name', 'unknown')}")
    else:
        print()
        print("No tags found.")


def print_latest_notes(client: GitHubClient, scan: ScanResult) -> None:
    print()
    if scan.latest_release and clean_notes(scan.latest_release.get("body")):
        tag = scan.latest_release.get("tag_name", "latest")
        print(f"What's new in {tag} (from GitHub release notes)")
        print_note_block(clean_notes(scan.latest_release.get("body")) or "")
        return

    default_branch = scan.info.get("default_branch")
    if not default_branch:
        print("No release notes found, and the repo default branch is unknown.")
        return

    changelog = find_changelog(client, scan.repo, default_branch)
    if changelog is None:
        print("No release notes or common changelog/update-log file found.")
        return

    name, text = changelog
    tag_name = scan.latest_release.get("tag_name") if scan.latest_release else None
    section = extract_changelog_section(text, tag_name) if tag_name else None
    print(f"What's new (from {name})")
    print_note_block(section or text)


def find_changelog(client: GitHubClient, repo: RepoRef, default_branch: str) -> tuple[str, str] | None:
    for path in CHANGELOG_CANDIDATES:
        try:
            text = client.get_file_text(repo, path, default_branch)
        except GitHubError as exc:
            if exc.status == 404:
                continue
            raise
        if text:
            return path, text
    return None


def extract_changelog_section(changelog: str, tag_name: str | None) -> str | None:
    if not tag_name:
        return None

    normalized_tag = normalize_version(tag_name)
    lines = changelog.splitlines()
    start_index: int | None = None
    start_level: int | None = None

    for index, line in enumerate(lines):
        match = re.match(r"^(#{1,6})\s+(.+?)\s*$", line)
        if not match:
            continue
        heading_text = strip_markdown(match.group(2))
        if normalized_tag in {normalize_version(token) for token in version_tokens(heading_text)}:
            start_index = index
            start_level = len(match.group(1))
            break

    if start_index is None or start_level is None:
        return None

    end_index = len(lines)
    for index in range(start_index + 1, len(lines)):
        match = re.match(r"^(#{1,6})\s+", lines[index])
        if match and len(match.group(1)) <= start_level:
            end_index = index
            break

    return "\n".join(lines[start_index:end_index]).strip()


def version_tokens(text: str) -> list[str]:
    return re.findall(r"v?\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?|v\d+(?:[-+][0-9A-Za-z.-]+)?", text)


def normalize_version(value: str) -> str:
    return value.strip().lower().lstrip("v")


def strip_markdown(value: str) -> str:
    return re.sub(r"[*_`[\]()]|#+", "", value)


def print_note_block(notes: str, *, max_lines: int = 90, max_chars: int = 8000) -> None:
    notes = notes.strip()
    if not notes:
        print("No notes were published for the latest release.")
        return

    lines = notes.splitlines()
    truncated = False
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        truncated = True
    block = "\n".join(lines)
    if len(block) > max_chars:
        block = block[:max_chars].rstrip()
        truncated = True

    print()
    print(textwrap.indent(block, "  "))
    if truncated:
        print()
        print("  ...truncated. Open the release page for the full notes.")


def clean_notes(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def release_label(release: dict[str, Any]) -> str:
    tag = release.get("tag_name") or "unknown tag"
    name = release.get("name") or ""
    date = release.get("published_at") or release.get("created_at") or ""
    date = date[:10] if date else "unknown date"
    markers = []
    if release.get("prerelease"):
        markers.append("pre-release")
    if release.get("draft"):
        markers.append("draft")

    title = f"{tag} - {name}" if name and name != tag else tag
    suffix = f" ({', '.join(markers)})" if markers else ""
    return f"{title} [{date}]{suffix}"


def release_download_options(repo: RepoRef, release: dict[str, Any]) -> list[DownloadOption]:
    options: list[DownloadOption] = []
    for asset in release.get("assets") or []:
        name = asset.get("name") or "release-asset"
        size = format_bytes(asset.get("size"))
        label = f"Asset {name}"
        if size:
            label += f" ({size})"
        if asset.get("browser_download_url"):
            options.append(DownloadOption(label=label, url=asset["browser_download_url"], filename=name))

    tag = release.get("tag_name") or "source"
    if release.get("zipball_url"):
        options.append(
            DownloadOption(
                label="Source ZIP",
                url=release["zipball_url"],
                filename=f"{repo.repo}-{tag}.zip",
            )
        )
    if release.get("tarball_url"):
        options.append(
            DownloadOption(
                label="Source TAR.GZ",
                url=release["tarball_url"],
                filename=f"{repo.repo}-{tag}.tar.gz",
            )
        )
    return options


def tag_download_options(repo: RepoRef, tag: dict[str, Any]) -> list[DownloadOption]:
    name = tag.get("name") or "tag"
    options: list[DownloadOption] = []
    if tag.get("zipball_url"):
        options.append(DownloadOption("Source ZIP", tag["zipball_url"], f"{repo.repo}-{name}.zip"))
    if tag.get("tarball_url"):
        options.append(DownloadOption("Source TAR.GZ", tag["tarball_url"], f"{repo.repo}-{name}.tar.gz"))
    return options


def branch_download_options(repo: RepoRef, branch: str) -> list[DownloadOption]:
    return [
        DownloadOption("Source ZIP", branch_api_archive_url(repo, branch, "zipball"), f"{repo.repo}-{branch}.zip"),
        DownloadOption("Source TAR.GZ", branch_api_archive_url(repo, branch, "tarball"), f"{repo.repo}-{branch}.tar.gz"),
    ]


def branch_archive_url(repo: RepoRef, branch: str, extension: str) -> str:
    return f"https://github.com/{repo.owner}/{repo.repo}/archive/refs/heads/{quote(branch, safe='/')}.{extension}"


def branch_api_archive_url(repo: RepoRef, branch: str, kind: str) -> str:
    return f"{API_ROOT}/repos/{repo.owner}/{repo.repo}/{kind}/{quote(branch, safe='')}"


def format_bytes(value: Any) -> str:
    if not isinstance(value, int):
        return ""
    amount = float(value)
    for unit in ("B", "KB", "MB", "GB"):
        if amount < 1024 or unit == "GB":
            return f"{amount:.1f} {unit}" if unit != "B" else f"{int(amount)} B"
        amount /= 1024
    return ""


def sanitize_filename(filename: str) -> str:
    filename = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", filename)
    filename = filename.strip().strip(".")
    return filename or "download"


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path

    stem = path.stem
    suffix = path.suffix
    if path.name.endswith(".tar.gz"):
        stem = path.name[:-7]
        suffix = ".tar.gz"

    for index in range(2, 1000):
        candidate = path.with_name(f"{stem}-{index}{suffix}")
        if not candidate.exists():
            return candidate
    raise GitHubError(f"Could not choose a unique filename for {path}")


def choose_release_or_tag(scan: ScanResult, limit: int) -> tuple[str, dict[str, Any]] | None:
    choices: list[tuple[str, dict[str, Any], str]] = []
    for release in scan.releases[:limit]:
        choices.append(("release", release, release_label(release)))
    if not choices:
        for tag in scan.tags[:limit]:
            choices.append(("tag", tag, tag.get("name", "unknown")))

    if not choices:
        print("No releases or tags are available to choose from.")
        return None

    print()
    for index, (_kind, _item, label) in enumerate(choices, start=1):
        print(f"  {index:>2}. {label}")
    answer = input("Pick a version number for links, or press Enter to go back: ").strip()
    if not answer:
        return None
    if not answer.isdigit() or not (1 <= int(answer) <= len(choices)):
        print("That selection is not in the list.")
        return None
    kind, item, _label = choices[int(answer) - 1]
    return kind, item


def choose_download_option(options: list[DownloadOption]) -> DownloadOption | None:
    if not options:
        print("No downloadable options found.")
        return None

    print()
    for index, option in enumerate(options, start=1):
        print(f"  {index:>2}. {option.label}")
        print(f"      {option.url}")

    answer = input("Pick a download number, or press Enter to go back: ").strip()
    if not answer:
        return None
    if not answer.isdigit() or not (1 <= int(answer) <= len(options)):
        print("That selection is not in the list.")
        return None
    return options[int(answer) - 1]


def options_for_choice(scan: ScanResult, kind: str, item: dict[str, Any]) -> list[DownloadOption]:
    if kind == "release":
        return release_download_options(scan.repo, item)
    return tag_download_options(scan.repo, item)


def interactive_menu(client: GitHubClient, scan: ScanResult, output_dir: Path, limit: int) -> str:
    while True:
        print()
        print("Choose an action")
        print("  1. Show latest release notes / changelog")
        print("  2. Show versions you can download")
        print("  3. Show latest download links")
        print("  4. Download a release/tag now")
        print("  5. Enter another repo")
        print("  q. Quit")
        choice = input("> ").strip().lower()

        if choice == "1":
            print_latest_notes(client, scan)
        elif choice == "2":
            print_versions(scan, limit)
            selected = choose_release_or_tag(scan, limit)
            if selected:
                kind, item = selected
                print_download_options(options_for_choice(scan, kind, item))
        elif choice == "3":
            print_latest_download_links(scan)
        elif choice == "4":
            selected = choose_release_or_tag(scan, limit)
            if selected is None:
                branch = scan.info.get("default_branch")
                if branch and not scan.releases and not scan.tags:
                    option = choose_download_option(branch_download_options(scan.repo, branch))
                else:
                    option = None
            else:
                kind, item = selected
                option = choose_download_option(options_for_choice(scan, kind, item))
            if option:
                saved = client.download(option, output_dir)
                print(f"Downloaded to: {saved}")
        elif choice == "5":
            return "again"
        elif choice in {"q", "quit", "exit"}:
            return "quit"
        else:
            print("Choose 1, 2, 3, 4, 5, or q.")


def run_once(args: argparse.Namespace, client: GitHubClient, repo_text: str) -> str:
    repo = parse_repo_input(repo_text)
    if args.best_url:
        scan = scan_repo(client, repo, limit=args.limit)
        option = best_url_option(scan)
        if option is None:
            raise ValueError("No latest release/tag/default-branch download option found.")
        print(option.url)
        return "done"

    print(f"Scanning {repo.full_name}...")
    scan = scan_repo(client, repo, limit=args.limit)
    output_dir = Path(args.output_dir).expanduser().resolve()

    print_summary(scan)

    action_mode = args.no_menu or args.versions or args.notes or args.download_latest or args.best_url
    if args.versions:
        print_versions(scan, args.limit)
    if args.notes:
        print_latest_notes(client, scan)
    if args.no_menu:
        print_latest_download_links(scan)
    if args.download_latest:
        option = latest_download_option(scan)
        if option is None:
            print("No latest release/tag/default-branch download option found.")
        else:
            saved = client.download(option, output_dir)
            print(f"Downloaded to: {saved}")

    if action_mode:
        return "done"
    return interactive_menu(client, scan, output_dir, args.limit)


def latest_download_option(scan: ScanResult) -> DownloadOption | None:
    if scan.latest_release:
        options = release_download_options(scan.repo, scan.latest_release)
        source_zip = next((option for option in options if option.label == "Source ZIP"), None)
        return source_zip or (options[0] if options else None)

    if scan.tags:
        options = tag_download_options(scan.repo, scan.tags[0])
        return options[0] if options else None

    branch = scan.info.get("default_branch")
    if branch:
        return branch_download_options(scan.repo, branch)[0]
    return None


def option_score(option: DownloadOption) -> int:
    name = option.filename.lower()
    label = option.label.lower()
    score = 0

    if label.startswith("asset "):
        score += 100
    if re.search(r"\.(exe|msi|msix|appinstaller)$", name):
        score += 80
    elif re.search(r"\.(zip|7z)$", name):
        score += 45
    if re.search(r"(windows|win32|win64|win-|_win|\.win)", name):
        score += 40
    if re.search(r"(x64|x86_64|amd64)", name):
        score += 25
    if re.search(r"(arm64|aarch64|armv7)", name):
        score -= 25
    if re.search(r"(sha256|sha512|checksum|checksums|\.sig|\.asc|sbom|symbols|debug)", name):
        score -= 120
    if label == "source zip":
        score += 20
    if label == "source tar.gz":
        score += 5
    return score


def select_best_download_option(options: list[DownloadOption]) -> DownloadOption | None:
    return max(options, key=option_score, default=None)


def best_url_option(scan: ScanResult) -> DownloadOption | None:
    if scan.latest_release:
        option = select_best_download_option(release_download_options(scan.repo, scan.latest_release))
        if option:
            return option

    if scan.tags:
        option = select_best_download_option(tag_download_options(scan.repo, scan.tags[0]))
        if option:
            return option

    branch = scan.info.get("default_branch")
    if branch:
        return branch_download_options(scan.repo, branch)[0]
    return None


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scan a GitHub repo for release downloads, versions, and latest release notes."
    )
    parser.add_argument("repo", nargs="?", help="GitHub repository URL, SSH URL, or owner/repo")
    parser.add_argument("--versions", action="store_true", help="Print available releases/tags and exit")
    parser.add_argument("--notes", action="store_true", help="Print latest release notes/changelog and exit")
    parser.add_argument("--download-latest", action="store_true", help="Download the latest source ZIP and exit")
    parser.add_argument("--best-url", action="store_true", help="Print only the best latest download URL and exit")
    parser.add_argument("--no-menu", action="store_true", help="Print summary/latest links without the interactive menu")
    parser.add_argument("--limit", type=int, default=30, help="Maximum releases/tags to scan, up to 100")
    parser.add_argument(
        "--output-dir",
        default="downloads",
        help="Folder for downloaded files when using the download action",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.limit < 1:
        print("--limit must be at least 1", file=sys.stderr)
        return 2
    args.limit = min(args.limit, 100)

    client = GitHubClient()

    try:
        if args.repo:
            result = run_once(args, client, args.repo)
            if result != "again":
                return 0

        print("GitHub Repo Download Finder")
        print("Paste a GitHub repo URL, SSH URL, or owner/repo. Press Enter on an empty line to quit.")
        while True:
            repo_text = input("\nRepo URL> ").strip()
            if not repo_text:
                return 0
            result = run_once(args, client, repo_text)
            if result == "quit":
                return 0
    except (GitHubError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nCancelled.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
