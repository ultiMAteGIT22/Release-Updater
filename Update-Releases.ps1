#Requires -Version 5.1
<#
  Release Updater (GUI) - GitHub + GitLab - Windows + Linux builds
  ----------------------------------------------------------------
  - Repo list lives in repos.txt (next to this script) - edit it in Notepad++ (or Notepad) any time.
  - Settings (download folder, platforms, GitHub/GitLab tokens, dark mode) live in settings.json.
  - Each repo gets its own sub-folder under the download folder, named after the repo.
  - A hidden file ".release-info.json" in each repo folder records which release/files
    were downloaded, so the script knows what to compare and what to delete on update.

  Run:  powershell -ExecutionPolicy Bypass -STA -File .\Update-Releases.ps1

  How the right files are chosen (when repos.txt has no filter for a repo):
    1. Published releases, including pre-releases, are checked. Every asset is classified
       by filename tokens and platform-specific extensions, not archive extension alone:
       windows (win, windows, win64, msvc, mingw, .exe/.msi), linux (linux, gnu, musl, ubuntu,
       .AppImage/.deb/.rpm), macOS/other (ignored), checksums/signatures/source/debug (ignored).
    2. Within each wanted platform the best file wins by architecture
       (x64/amd64/x86_64 preferred; ARM never chosen; 32-bit only if nothing else) and then
       by format (Windows: portable/zip or installer - your choice; Linux: tar.gz/zip/AppImage first).
    3. If one platform is explicit and exactly one other asset is generic (e.g. App.AppImage
       plus App.zip), the generic asset is assigned to the other platform. If all assets are
       generic, the best single file is used once.

  Sources (repos.txt / Add box):
      https://github.com/owner/repo      or just   owner/repo   (GitHub)
      https://gitlab.com/group/project   (GitLab - nested groups such as group/sub/project work too)

  Repos with NO releases at all: a zip of the default branch (pinned to its newest commit) is
  downloaded instead; a new commit counts as an update. Repos that have releases never use this.

  Per-repo overrides in repos.txt after a "|":
      owner/repo | *win-x64*.zip                       -> download every file matching (any platform)
      owner/repo | win:*x64*.zip, linux:*linux*.tar.gz -> choose per platform (the other platform auto-picks)
#>

param([string]$DownloadRoot)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -AssemblyName System.Net.Http
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ('NativeTheme' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -Language CSharp -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class NativeTheme {
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hwnd, string subApp, string subIdList);

    public static void TitleBar(IntPtr h, bool dark) {
        int v = dark ? 1 : 0;
        if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) DwmSetWindowAttribute(h, 19, ref v, 4);
    }
    public static void Scroll(IntPtr h, bool dark) {
        SetWindowTheme(h, dark ? "DarkMode_Explorer" : "Explorer", null);
    }
}

public class SlimProgressBar : Control {
    int _value;
    public int Minimum { get; set; }
    int _max = 100;
    public int Maximum { get { return _max; } set { _max = Math.Max(1, value); Invalidate(); } }
    public Color TrackColor = Color.FromArgb(36, 40, 49);
    public Color BarColor = Color.FromArgb(99, 132, 240);
    public int Value {
        get { return _value; }
        set { int v = Math.Max(Minimum, Math.Min(_max, value)); if (v != _value) { _value = v; Invalidate(); } }
    }
    public SlimProgressBar() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    static GraphicsPath Pill(Rectangle r) {
        int d = Math.Max(1, r.Height);
        var p = new GraphicsPath();
        if (r.Width < d) { p.AddEllipse(r.X, r.Y, Math.Max(1, r.Width), d); return p; }
        p.AddArc(r.X, r.Y, d, d, 90, 180);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 180);
        p.CloseFigure();
        return p;
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var track = new Rectangle(0, 0, Width - 1, Height - 1);
        using (var p = Pill(track)) using (var b = new SolidBrush(TrackColor)) g.FillPath(b, p);
        int w = (int)((long)track.Width * (_value - Minimum) / Math.Max(1, _max - Minimum));
        if (w > 0) {
            var bar = new Rectangle(0, 0, Math.Max(track.Height, w), track.Height);
            using (var p = Pill(bar)) using (var b = new SolidBrush(BarColor)) g.FillPath(b, p);
        }
    }
}

public class ModernCheck : CheckBox {
    public Color BoxFill = Color.FromArgb(28, 31, 38);
    public Color BoxBorder = Color.FromArgb(70, 77, 92);
    public Color AccentColor = Color.FromArgb(99, 132, 240);
    public Color DisabledColor = Color.FromArgb(84, 90, 102);
    public ModernCheck() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int sz = 16, y = (Height - sz) / 2;
        var r = new Rectangle(1, y, sz, sz);
        using (var path = new GraphicsPath()) {
            int d = 6;
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            using (var b = new SolidBrush(Checked ? AccentColor : BoxFill)) g.FillPath(b, path);
            using (var p = new Pen(Checked ? AccentColor : BoxBorder, 1f)) g.DrawPath(p, path);
        }
        if (Checked) {
            using (var p = new Pen(Color.White, 2f)) {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                g.DrawLines(p, new PointF[] { new PointF(r.X + 4f, r.Y + 8.5f), new PointF(r.X + 7f, r.Y + 11.5f), new PointF(r.X + 12.5f, r.Y + 5f) });
            }
        }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(sz + 8, 0, Math.Max(1, Width - sz - 8), Height),
            Enabled ? ForeColor : DisabledColor,
            TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }
}
"@
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ReposFile    = Join-Path $ScriptDir 'repos.txt'
$SettingsFile = Join-Path $ScriptDir 'settings.json'
$MarkerName   = '.release-info.json'
$LogFile      = Join-Path $ScriptDir 'Update-GitHubReleases.log'

$script:Busy   = $false
$script:Cancel = $false

# ----------------------------------------------------------------------------
# Settings + repo list files
# ----------------------------------------------------------------------------
$script:Settings = @{
    DownloadRoot    = (Join-Path $ScriptDir 'Downloads')
    Token           = ''
    GitLabToken     = ''
    Windows         = $true
    Linux           = $true
    PreferInstaller = $false
    Dark            = $true
}
if (Test-Path -LiteralPath $SettingsFile) {
    try {
        $s = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
        if ($s.DownloadRoot)         { $script:Settings.DownloadRoot = [string]$s.DownloadRoot }
        if ($s.Token)                { $script:Settings.Token = [string]$s.Token }
        if ($s.GitLabToken)          { $script:Settings.GitLabToken = [string]$s.GitLabToken }
        if ($null -ne $s.Windows)         { $script:Settings.Windows = [bool]$s.Windows }
        if ($null -ne $s.Linux)           { $script:Settings.Linux = [bool]$s.Linux }
        if ($null -ne $s.PreferInstaller) { $script:Settings.PreferInstaller = [bool]$s.PreferInstaller }
        if ($null -ne $s.Dark)            { $script:Settings.Dark = [bool]$s.Dark }
    } catch {}
}
if ($DownloadRoot) { $script:Settings.DownloadRoot = $DownloadRoot }
if (-not $script:Settings.Token -and $env:GITHUB_TOKEN) { $script:Settings.Token = $env:GITHUB_TOKEN }
if (-not $script:Settings.GitLabToken -and $env:GITLAB_TOKEN) { $script:Settings.GitLabToken = $env:GITLAB_TOKEN }

if (-not (Test-Path -LiteralPath $ReposFile)) {
    @(
        '# One repo per line: a GitHub or GitLab URL (or GitHub owner/repo). Lines starting with # are ignored.',
        '# Normally nothing else is needed - Windows and Linux files are detected automatically.',
        '#',
        '# Optional overrides after a | :',
        '#   owner/repo | *x64*.zip                          (download every file matching, any platform)',
        '#   owner/repo | win:*x64*.zip, linux:*linux*.tar.gz (choose per platform)',
        '#',
        '# https://github.com/PowerShell/PowerShell',
        '# 7zip/7zip',
        '# https://gitlab.com/zzzarathustra-dev/power-moon-recomp'
    ) | Set-Content -LiteralPath $ReposFile -Encoding UTF8
}

function Save-Settings {
    $script:Settings.DownloadRoot    = $txtFolder.Text.Trim()
    $script:Settings.Token           = $txtToken.Text.Trim()
    $script:Settings.GitLabToken     = $txtGitLabToken.Text.Trim()
    $script:Settings.Windows         = [bool]$chkWin.Checked
    $script:Settings.Linux           = [bool]$chkLinux.Checked
    $script:Settings.PreferInstaller = [bool]$chkInstaller.Checked
    $script:Settings.Dark            = [bool]$chkDark.Checked
    try { $script:Settings | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 } catch {}
}

function Test-Platforms {
    if (-not $chkWin.Checked -and -not $chkLinux.Checked) {
        [void][System.Windows.Forms.MessageBox]::Show('Tick at least one platform (Windows and/or Linux).', 'No platform selected')
        return $false
    }
    $true
}

