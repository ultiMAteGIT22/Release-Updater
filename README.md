# Release Updater

A small Windows GUI (PowerShell + WinForms) that keeps a list of **GitHub and GitLab** projects up to date. Paste a repo URL, click a button, and it downloads the latest Windows and/or Linux build into one folder per project. When a new release appears it downloads the new files and removes the old ones.

No installation, no dependencies: a single `.ps1` script.

## Features

- GitHub **and** GitLab (`gitlab.com`, including nested groups like `group/sub/project`)
- Picks the right files automatically: Windows and/or Linux, x64 preferred, ARM never chosen, checksums / signatures / source / debug files ignored
- Check everything, check only the selected repos, download everything, or download only the selected repos
- Shows downloaded vs. latest version, status, and download size before anything is downloaded
- Safe updates: new files are downloaded first, old files are removed only after success; a failed download rolls back
- Repos with **no releases at all** fall back to a zip of the default branch (pinned to the newest commit; a new commit counts as an update)
- Optional per-repo filters (see below)
- Dark mode (default) and light mode
- Clear message when GitHub's rate limit is hit, with the reset time

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (included with Windows)

## Quick start

1. Download `Update-Releases.ps1` (and optionally `Run-Updater.bat`) into a folder of your choice.
2. Double-click `Run-Updater.bat`, or run:
   ```powershell
   powershell -ExecutionPolicy Bypass -STA -File .\Update-Releases.ps1
   ```
3. Paste a repo URL into **Add repo**, press **Add**, then **Download / update all**.

The tool does not check for updates on start. Click **Check for updates** (all repos) or **Check selected**.

## Files the tool creates (next to the script)

| File | Purpose |
|---|---|
| `repos.txt` | Your repo list. Edit it with **Edit list** (opens Notepad++ if installed, otherwise Notepad) |
| `settings.json` | Download folder, platforms, tokens, dark mode |
| `Update-GitHubReleases.log` | Diagnostic log |
| `Downloads/<repo>/` | Downloaded files, plus a hidden `.release-info.json` that records what was downloaded |

> `settings.json` stores your access tokens **in plain text**. It is listed in `.gitignore`; keep it out of version control.

## repos.txt

```text
# GitHub: URL or owner/repo
https://github.com/PowerShell/PowerShell
7zip/7zip

# GitLab: full URL
https://gitlab.com/group/project
```

Optional overrides after a `|`:

```text
owner/repo | *x64*.zip                            # download every file matching (any platform)
owner/repo | win:*x64*.zip, linux:*linux*.tar.gz   # choose per platform (the other platform auto-picks)
```

## Tokens (optional)

| Site | Needed for | Where to create | Notes |
|---|---|---|---|
| GitHub | Avoiding the rate limit (60 requests/hour without a token, 5,000 with one) | <https://github.com/settings/tokens> | A classic token with **no scopes** is enough for public repos |
| GitLab | Private projects, rate limits | <https://gitlab.com/-/user_settings/personal_access_tokens> | Regular personal access token with the `read_api` scope |

Paste them into the token boxes in the app. They can also be provided through the `GITHUB_TOKEN` and `GITLAB_TOKEN` environment variables. Each token is only sent to its own site.

## How files are chosen

1. Published releases (including pre-releases) are checked; the newest stable release wins, otherwise the newest pre-release.
2. Every file is classified by filename tokens and platform-specific extensions (not by `.zip` alone): Windows (`win`, `windows`, `.exe`, `.msi` …), Linux (`linux`, `gnu`, `musl`, `.AppImage`, `.deb`, `.rpm` …). macOS and other platforms, checksums, signatures, source and debug files are ignored.
3. Per platform, the best file wins by architecture (x64 preferred, ARM never, 32-bit only if nothing else), then by format. On Windows you can choose portable/zip or installer with the **Prefer installers** checkbox.
4. If one platform is identified and exactly one other file is generic, it is assigned to the other platform. If every file is generic, the best single file is used once.

### GitLab specifics

- Files attached to the release as links are used. If a release has none, links to files (zip, 7z, tar.gz, AppImage, exe, msi …) inside the **release description** are used instead.
- GitLab does not report file sizes, so the tool asks the server. If the server does not say, the size column shows "unknown".
- The auto-generated "Source code" archives are not used, except by the no-releases fallback described above.

## Limitations

- Only `github.com` and `gitlab.com` (no self-hosted GitLab).
- The no-releases zip fallback on GitHub is fetched without a token, so private GitHub repos will not download that way.
- Each repo downloads into a folder named after the repo; two repos with the same name would share a folder.
- Pop-up message boxes and the folder picker stay light even in dark mode (a Windows limitation).

## License

MIT, see [LICENSE](LICENSE).