function Get-EnabledPlatforms {
    $p = @()
    if ($script:Settings.Windows) { $p += 'windows' }
    if ($script:Settings.Linux)   { $p += 'linux' }
    $p
}

function ConvertTo-RepoEntry([string]$line) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { return $null }
    $parts   = $t -split '\|', 2
    $spec    = $parts[0].Trim()
    $pattern = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
    $src = 'github'
    if ($spec -match 'gitlab\.com[/:](\S+)') {
        # GitLab projects may live in nested groups: group/sub/project
        $path = ($matches[1] -split '[?#]')[0]
        $path = ($path -split '/-/')[0]
        $path = $path.Trim('/') -replace '\.git$', ''
        $segs = @($path -split '/' | Where-Object { $_ })
        if ($segs.Count -lt 2) { return $null }
        $n = $segs[$segs.Count - 1]
        $o = ($segs[0..($segs.Count - 2)] -join '/')
        $src = 'gitlab'
    }
    elseif ($spec -match 'github\.com[/:]([^/\s]+)/([^/\s#?]+)') { $o = $matches[1]; $n = $matches[2] }
    elseif ($spec -match '^([\w.-]+)/([\w.-]+)$')                { $o = $matches[1]; $n = $matches[2] }
    else { return $null }
    $n = $n -replace '\.git$', ''
    $key = if ($src -eq 'gitlab') { "gitlab:$o/$n" } else { "$o/$n" }
    [pscustomobject]@{ Owner = $o; Name = $n; Pattern = $pattern; Source = $src; Key = $key.ToLower() }
}

function Get-Repos {
    $out = @()
    foreach ($l in @(Get-Content -LiteralPath $ReposFile)) {
        $e = ConvertTo-RepoEntry $l
        if ($e) { $out += $e }
    }
    $out
}

function Add-RepoLine($entry) {
    $text = if ($entry.Source -eq 'gitlab') { "https://gitlab.com/$($entry.Owner)/$($entry.Name)" } else { "$($entry.Owner)/$($entry.Name)" }
    if ($entry.Pattern) { $text += " | $($entry.Pattern)" }
    $raw = [IO.File]::ReadAllText($ReposFile)
    $prefix = if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) { "`r`n" } else { '' }
    [IO.File]::AppendAllText($ReposFile, "$prefix$text`r`n")
}

function Remove-RepoLine([string]$key) {
    $keep = @()
    foreach ($l in @(Get-Content -LiteralPath $ReposFile)) {
        $e = ConvertTo-RepoEntry $l
        if ($e -and $e.Key -eq $key) { continue }
        $keep += $l
    }
    Set-Content -LiteralPath $ReposFile -Value $keep -Encoding UTF8
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Format-Size([double]$b) {
    if     ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) }
    else                { "$([int]$b) B" }
}

function Write-Log([string]$msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    if ($txtLog -and -not $txtLog.IsDisposed) { $txtLog.AppendText($line + "`r`n") }
    # Keep a persistent diagnostic log beside the script as well as in the GUI.
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
}

function Get-RepoFolder($entry) { Join-Path $script:Settings.DownloadRoot $entry.Name }

function Get-RepoUrl($entry) {
    if ($entry.Source -eq 'gitlab') { "https://gitlab.com/$($entry.Owner)/$($entry.Name)/-/releases" }
    else                            { "https://github.com/$($entry.Owner)/$($entry.Name)/releases" }
}

function Read-Marker($entry) {
    $p = Join-Path (Get-RepoFolder $entry) $MarkerName
    if (Test-Path -LiteralPath $p) {
        try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch {}
    }
    $null
}

function Write-Marker($entry, [string]$tag, $files) {
    $p = Join-Path (Get-RepoFolder $entry) $MarkerName
    if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p -Force).Attributes = 'Normal' }
    $obj = @{ tag = $tag; files = @($files); updated = (Get-Date).ToString('s') }
    $obj | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding UTF8
    try { (Get-Item -LiteralPath $p -Force).Attributes = 'Hidden' } catch {}
}

# ----------------------------------------------------------------------------
# GitHub API
# ----------------------------------------------------------------------------
# Turn a 401/403/429 from GitHub into a clear message (and flag real rate-limit hits so checking can stop early)
function Get-GitHubRefusal($err, [int]$code) {
    $remaining = $null; $reset = $null
    try {
        $hd = $err.Exception.Response.Headers
        $remaining = [string]$hd['X-RateLimit-Remaining']; $reset = [string]$hd['X-RateLimit-Reset']
    } catch {}
    if ($remaining -eq '0' -or $code -eq 429 -or ([string]::IsNullOrEmpty($remaining) -and $code -eq 403)) {
        $when = ''
        try { $when = ' Resets around ' + [DateTimeOffset]::FromUnixTimeSeconds([long]$reset).LocalDateTime.ToString('HH:mm') + '.' } catch {}
        $tip = if ($script:Settings.Token) { '' } else { ' Without a token GitHub allows only 60 requests per hour - paste a GitHub token (no scopes needed) into the token box for 5,000 per hour.' }
        return @{ Release = $null; RateLimited = $true; Error = "GitHub rate limit reached.$when$tip" }
    }
    return @{ Release = $null; Error = "GitHub refused the request ($code) - the token is invalid or access is denied" }
}

function Get-LatestGitHubRelease([string]$owner, [string]$name) {
    $h = @{ 'User-Agent' = 'ReleaseUpdater'; 'Accept' = 'application/vnd.github+json' }
    if ($script:Settings.Token) { $h['Authorization'] = "Bearer $($script:Settings.Token)" }
    $apiBase = "https://api.github.com/repos/$owner/$name"

    try {
        # GitHub returns the releases collection newest-first. Select ONE
        # release explicitly; avoid pipeline/array unrolling that can make
        # $rel contain every release and aggregate assets from the whole repo.
        $uri = "$apiBase/releases?per_page=100"
        $rawReleases = Invoke-RestMethod -Uri $uri -Headers $h -TimeoutSec 30 -ErrorAction Stop

        $releaseList = @()
        foreach ($entry in @($rawReleases)) {
            if ($entry -is [System.Array]) {
                foreach ($nestedEntry in $entry) {
                    if ($nestedEntry) { $releaseList += $nestedEntry }
                }
            } elseif ($entry) {
                $releaseList += $entry
            }
        }

        $stableRelease = $null
        $preRelease = $null
        foreach ($candidate in $releaseList) {
            if (-not $candidate -or $candidate.draft -eq $true) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$candidate.published_at)) { continue }

            if ($candidate.prerelease -eq $true) {
                if ($null -eq $preRelease) { $preRelease = $candidate }
            } else {
                if ($null -eq $stableRelease) { $stableRelease = $candidate }
            }
            if ($stableRelease) { break }
        }

        $selectedRelease = $stableRelease
        if ($null -eq $selectedRelease) { $selectedRelease = $preRelease }
        if ($null -ne $selectedRelease) {
            return @{ Release = $selectedRelease; Error = $null }
        }

        # Fallback to GitHub's Atom release feed when the API collection
        # contains no published releases.
        $feedUri = "https://github.com/$owner/$name/releases.atom"
        $feedResponse = Invoke-WebRequest -Uri $feedUri -Headers @{ 'User-Agent' = 'ReleaseUpdater' } -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
        [xml]$feed = $feedResponse.Content
        $entries = @($feed.SelectNodes("//*[local-name()='entry']"))
        $fallbackPrerelease = $null

        foreach ($entry in $entries) {
            $linkNode = $entry.SelectSingleNode("*[local-name()='link'][@rel='alternate']")
            if (-not $linkNode) { $linkNode = $entry.SelectSingleNode("*[local-name()='link']") }
            if (-not $linkNode) { continue }
            $href = [string]$linkNode.GetAttribute('href')
            if ($href -notmatch '/releases/tag/([^/?#]+)') { continue }
            $tag = [uri]::UnescapeDataString($Matches[1])
            $tagUri = "$apiBase/releases/tags/$([uri]::EscapeDataString($tag))"
            try {
                $candidate = Invoke-RestMethod -Uri $tagUri -Headers $h -TimeoutSec 30 -ErrorAction Stop
                if ($candidate -and ($candidate.draft -ne $true) -and
                    -not [string]::IsNullOrWhiteSpace([string]$candidate.published_at)) {
                    if ($candidate.prerelease -ne $true) {
                        return @{ Release = $candidate; Error = $null }
                    }
                    if ($null -eq $fallbackPrerelease) { $fallbackPrerelease = $candidate }
                }
            } catch {
                Write-Log "Release-feed lookup failed for tag '$tag': $($_.Exception.Message)"
            }
        }
        if ($null -ne $fallbackPrerelease) {
            return @{ Release = $fallbackPrerelease; Error = $null }
        }

        return @{ Release = $null; NoReleases = ($releaseList.Count -eq 0 -and $entries.Count -eq 0); Error = "No published releases found. Releases API returned $($releaseList.Count) item(s); Atom feed returned $($entries.Count) entr$(if ($entries.Count -eq 1) {'y'} else {'ies'})." }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 404)           { return @{ Release = $null; Error = 'Repository not found or no accessible releases' } }
        if ($code -in 401, 403, 429) { return (Get-GitHubRefusal $_ $code) }
        return @{ Release = $null; Error = $_.Exception.Message }
    }
}

# ----------------------------------------------------------------------------
# GitLab API (releases are normalised to the same shape GitHub returns, so the
# asset selection / download / update logic below works unchanged)
# ----------------------------------------------------------------------------
$script:KnownExt = '\.(zip|7z|rar|tar\.gz|tgz|tar\.xz|tar\.bz2|tar\.zst|gz|xz|exe|msi|msix|appx|appimage|deb|rpm|snap|flatpak|dmg|pkg|apk|jar|bin|iso|sh|run)$'

function Get-SafeFileName([string]$n) {
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $n = $n.Replace([string]$c, '_') }
    $n.Trim()
}

function ConvertTo-GitLabRelease($rel, [string]$owner = '', [string]$name = '') {
    $assets = @()
    foreach ($l in @($rel.assets.links)) {
        if (-not $l) { continue }
        $url = if ($l.direct_asset_url) { [string]$l.direct_asset_url } else { [string]$l.url }
        if (-not $url) { continue }
        $label = [string]$l.name
        $leaf = ''
        try { $leaf = [uri]::UnescapeDataString(([uri]$url).Segments[-1]).Trim('/') } catch {}

        # GitLab link "names" are free-text labels; the real filename is usually the URL's last segment
        if     ($leaf  -match $script:KnownExt) { $fname = $leaf }
        elseif ($label -match $script:KnownExt) { $fname = $label }
        elseif ($leaf)                          { $fname = $leaf }
        else                                    { $fname = $label }
        $fname = Get-SafeFileName $fname
        if (-not $fname) { continue }

        # classify on label + filename so a label like "Windows x64" still counts
        $classify = if ($label -and $label -ne $fname) { "$label $fname" } else { $fname }
        $assets += [pscustomobject]@{
            name = $fname; classify = $classify; size = [long]0
            browser_download_url = $url
        }
    }
    # Many authors attach nothing to the release itself and instead upload the files into the
    # release description (markdown links). If there are no attached links, read those instead.
    if ($assets.Count -eq 0 -and $rel.description) {
        $seen = @{}
        $rx = [regex]'\[(?<label>[^\]]*)\]\((?<url>[^)\s]+)[^)]*\)|(?<bare>https?://[^\s<>)\]]+)'
        foreach ($m in $rx.Matches([string]$rel.description)) {
            $label = ''
            if ($m.Groups['bare'].Success) { $url = $m.Groups['bare'].Value }
            else { $url = $m.Groups['url'].Value; $label = $m.Groups['label'].Value }
            $url = $url.TrimEnd('.', ',', ';')
            if ($url -notmatch '^https?://') {
                if     ($url -match '^/?uploads/') { $url = "https://gitlab.com/$owner/$name/" + $url.TrimStart('/') }
                elseif ($url.StartsWith('/'))      { $url = 'https://gitlab.com' + $url }
                else                               { continue }
            }
            $leaf = ''
            try { $leaf = [uri]::UnescapeDataString(([uri]$url).Segments[-1]).Trim('/') } catch {}
            if ($leaf -notmatch $script:KnownExt -or $seen.ContainsKey($url)) { continue }
            $seen[$url] = $true
            $fname = Get-SafeFileName $leaf
            $classify = if ($label -and $label -ne $fname) { "$label $fname" } else { $fname }
            $assets += [pscustomobject]@{ name = $fname; classify = $classify; size = [long]0; browser_download_url = $url }
        }
    }
    [pscustomobject]@{
        tag_name     = [string]$rel.tag_name
        name         = [string]$rel.name
        draft        = $false
        prerelease   = [bool]$rel.upcoming_release
        published_at = [string]$rel.released_at
        assets       = @($assets)
    }
}

function Get-LatestGitLabRelease([string]$owner, [string]$name) {
    $h = @{ 'User-Agent' = 'ReleaseUpdater' }
    if ($script:Settings.GitLabToken) { $h['PRIVATE-TOKEN'] = $script:Settings.GitLabToken }
    $proj = [uri]::EscapeDataString("$owner/$name")
    $uri  = "https://gitlab.com/api/v4/projects/$proj/releases?per_page=100&order_by=released_at&sort=desc"
    try {
        $raw  = Invoke-RestMethod -Uri $uri -Headers $h -TimeoutSec 30 -ErrorAction Stop
        $list = @()
        foreach ($entry in @($raw)) {
            if ($entry -is [System.Array]) { foreach ($x in $entry) { if ($x) { $list += $x } } }
            elseif ($entry)               { $list += $entry }
        }
        $stable = $null; $pre = $null
        foreach ($c in $list) {
            if (-not $c -or [string]::IsNullOrWhiteSpace([string]$c.tag_name)) { continue }
            if ($c.upcoming_release -eq $true) { if ($null -eq $pre) { $pre = $c } }
            else { $stable = $c; break }
        }
        $sel = $stable; if ($null -eq $sel) { $sel = $pre }
        if ($null -eq $sel) {
            return @{ Release = $null; NoReleases = ($list.Count -eq 0); Error = "No releases found. The GitLab Releases API returned $($list.Count) item(s) (tags without a Release are not used)." }
        }
        return @{ Release = (ConvertTo-GitLabRelease $sel $owner $name); Error = $null }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 404)           { return @{ Release = $null; Error = 'Project not found, or it has no accessible releases (private projects need a GitLab token)' } }
        if ($code -in 401, 403, 429) { return @{ Release = $null; Error = "GitLab refused the request ($code) - rate limit or bad token" } }
        return @{ Release = $null; Error = $_.Exception.Message }
    }
}

# GitLab release links carry no file size, so ask the server (HEAD) for the selected files only
function Get-RemoteSize([string]$url) {
    # Some hosts (GitLab uploads, object storage redirects) answer HEAD without a size or with an
    # error, so try HEAD, then a header-only GET, then a 1-byte range request.
    $client = $null
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('ReleaseUpdater')
        if ($script:Settings.GitLabToken -and ([uri]$url).Host -eq 'gitlab.com') {
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('PRIVATE-TOKEN', $script:Settings.GitLabToken)
        }
        foreach ($mode in 'HEAD', 'GET', 'RANGE') {
            $req = $null; $resp = $null
            try {
                $method = if ($mode -eq 'HEAD') { [System.Net.Http.HttpMethod]::Head } else { [System.Net.Http.HttpMethod]::Get }
                $req = New-Object System.Net.Http.HttpRequestMessage($method, $url)
                if ($mode -eq 'RANGE') { $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue(0, 0) }
                $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                if ($resp.IsSuccessStatusCode) {
                    $cr = $resp.Content.Headers.ContentRange
                    if ($cr -and $cr.Length) { return [long]$cr.Length }
                    $cl = $resp.Content.Headers.ContentLength
                    if ($cl -and ($mode -ne 'RANGE' -or [int]$resp.StatusCode -eq 200)) { return [long]$cl }
                }
            } catch {
            } finally {
                if ($resp) { $resp.Dispose() }
                if ($req)  { $req.Dispose() }
            }
        }
    } catch {
    } finally {
        if ($client) { $client.Dispose() }
    }
    return [long]0
}

# Used ONLY when a repo has no releases at all: build a pseudo-release that points at a zip of the
# default branch, pinned to its newest commit. The "tag" is branch@shortsha so the normal
# up-to-date / update-available comparison works (a new commit = an update).
function Get-SourceSnapshot($entry) {
    $owner = $entry.Owner; $name = $entry.Name
    try {
        if ($entry.Source -eq 'gitlab') {
            $h = @{ 'User-Agent' = 'ReleaseUpdater' }
            if ($script:Settings.GitLabToken) { $h['PRIVATE-TOKEN'] = $script:Settings.GitLabToken }
            $proj   = [uri]::EscapeDataString("$owner/$name")
            $info   = Invoke-RestMethod -Uri "https://gitlab.com/api/v4/projects/$proj" -Headers $h -TimeoutSec 30 -ErrorAction Stop
            $branch = [string]$info.default_branch
            if (-not $branch) { return @{ Release = $null; Error = 'No releases, and the repository has no default branch to download' } }
            $c   = Invoke-RestMethod -Uri "https://gitlab.com/api/v4/projects/$proj/repository/commits/$([uri]::EscapeDataString($branch))" -Headers $h -TimeoutSec 30 -ErrorAction Stop
            $sha = [string]$c.id
            $url = "https://gitlab.com/api/v4/projects/$proj/repository/archive.zip?sha=$sha"
            $when = [string]$c.committed_date
        } else {
            $h = @{ 'User-Agent' = 'ReleaseUpdater'; 'Accept' = 'application/vnd.github+json' }
            if ($script:Settings.Token) { $h['Authorization'] = "Bearer $($script:Settings.Token)" }
            $info   = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$name" -Headers $h -TimeoutSec 30 -ErrorAction Stop
            $branch = [string]$info.default_branch
            if (-not $branch) { return @{ Release = $null; Error = 'No releases, and the repository has no default branch to download' } }
            $c   = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$name/commits/$([uri]::EscapeDataString($branch))" -Headers $h -TimeoutSec 30 -ErrorAction Stop
            $sha = [string]$c.sha
            $url = "https://github.com/$owner/$name/archive/$sha.zip"
            $when = [string]$c.commit.committer.date
        }
        if (-not $sha) { return @{ Release = $null; Error = 'No releases, and the latest commit could not be determined' } }
        $short = $sha.Substring(0, [Math]::Min(7, $sha.Length))
        $file  = Get-SafeFileName "$name-$branch.zip"
        $rel = [pscustomobject]@{
            tag_name = "$branch@$short"; name = "Source snapshot ($branch)"; draft = $false; prerelease = $false
            published_at = $when; fallback = $true
            assets = @([pscustomobject]@{ name = $file; classify = $file; size = [long]0; browser_download_url = $url })
        }
        return @{ Release = $rel; Error = $null }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -in 401, 403, 404, 429) { return @{ Release = $null; Error = "No releases, and the source-zip fallback was refused ($code) - private repo, rate limit or bad token" } }
        return @{ Release = $null; Error = "No releases, and the source-zip fallback failed: $($_.Exception.Message)" }
    }
}

function Get-LatestRelease($entry) {
    $res = if ($entry.Source -eq 'gitlab') { Get-LatestGitLabRelease $entry.Owner $entry.Name }
           else                            { Get-LatestGitHubRelease $entry.Owner $entry.Name }
    # fallback strictly when the repo has NO releases; any other error is reported as-is
    if (-not $res.Release -and $res.NoReleases) {
        Write-Log "$($entry.Owner)/$($entry.Name): no releases - using a zip of the default branch instead"
        return (Get-SourceSnapshot $entry)
    }
    $res
}

function Get-AssetClassifyName($a) {
    if ($a.classify) { [string]$a.classify } else { [string]$a.name }
}

# ----------------------------------------------------------------------------
# Asset classification / selection
# ----------------------------------------------------------------------------
function Get-AssetInfo([string]$name) {
    $n = $name.ToLower()

    # checksums, signatures, source, debug symbols, metadata -> never download
    if ($n -match '\.(sha\d+|md5|sig|asc|pem|sbom|json|txt|yml|yaml|blockmap|sum|minisig|pub|cert|spdx|pdb|dsym)$|checksum|sha\d+sums|sbom|(^|[^a-z])(src|source|sources|debug|symbols|dbg)([^a-z]|$)') {
        return @{ Platform = 'skip'; Score = -999 }
    }

    # Archive extensions such as ZIP are intentionally platform-neutral.
    # Use filename tokens and genuinely platform-specific package formats.
    $win   = ($n -match '(^|[^a-z])(win(dows)?|win32|win64)([^a-z]|$)|msvc|mingw|windows') -or
             ($n -match '\.(exe|msi|msix|appx)$')
    $linux = ($n -match 'linux|ubuntu|debian|fedora|archlinux|appimage|(^|[^a-z])(gnu|musl)([^a-z]|$)') -or
             ($n -match '\.(appimage|deb|rpm|snap|flatpak)$')
    $mac   = ($n -match 'darwin|macos|(^|[^a-z])(mac|osx|apple)([^a-z]|$)') -or ($n -match '\.(dmg|pkg)$')
    $other = ($n -match 'android|freebsd|openbsd|netbsd|solaris|illumos|(^|[^a-z])(ios|wasm)([^a-z]|$)') -or ($n -match '\.(apk|vsix|nupkg|whl|gem)$')

    $plat = 'generic'
    if     (($mac -or $other) -and -not ($win -or $linux)) { $plat = 'other' }
    elseif ($win -and -not $linux)                         { $plat = 'windows' }
    elseif ($linux -and -not $win)                         { $plat = 'linux' }

    # architecture
    $s = 0
    if ($n -match 'x64|x86_64|x86-64|amd64|win64|64-?bit')   { $s += 10 }
    if ($n -match '(^|[^a-z])(arm|aarch)')                   { $s -= 20 }
    if ($n -match 'ia32|i386|i686|win32|32-?bit|x86(?![_-]?64)') { $s -= 15 }

    # format
    $prefInst = [bool]$script:Settings.PreferInstaller
    switch ($plat) {
        'windows' {
            $inst = $n -match '\.(exe|msi|msix|appx)$'
            $arch = $n -match '\.(zip|7z|rar)$'
            if ($prefInst) {
                if ($inst) { $s += 6 } elseif ($arch) { $s += 3 }
                if ($n -match 'setup|install') { $s += 2 }
            } else {
                if ($n -match 'portable') { $s += 5 }
                if ($arch) { $s += 4 } elseif ($inst) { $s += 3 }
            }
        }
        'linux' {
            if     ($n -match '\.(tar\.gz|tgz|tar\.xz|tar\.bz2|tar\.zst|zip|appimage)$') { $s += 5 }
            elseif ($n -match '\.(deb|rpm)$')                                            { $s += 1 }
            elseif ($n -match '\.(snap|flatpak)$')                                       { $s -= 3 }
            elseif ($n -notmatch '\.[a-z0-9]{1,5}$')                                     { $s += 4 }
            if ($n -match 'musl') { $s -= 1 }
        }
        'generic' {
            if ($n -match '\.(zip|7z|rar|tar\.gz|tgz|tar\.xz|tar\.bz2|tar\.zst)$') { $s += 2 }
        }
    }
    @{ Platform = $plat; Score = $s }
}

function Set-AssetPlatform($asset, [string]$plat) {
    Add-Member -InputObject $asset -NotePropertyName Platform -NotePropertyValue $plat -Force -PassThru
}

function Select-Assets($assets, [string]$pattern) {
    $assets = @($assets)
    if ($assets.Count -eq 0) { return @() }
    $plats  = @(Get-EnabledPlatforms)
    $result = @()

    # parse overrides:  "glob"  or  "win:glob"  or  "linux:glob"
    $pats = @()
    if ($pattern) {
        foreach ($p in ($pattern -split ',')) {
            $p = $p.Trim(); if (-not $p) { continue }
            if ($p -match '^(win|windows|linux):(.+)$') {
                $pl = if ($matches[1] -eq 'linux') { 'linux' } else { 'windows' }
                $pats += [pscustomobject]@{ Plat = $pl; Glob = $matches[2].Trim() }
            } else {
                $pats += [pscustomobject]@{ Plat = 'any'; Glob = $p }
            }
        }
    }

    # plain patterns -> exactly those files, no auto-detection
    $anyPats = @($pats | Where-Object { $_.Plat -eq 'any' })
    if ($anyPats.Count -gt 0) {
        foreach ($a in $assets) {
            foreach ($p in $anyPats) { if ($a.name -like $p.Glob) { $result += (Set-AssetPlatform $a 'custom'); break } }
        }
        return $result
    }

    $infos = @{}
    foreach ($a in $assets) { $infos[$a.name] = Get-AssetInfo (Get-AssetClassifyName $a) }

    foreach ($pl in $plats) {
        $pp = @($pats | Where-Object { $_.Plat -eq $pl })
        if ($pp.Count -gt 0) {
            foreach ($a in $assets) {
                foreach ($p in $pp) { if ($a.name -like $p.Glob) { $result += (Set-AssetPlatform $a $pl); break } }
            }
        } else {
            $best = $null; $bs = -999
            foreach ($a in $assets) {
                $i = $infos[$a.name]
                if ($i.Platform -eq $pl -and $i.Score -gt $bs) { $best = $a; $bs = $i.Score }
            }
            if ($best -and $bs -gt -20) { $result += (Set-AssetPlatform $best $pl) }   # never pick ARM-only
        }
    }

    # If a release has one clearly identified platform asset plus exactly one
    # otherwise-generic binary/archive (for example Tool.AppImage + Tool.zip),
    # infer that the generic file is for the other enabled platform. This makes
    # common mixed-format Windows/Linux releases work without treating ZIP as
    # inherently Windows or Linux.
    $genericAssets = @($assets | Where-Object { $infos[$_.name].Platform -eq 'generic' })
    if ($genericAssets.Count -eq 1 -and $result.Count -gt 0) {
        $selectedPlatforms = @($result | ForEach-Object { $_.Platform } | Select-Object -Unique)
        $missingPlatforms = @($plats | Where-Object { $selectedPlatforms -notcontains $_ })
        if ($missingPlatforms.Count -eq 1) {
            $gi = $infos[$genericAssets[0].name]
            if ($gi.Score -gt -20) {
                $result += (Set-AssetPlatform $genericAssets[0] $missingPlatforms[0])
            }
        }
    }

    # If the release has no OS-specific names at all (one generic ZIP, JAR,
    # etc.), use the best generic file once rather than downloading it twice.
    $tagged = @($infos.Values | Where-Object { $_.Platform -eq 'windows' -or $_.Platform -eq 'linux' })
    if ($result.Count -eq 0 -and $tagged.Count -eq 0) {
        $best = $null; $bs = -999
        foreach ($a in $assets) {
            $i = $infos[$a.name]
            if ($i.Platform -eq 'generic' -and $i.Score -gt $bs) { $best = $a; $bs = $i.Score }
        }
        if ($best -and $bs -gt -20) { $result += (Set-AssetPlatform $best 'any') }
    }
    $result
}

# ----------------------------------------------------------------------------
# Download with progress
# ----------------------------------------------------------------------------
function Save-Asset([string]$url, [string]$dest, [long]$expected, [string]$label) {
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromHours(2)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('ReleaseUpdater')
    try { if ($script:Settings.GitLabToken -and ([uri]$url).Host -eq 'gitlab.com') { [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('PRIVATE-TOKEN', $script:Settings.GitLabToken) } } catch {}
    $resp = $null; $in = $null; $out = $null
    try {
        $resp = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        [void]$resp.EnsureSuccessStatusCode()
        $total = $expected
        if ($total -le 0 -and $resp.Content.Headers.ContentLength) { $total = [long]$resp.Content.Headers.ContentLength }
        $in  = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = [IO.File]::Create($dest)
        $buf = New-Object byte[] 81920
        $done = [long]0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $last = -1000
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if ($sw.ElapsedMilliseconds - $last -ge 100) {
                $last = $sw.ElapsedMilliseconds
                $pct = if ($total -gt 0) { [Math]::Min(100, [int](($done * 100) / $total)) } else { 0 }
                $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { $done / $sw.Elapsed.TotalSeconds } else { 0 }
                $pb.Value = $pct
                $lblProgress.Text = "$label   $pct%   ($(Format-Size $done) / $(Format-Size $total))   $(Format-Size $speed)/s"
                [System.Windows.Forms.Application]::DoEvents()
                if ($script:Cancel) { throw 'Cancelled by user' }
            }
        }
        $pb.Value = 100
        $lblProgress.Text = "$label   100%   ($(Format-Size $done))"
    } finally {
        if ($out)  { $out.Dispose() }
        if ($in)   { $in.Dispose() }
        if ($resp) { $resp.Dispose() }
        $client.Dispose()
    }
}

function Download-Repo($item, [int]$idx, [int]$count) {
    $r = $item.Tag
    $folder = Get-RepoFolder $r.Entry
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    $old = Read-Marker $r.Entry
    $oldFiles = if ($old) { @($old.files) } else { @() }
    $newFiles = @()
    try {
        foreach ($a in $r.Assets) {
            $dest = Join-Path $folder $a.name
            $tmp  = "$dest.part"
            $label = "[$idx/$count] $($r.Entry.Name) ($($a.Platform)) - $($a.name)"
            try { Save-Asset $a.browser_download_url $tmp ([long]$a.size) $label }
            catch { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }; throw }
            Move-Item -LiteralPath $tmp -Destination $dest -Force
            $newFiles += $a.name
        }
    } catch {
        # roll back files of the new version that were already completed
        foreach ($f in $newFiles) {
            if ($oldFiles -notcontains $f) {
                $p = Join-Path $folder $f
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
            }
        }
        throw
    }
    # success: remove the previous version's files
    foreach ($f in $oldFiles) {
        if ($newFiles -notcontains $f) {
            $p = Join-Path $folder $f
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
    }
    Write-Marker $r.Entry $r.Release.tag_name $newFiles
}

# Notepad++ if it is installed (standard folders, registry, or PATH); otherwise $null -> plain Notepad
function Get-NotepadPlusPlus {
    $cands = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ($base) { $cands += (Join-Path $base 'Notepad++\notepad++.exe') }
    }
    foreach ($key in 'HKLM:\SOFTWARE\Notepad++', 'HKLM:\SOFTWARE\WOW6432Node\Notepad++', 'HKCU:\SOFTWARE\Notepad++') {
        try {
            $dir = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
            if (-not $dir) { $dir = (Get-Item -LiteralPath $key -ErrorAction Stop).GetValue('') }
            if ($dir) { $cands += (Join-Path $dir 'notepad++.exe') }
        } catch {}
    }
    try { $cmd = Get-Command 'notepad++.exe' -ErrorAction Stop; if ($cmd.Source) { $cands += $cmd.Source } } catch {}
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# ----------------------------------------------------------------------------
# GUI
# ----------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Release Updater  -  GitHub + GitLab'
$form.Size = New-Object System.Drawing.Size(1180, 800)
$form.MinimumSize = New-Object System.Drawing.Size(950, 620)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$PanelW = 1164

function New-Label($text, $x, $y, $w = 140) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, ($y + 4)); $l.Size = New-Object System.Drawing.Size($w, 20)
    $l
}
function New-Button($text, $x, $y, $w, $h = 28) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'System'
    $b
}
function New-Text($x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, 24)
    $t
}
function New-Check($text, $x, $y, $w, [bool]$checked) {
    $c = New-Object ModernCheck
    $c.Text = $text; $c.Location = New-Object System.Drawing.Point($x, ($y + 2)); $c.Size = New-Object System.Drawing.Size($w, 22)
    $c.Checked = $checked
    $c
}

# --- list ---
$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $false
$lv.HideSelection = $false; $lv.MultiSelect = $true
$lv.BorderStyle = 'None'; $lv.OwnerDraw = $true
# taller rows (a 1x30 image list is the standard WinForms trick) + flicker-free painting
$rowImages = New-Object System.Windows.Forms.ImageList
$rowImages.ImageSize = New-Object System.Drawing.Size(1, 30)
$lv.SmallImageList = $rowImages
try { $lv.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($lv, $true, $null) } catch {}
[void]$lv.Columns.Add('#', 40)
[void]$lv.Columns.Add('Repository', 230)
[void]$lv.Columns.Add('Source', 70)
[void]$lv.Columns.Add('Downloaded', 120)
[void]$lv.Columns.Add('Latest', 120)
[void]$lv.Columns.Add('Status', 130)
[void]$lv.Columns.Add('Download size', 100)
[void]$lv.Columns.Add('Files to download', 400)

# --- bottom panel ---
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Size = New-Object System.Drawing.Size($PanelW, 210); $bottom.Dock = 'Bottom'

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text = 'Idle'; $lblProgress.Location = New-Object System.Drawing.Point(12, 8)
$lblProgress.Size = New-Object System.Drawing.Size(($PanelW - 24), 20); $lblProgress.Anchor = 'Top,Left,Right'

$pb = New-Object SlimProgressBar
$pb.Location = New-Object System.Drawing.Point(12, 34); $pb.Size = New-Object System.Drawing.Size(($PanelW - 24), 10)
$pb.Anchor = 'Top,Left,Right'; $pb.Minimum = 0; $pb.Maximum = 100

$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Text = ''; $lblSummary.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblSummary.Location = New-Object System.Drawing.Point(12, 60); $lblSummary.Size = New-Object System.Drawing.Size(($PanelW - 24), 20)
$lblSummary.Anchor = 'Top,Left,Right'

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
$txtLog.Location = New-Object System.Drawing.Point(12, 86); $txtLog.Size = New-Object System.Drawing.Size(($PanelW - 24), 116)
$txtLog.Anchor = 'Top,Bottom,Left,Right'; $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$bottom.Controls.AddRange(@($lblProgress, $pb, $lblSummary, $txtLog))

# --- action bar ---
$actions = New-Object System.Windows.Forms.Panel
$actions.Size = New-Object System.Drawing.Size($PanelW, 46); $actions.Dock = 'Top'
$btnCheck  = New-Button 'Check for updates'     12  8 150 30
$btnCheckSel = New-Button 'Check selected'      172 8 130 30
$btnAll    = New-Button 'Download / update all' 312 8 160 30
$btnSel    = New-Button 'Download selected'     482 8 150 30
$btnCancel = New-Button 'Cancel'                642 8 90  30
$btnCancel.Enabled = $false
$btnCheck.Tag = 'primary'; $btnAll.Tag = 'primary'
$actions.Controls.AddRange(@($btnCheck, $btnCheckSel, $btnAll, $btnSel, $btnCancel))

# --- top panel (repo + settings) ---
$top = New-Object System.Windows.Forms.Panel
$top.Size = New-Object System.Drawing.Size($PanelW, 174); $top.Dock = 'Top'

$txtAdd = New-Text 175 10 594; $txtAdd.Anchor = 'Top,Left,Right'
$btnAdd    = New-Button 'Add'                 779 8 70;  $btnAdd.Anchor = 'Top,Right'
$btnRemove = New-Button 'Remove selected'     859 8 130; $btnRemove.Anchor = 'Top,Right'
$script:Editor = Get-NotepadPlusPlus
$btnEdit   = New-Button $(if ($script:Editor) { 'Edit list (Notepad++)' } else { 'Edit list (Notepad)' }) 999 8 145; $btnEdit.Anchor = 'Top,Right'

$txtFolder = New-Text 175 42 594; $txtFolder.Anchor = 'Top,Left,Right'
$txtFolder.Text = $script:Settings.DownloadRoot
$btnBrowse = New-Button 'Browse...'   779 40 70;  $btnBrowse.Anchor = 'Top,Right'
$btnOpen   = New-Button 'Open folder' 859 40 130; $btnOpen.Anchor = 'Top,Right'

$txtToken = New-Text 175 74 594; $txtToken.Anchor = 'Top,Left,Right'
$txtToken.UseSystemPasswordChar = $true
$txtToken.Text = $script:Settings.Token
$lblHint = New-Label 'Optional - avoids GitHub rate limits' 779 72 300; $lblHint.Anchor = 'Top,Right'
$lblHint.Tag = 'muted'

$txtGitLabToken = New-Text 175 106 594; $txtGitLabToken.Anchor = 'Top,Left,Right'
$txtGitLabToken.UseSystemPasswordChar = $true
$txtGitLabToken.Text = $script:Settings.GitLabToken
$lblHint2 = New-Label 'Optional - private projects / rate limits' 779 104 300; $lblHint2.Anchor = 'Top,Right'
$lblHint2.Tag = 'muted'

$chkWin       = New-Check 'Windows' 175 136 85  $script:Settings.Windows
$chkLinux     = New-Check 'Linux'   265 136 75  $script:Settings.Linux
$chkInstaller = New-Check 'Prefer installers (.exe/.msi) over portable/zip on Windows' 350 136 420 $script:Settings.PreferInstaller
$chkDark      = New-Check 'Dark mode' 1030 136 110 $script:Settings.Dark; $chkDark.Anchor = 'Top,Right'

$top.Controls.AddRange(@(
    (New-Label 'Add repo (paste URL):' 12 8 160), $txtAdd, $btnAdd, $btnRemove, $btnEdit,
    (New-Label 'Download folder:' 12 40 160), $txtFolder, $btnBrowse, $btnOpen,
    (New-Label 'GitHub token:' 12 72 160), $txtToken, $lblHint,
    (New-Label 'GitLab token:' 12 104 160), $txtGitLabToken, $lblHint2,
    (New-Label 'Platforms:' 12 134 160), $chkWin, $chkLinux, $chkInstaller, $chkDark
))

# Dock order: Fill first, then Bottom, then Top panels (last added is docked first)
$form.Controls.Add($lv)
$form.Controls.Add($bottom)
$form.Controls.Add($actions)
$form.Controls.Add($top)

# ----------------------------------------------------------------------------
# Theme (dark / light)
# ----------------------------------------------------------------------------
function New-Rgb([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }

function Get-Palette([bool]$dark) {
    if ($dark) {
        @{
            Bg = (New-Rgb 20 22 28);  Surface = (New-Rgb 28 31 38); Header = (New-Rgb 24 27 33)
            Border = (New-Rgb 44 49 60); BorderStrong = (New-Rgb 70 77 92); RowLine = (New-Rgb 36 40 49)
            Text = (New-Rgb 226 229 235); Muted = (New-Rgb 128 136 150); Disabled = (New-Rgb 84 90 102)
            Accent = (New-Rgb 99 132 240); AccentHover = (New-Rgb 121 151 250); AccentDown = (New-Rgb 80 110 214)
            AccentText = (New-Rgb 255 255 255)
            BtnBg = (New-Rgb 34 38 47); BtnHover = (New-Rgb 44 49 61); BtnDown = (New-Rgb 54 60 74)
            Select = (New-Rgb 38 48 82); Track = (New-Rgb 36 40 49)
            Ok = (New-Rgb 112 208 152); Warn = (New-Rgb 240 178 80); Info = (New-Rgb 116 170 255); Err = (New-Rgb 242 116 124)
        }
    } else {
        @{
            Bg = (New-Rgb 244 245 248); Surface = (New-Rgb 255 255 255); Header = (New-Rgb 236 238 243)
            Border = (New-Rgb 216 220 228); BorderStrong = (New-Rgb 176 183 196); RowLine = (New-Rgb 233 236 242)
            Text = (New-Rgb 30 34 42); Muted = (New-Rgb 112 120 134); Disabled = (New-Rgb 170 176 186)
            Accent = (New-Rgb 59 100 225); AccentHover = (New-Rgb 80 118 235); AccentDown = (New-Rgb 45 82 200)
            AccentText = (New-Rgb 255 255 255)
            BtnBg = (New-Rgb 255 255 255); BtnHover = (New-Rgb 238 241 248); BtnDown = (New-Rgb 226 231 242)
            Select = (New-Rgb 218 228 252); Track = (New-Rgb 224 228 236)
            Ok = (New-Rgb 20 140 70); Warn = (New-Rgb 200 110 0); Info = (New-Rgb 0 90 200); Err = (New-Rgb 178 34 34)
        }
    }
}

function Set-ButtonLook($b) {
    $p = $script:Pal
    $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false
    $b.FlatAppearance.BorderSize = 1
    $b.Cursor = if ($b.Enabled) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    if (-not $b.Enabled) {
        $b.BackColor = $p.Bg; $b.ForeColor = $p.Disabled
        $b.FlatAppearance.BorderColor = $p.Border
        $b.FlatAppearance.MouseOverBackColor = $p.Bg; $b.FlatAppearance.MouseDownBackColor = $p.Bg
    } elseif ($b.Tag -eq 'primary') {
        $b.BackColor = $p.Accent; $b.ForeColor = $p.AccentText
        $b.FlatAppearance.BorderColor = $p.Accent
        $b.FlatAppearance.MouseOverBackColor = $p.AccentHover; $b.FlatAppearance.MouseDownBackColor = $p.AccentDown
    } else {
        $b.BackColor = $p.BtnBg; $b.ForeColor = $p.Text
        $b.FlatAppearance.BorderColor = $p.BorderStrong
        $b.FlatAppearance.MouseOverBackColor = $p.BtnHover; $b.FlatAppearance.MouseDownBackColor = $p.BtnDown
    }
}

function Set-ControlTheme($parent) {
    $p = $script:Pal
    foreach ($c in $parent.Controls) {
        if     ($c -is [System.Windows.Forms.Button]) { Set-ButtonLook $c }
        elseif ($c -is [System.Windows.Forms.TextBox]) {
            $c.BackColor = $p.Surface; $c.ForeColor = $p.Text; $c.BorderStyle = 'FixedSingle'
        }
        elseif ($c -is [ModernCheck]) {
            $c.BackColor = $p.Bg; $c.ForeColor = $p.Text
            $c.BoxFill = $p.Surface; $c.BoxBorder = $p.BorderStrong; $c.AccentColor = $p.Accent; $c.DisabledColor = $p.Disabled
            $c.Invalidate()
        }
        elseif ($c -is [SlimProgressBar]) {
            $c.BackColor = $p.Bg; $c.TrackColor = $p.Track; $c.BarColor = $p.Accent; $c.Invalidate()
        }
        elseif ($c -is [System.Windows.Forms.Label]) {
            $c.BackColor = $p.Bg
            $c.ForeColor = if ($c.Tag -eq 'muted') { $p.Muted } else { $p.Text }
        }
        elseif ($c -is [System.Windows.Forms.Panel]) { $c.BackColor = $p.Bg }
        if ($c.Controls.Count -gt 0) { Set-ControlTheme $c }
    }
}

# dark title bar + dark scrollbars (Windows 10 1809+ / Windows 11; silently ignored elsewhere)
function Set-NativeTheme {
    $d = [bool]$script:Settings.Dark
    try {
        if ($form.IsHandleCreated) { [NativeTheme]::TitleBar($form.Handle, $d) }
        foreach ($c in @($lv, $txtLog)) { if ($c.IsHandleCreated) { [NativeTheme]::Scroll($c.Handle, $d) } }
    } catch {}
}

function Set-Theme {
    $script:Pal = Get-Palette ([bool]$script:Settings.Dark)
    $p = $script:Pal
    $form.BackColor = $p.Bg; $form.ForeColor = $p.Text
    Set-ControlTheme $form
    $lv.BackColor = $p.Surface; $lv.ForeColor = $p.Text
    $txtLog.ForeColor = $p.Text
    $lv.Invalidate()
    Set-NativeTheme
}

$lblProgress.Tag = 'muted'
$script:TextFlags = [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis, NoPrefix'

# owner-drawn list: header, cells, subtle row separators, status colour only on the Status column
$lv.Add_DrawColumnHeader({
    param($s, $e)
    try {
        $p = $script:Pal
        $br = New-Object System.Drawing.SolidBrush($p.Header)
        $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $pen = New-Object System.Drawing.Pen($p.Border)
        $e.Graphics.DrawLine($pen, $e.Bounds.Left, ($e.Bounds.Bottom - 1), $e.Bounds.Right, ($e.Bounds.Bottom - 1))
        $e.Graphics.DrawLine($pen, ($e.Bounds.Right - 1), ($e.Bounds.Top + 6), ($e.Bounds.Right - 1), ($e.Bounds.Bottom - 7))
        $pen.Dispose()
        $tr = New-Object System.Drawing.Rectangle(($e.Bounds.X + 8), $e.Bounds.Y, ($e.Bounds.Width - 12), $e.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, $tr, $p.Muted, $script:TextFlags)
    } catch {}
})
$lv.Add_DrawSubItem({
    param($s, $e)
    try {
        $p = $script:Pal
        $b = $e.Bounds
        $w = if ($e.ColumnIndex -eq 0) { $s.Columns[0].Width } else { $b.Width }
        $rect = New-Object System.Drawing.Rectangle($b.X, $b.Y, $w, $b.Height)
        $bg = if ($e.Item.Selected) { $p.Select } else { $p.Surface }
        $br = New-Object System.Drawing.SolidBrush($bg)
        $e.Graphics.FillRectangle($br, $rect); $br.Dispose()
        $pen = New-Object System.Drawing.Pen($p.RowLine)
        $e.Graphics.DrawLine($pen, $rect.Left, ($rect.Bottom - 1), $rect.Right, ($rect.Bottom - 1)); $pen.Dispose()
        $fc = $p.Text
        if     ($e.ColumnIndex -in 0, 2, 7) { $fc = $p.Muted }
        elseif ($e.ColumnIndex -eq 5)       { $fc = $e.Item.ForeColor }
        $tr = New-Object System.Drawing.Rectangle(($rect.X + 8), $rect.Y, [Math]::Max(1, ($rect.Width - 12)), $rect.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $s.Font, $tr, $fc, $script:TextFlags)
    } catch {}
})

# keep the last column filling the window
function Resize-LastColumn {
    try {
        $used = 0
        for ($i = 0; $i -lt ($lv.Columns.Count - 1); $i++) { $used += $lv.Columns[$i].Width }
        $lv.Columns[$lv.Columns.Count - 1].Width = [Math]::Max(250, ($lv.ClientSize.Width - $used))
    } catch {}
}
$lv.Add_Resize({ Resize-LastColumn })

Set-Theme

# ----------------------------------------------------------------------------
# List handling
# ----------------------------------------------------------------------------
function Update-Item($item) {
    $r = $item.Tag
    $item.SubItems[1].Text = "$($r.Entry.Owner)/$($r.Entry.Name)"
    $item.SubItems[2].Text = $(if ($r.Entry.Source -eq 'gitlab') { 'GitLab' } else { 'GitHub' })
    $item.SubItems[3].Text = $r.Installed
    $item.SubItems[4].Text = $r.Latest
    $item.SubItems[5].Text = $r.Status
    $pending = ($r.Status -eq 'Update available' -or $r.Status -eq 'Not downloaded')
    $item.SubItems[6].Text = if ($pending -and $r.Size -gt 0) { Format-Size $r.Size } elseif ($pending -and @($r.Assets).Count -gt 0) { 'unknown' } else { '' }
    $item.SubItems[7].Text = $r.Files
    $item.ToolTipText = if ($r.Message) { [string]$r.Message } else { [string]$r.Files }
    $pal = $script:Pal
    $item.ForeColor = switch ($r.Status) {
        'Up to date'       { $pal.Ok }
        'Update available' { $pal.Warn }
        'Not downloaded'   { $pal.Info }
        'Error'            { $pal.Err }
        default            { $pal.Text }
    }
}

function Load-List {
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $i = 0
    foreach ($e in (Get-Repos)) {
        $i++
        $m = Read-Marker $e
        $row = @{
            Entry = $e; Installed = $(if ($m) { [string]$m.tag } else { '-' }); Latest = '?'
            Status = 'Not checked'; Size = 0; Assets = @(); Release = $null; Message = ''; Files = ''
        }
        $item = New-Object System.Windows.Forms.ListViewItem($i.ToString())
        1..7 | ForEach-Object { [void]$item.SubItems.Add('') }
        $item.Tag = $row
        [void]$lv.Items.Add($item)
        Update-Item $item
    }
    $lv.EndUpdate()
}

function Update-Summary {
    $up = 0; $pend = 0; $err = 0; $size = [long]0
    foreach ($item in $lv.Items) {
        switch ($item.Tag.Status) {
            'Up to date'       { $up++ }
            'Update available' { $pend++; $size += $item.Tag.Size }
            'Not downloaded'   { $pend++; $size += $item.Tag.Size }
            'Error'            { $err++ }
        }
    }
    $lblSummary.Text = "Up to date: $up     Can be downloaded/updated: $pend     Total download size: $(Format-Size $size)     Errors: $err"
}

function Set-Busy([bool]$b) {
    $script:Busy = $b
    foreach ($c in @($btnCheck, $btnCheckSel, $btnAll, $btnSel, $btnAdd, $btnRemove, $btnEdit, $btnBrowse, $chkWin, $chkLinux, $chkInstaller)) { $c.Enabled = -not $b }
    $btnCancel.Enabled = $b
}

# ----------------------------------------------------------------------------
# Checking
# ----------------------------------------------------------------------------
function Check-Items($items) {
    foreach ($item in $items) {
        if ($script:Cancel) { break }
        $r = $item.Tag
        $name = "$($r.Entry.Owner)/$($r.Entry.Name)"
        $r.Status = 'Checking...'; Update-Item $item
        [System.Windows.Forms.Application]::DoEvents()

        $m = Read-Marker $r.Entry
        $r.Installed = if ($m) { [string]$m.tag } else { '-' }

        $res = Get-LatestRelease $r.Entry
        if ($res.Error) {
            $r.Status = 'Error'; $r.Latest = '-'; $r.Message = $res.Error; $r.Release = $null; $r.Size = 0; $r.Files = ''
            Write-Log "CHECK FAILED: ${name}: $($res.Error)"
            Update-Item $item
            if ($res.RateLimited) { Write-Log 'Stopped checking: every remaining GitHub request would fail the same way.'; break }
            continue
        }
        $rel = $res.Release
        if ($rel.fallback) { $assets = @($rel.assets | ForEach-Object { Set-AssetPlatform $_ 'source' }) }
        else               { $assets = @(Select-Assets $rel.assets $r.Entry.Pattern) }
        $r.Release = $rel; $r.Latest = [string]$rel.tag_name; $r.Assets = $assets
        if ($r.Entry.Source -eq 'gitlab' -and -not $rel.fallback) {
            foreach ($a in $assets) {
                if ([long]$a.size -le 0) { $a.size = Get-RemoteSize $a.browser_download_url; [System.Windows.Forms.Application]::DoEvents() }
            }
        }
        $r.Size = [long](($assets | Measure-Object -Property size -Sum).Sum)
        $r.Files = (($assets | ForEach-Object { "$($_.Platform): $($_.name)" }) -join '   |   ')
        $selectedAssetDetails = @($assets | ForEach-Object { "$($_.Platform): $($_.name) ($(Format-Size ([long]$_.size)))" }) -join '; '
        Write-Log "Release selected for ${name}: tag=$($rel.tag_name); prerelease=$($rel.prerelease); assetCount=$($rel.assets.Count); selected=[$selectedAssetDetails]"

        if ($assets.Count -eq 0) {
            $r.Status = 'Error'; $r.Message = 'No matching file in latest release'
            $assetDiagnostics = @($rel.assets | ForEach-Object { $ai = Get-AssetInfo (Get-AssetClassifyName $_); "$($_.name) [platform=$($ai.Platform); score=$($ai.Score)]" }) -join '; '
            $r.Message = "No assets matched. Release=$($rel.tag_name); prerelease=$($rel.prerelease); enabled=$((Get-EnabledPlatforms) -join ','); assets=$assetDiagnostics"
            Write-Log "ASSET SELECTION FAILED: ${name}: $($r.Message)"
            Update-Item $item; continue
        }

        # warn when one wanted platform has no file in this release
        $manual = @($assets | Where-Object { $_.Platform -eq 'custom' -or $_.Platform -eq 'any' -or $_.Platform -eq 'source' })
        if ($manual.Count -eq 0) {
            foreach ($pl in (Get-EnabledPlatforms)) {
                if (-not (@($assets | Where-Object { $_.Platform -eq $pl }).Count)) {
                    Write-Log "${name}: no $pl file found in $($rel.tag_name)"
                }
            }
        }

        $folder = Get-RepoFolder $r.Entry
        $filesOk = $false
        if ($m -and @($m.files).Count -gt 0) {
            $filesOk = -not (@($m.files) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $folder $_)) })
        }
        if     ($m -and $filesOk -and $m.tag -eq $rel.tag_name) { $r.Status = 'Up to date' }
        elseif ($m -and $filesOk)                                { $r.Status = 'Update available' }
        else                                                     { $r.Status = 'Not downloaded' }
        Update-Item $item
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Write-Report {
    $up = @(); $pend = @()
    foreach ($item in $lv.Items) {
        $r = $item.Tag; $n = "$($r.Entry.Owner)/$($r.Entry.Name)"
        if ($r.Status -eq 'Up to date') { $up += $n }
        elseif ($r.Status -eq 'Update available') { $pend += "$n ($($r.Installed) -> $($r.Latest), $(Format-Size $r.Size))" }
        elseif ($r.Status -eq 'Not downloaded')   { $pend += "$n (new: $($r.Latest), $(Format-Size $r.Size))" }
    }
    Write-Log ("At latest version : " + $(if ($up.Count) { $up -join ', ' } else { 'none' }))
    Write-Log ("Can be downloaded : " + $(if ($pend.Count) { $pend -join '; ' } else { 'none' }))
}

function Invoke-Check($items) {
    if ($script:Busy) { return }
    if (-not (Test-Platforms)) { return }
    Set-Busy $true; $script:Cancel = $false
    try {
        Save-Settings
        if (-not $items) { $items = @($lv.Items) }
        Check-Items $items
        Write-Report
    } catch {
        Write-Log "Error: $($_.Exception.Message)"
    } finally {
        Set-Busy $false; Update-Summary
    }
}

# ----------------------------------------------------------------------------
# Downloading
# ----------------------------------------------------------------------------
function Invoke-Download($items) {
    if ($script:Busy) { return }
    if (-not (Test-Platforms)) { return }
    Set-Busy $true; $script:Cancel = $false
    try {
        Save-Settings
        # re-check anything not checked yet (or checked before platform settings changed)
        $unchecked = @($items | Where-Object { $_.Tag.Release -eq $null -and $_.Tag.Status -ne 'Error' })
        if ($unchecked.Count) { Check-Items $unchecked }

        $todo = @($items | Where-Object { $_.Tag.Status -eq 'Update available' -or $_.Tag.Status -eq 'Not downloaded' })
        if ($todo.Count -eq 0) { Write-Log 'Nothing to download.'; return }

        $total = [long]0; foreach ($t in $todo) { $total += $t.Tag.Size }
        Write-Log "Downloading $($todo.Count) repo(s), total $(Format-Size $total) ..."
        if (-not (Test-Path -LiteralPath $script:Settings.DownloadRoot)) {
            [void](New-Item -ItemType Directory -Path $script:Settings.DownloadRoot -Force)
        }

        $i = 0
        foreach ($item in $todo) {
            $i++
            if ($script:Cancel) { break }
            $r = $item.Tag; $name = "$($r.Entry.Owner)/$($r.Entry.Name)"
            $prev = $r.Status
            $r.Status = 'Downloading...'; Update-Item $item; $pb.Value = 0
            try {
                Download-Repo $item $i $todo.Count
                $r.Installed = $r.Latest; $r.Status = 'Up to date'
                Write-Log "OK: $name -> $($r.Latest)  ($($r.Files))"
            } catch {
                $r.Status = $prev
                Write-Log "FAILED: $name - $($_.Exception.Message)"
                if ($_.Exception.Message -eq 'Cancelled by user') { $script:Cancel = $true }
            }
            Update-Item $item
            Update-Summary
        }
        Write-Log $(if ($script:Cancel) { 'Stopped.' } else { 'Finished.' })
    } catch {
        Write-Log "Error: $($_.Exception.Message)"
    } finally {
        $lblProgress.Text = 'Idle'; $pb.Value = 0
        Set-Busy $false; Update-Summary
    }
}

# ----------------------------------------------------------------------------
# Events
# ----------------------------------------------------------------------------
$btnCheck.Add_Click({ if (-not $script:Busy) { Load-List; Invoke-Check $null } })
$btnCheckSel.Add_Click({
    $sel = @($lv.SelectedItems)
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Select one or more repos in the list first.', 'Nothing selected'); return }
    Invoke-Check $sel
})
$btnAll.Add_Click({ Invoke-Download @($lv.Items) })
$btnSel.Add_Click({
    $sel = @($lv.SelectedItems)
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Select one or more repos in the list first.', 'Nothing selected'); return }
    Invoke-Download $sel
})
$btnCancel.Add_Click({ $script:Cancel = $true })

$btnAdd.Add_Click({
    $t = $txtAdd.Text.Trim()
    if (-not $t) { return }
    $e = ConvertTo-RepoEntry $t
    if (-not $e) { [void][System.Windows.Forms.MessageBox]::Show('That does not look like a GitHub or GitLab repo URL (or GitHub owner/repo).', 'Cannot add'); return }
    if (@(Get-Repos | Where-Object { $_.Key -eq $e.Key }).Count) {
        [void][System.Windows.Forms.MessageBox]::Show("$($e.Owner)/$($e.Name) is already in the list.", 'Already added'); return
    }
    Add-RepoLine $e
    $txtAdd.Clear()
    Load-List
    Write-Log "Added $($e.Owner)/$($e.Name)"
    Invoke-Check @($lv.Items[$lv.Items.Count - 1])
})
$txtAdd.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; $btnAdd.PerformClick() }
})

$btnRemove.Add_Click({
    $sel = @($lv.SelectedItems)
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Select the repo(s) to remove first.', 'Nothing selected'); return }
    $names = ($sel | ForEach-Object { "$($_.Tag.Entry.Owner)/$($_.Tag.Entry.Name)" }) -join "`n"
    $ans = [System.Windows.Forms.MessageBox]::Show("Remove from the list?`n`n$names`n`n(Already downloaded files are NOT deleted.)", 'Confirm remove', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    foreach ($item in $sel) {
        Remove-RepoLine $item.Tag.Entry.Key
        Write-Log "Removed $($item.Tag.Entry.Owner)/$($item.Tag.Entry.Name)"
        $lv.Items.Remove($item)
    }
    for ($i = 0; $i -lt $lv.Items.Count; $i++) { $lv.Items[$i].SubItems[0].Text = ($i + 1).ToString() }
    Update-Summary
})

$btnEdit.Add_Click({
    $exe = if ($script:Editor -and (Test-Path -LiteralPath $script:Editor)) { $script:Editor } else { 'notepad.exe' }
    Start-Process $exe -ArgumentList "`"$ReposFile`""
    Write-Log 'After saving repos.txt, click "Check for updates" to reload the list.'
})

$btnBrowse.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Choose the folder that will hold one sub-folder per repo'
    if (Test-Path -LiteralPath $txtFolder.Text) { $d.SelectedPath = $txtFolder.Text }
    if ($d.ShowDialog() -eq 'OK') { $txtFolder.Text = $d.SelectedPath; Save-Settings }
})
$btnOpen.Add_Click({
    $p = $txtFolder.Text.Trim()
    if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p -Force) }
    Start-Process explorer.exe -ArgumentList "`"$p`""
})

$lv.Add_DoubleClick({
    if ($lv.SelectedItems.Count -eq 1) {
        $e = $lv.SelectedItems[0].Tag.Entry
        Start-Process (Get-RepoUrl $e)
    }
})

$form.Add_FormClosing({
    Save-Settings
    if ($script:Busy) { $script:Cancel = $true }
})

$form.Add_HandleCreated({ Set-NativeTheme })

# buttons re-style themselves when enabled/disabled (e.g. Cancel while downloading)
foreach ($b in @($btnCheck, $btnCheckSel, $btnAll, $btnSel, $btnCancel, $btnAdd, $btnRemove, $btnEdit, $btnBrowse, $btnOpen)) {
    $b.Add_EnabledChanged({ Set-ButtonLook $args[0] })
}

$chkDark.Add_CheckedChanged({
    $script:Settings.Dark = [bool]$chkDark.Checked
    Set-Theme
    foreach ($it in $lv.Items) { Update-Item $it }
    Save-Settings
})

$form.Add_Shown({
    Set-NativeTheme
    Resize-LastColumn
    Write-Log "Repo list: $ReposFile"
    Write-Log "Diagnostic log: $LogFile"
    Load-List
    Update-Summary
    Write-Log 'Ready - click "Check for updates" to look for new releases.'
})

[void]$form.ShowDialog()
