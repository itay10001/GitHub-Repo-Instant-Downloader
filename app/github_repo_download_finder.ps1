param(
    [string]$Repo,
    [switch]$Versions,
    [switch]$Notes,
    [switch]$DownloadLatest,
    [switch]$BestUrl,
    [switch]$NoMenu,
    [switch]$Help,
    [int]$Limit = 30,
    [string]$OutputDir = "downloads"
)

$ErrorActionPreference = "Stop"
$ApiRoot = "https://api.github.com"
$UserAgent = "github-repo-download-finder/1.0"
$ChangelogCandidates = @(
    "CHANGELOG.md",
    "CHANGELOG",
    "CHANGES.md",
    "HISTORY.md",
    "RELEASES.md",
    "docs/CHANGELOG.md"
)
$InstallScriptCandidates = @(
    "install.ps1",
    "setup.ps1",
    "install.bat",
    "setup.bat",
    "install.cmd",
    "setup.cmd"
)

function Show-Help {
    @"
GitHub Repo Download Finder

Usage:
  .\github_repo_download_finder.ps1 [repo-url-or-owner/repo] [options]

Options:
  -Versions          Show releases/tags you can download.
  -Notes             Show the latest release notes or changelog.
  -DownloadLatest    Download the recommended latest file.
  -BestUrl           Print only the best latest download URL and exit.
  -NoMenu            Show the summary/latest links without the interactive menu.
  -Limit 30          Maximum releases/tags to scan, up to 100.
  -OutputDir path    Folder for downloaded files.
  -Help              Show this help.

Examples:
  .\github_repo_download_finder.ps1 https://github.com/psf/requests
  .\github_repo_download_finder.ps1 owner/repo -BestUrl
  .\github_repo_download_finder.ps1 owner/repo -Versions
  .\github_repo_download_finder.ps1 owner/repo -DownloadLatest -OutputDir "$env:USERPROFILE\Downloads"

Set GITHUB_TOKEN first for private repos or higher rate limits:
  `$env:GITHUB_TOKEN = "your_token_here"
"@ | Write-Host
}

function New-GitHubHeaders([string]$Accept = "application/vnd.github+json") {
    $headers = @{
        "Accept" = $Accept
        "User-Agent" = $UserAgent
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($env:GITHUB_TOKEN) {
        $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
    }
    return $headers
}

function Get-ErrorMessageFromResponse($ErrorRecord) {
    $message = $ErrorRecord.Exception.Message
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $message = $ErrorRecord.ErrorDetails.Message
    }

    try {
        $parsed = $message | ConvertFrom-Json
        if ($parsed.message) {
            return $parsed.message
        }
    }
    catch {
    }

    return $message
}

function Invoke-GitHubJson([string]$PathOrUrl, [switch]$Allow404) {
    if ($PathOrUrl -match "^https?://") {
        $url = $PathOrUrl
    }
    else {
        $url = "$ApiRoot$PathOrUrl"
    }

    try {
        return Invoke-RestMethod -Uri $url -Headers (New-GitHubHeaders) -TimeoutSec 25
    }
    catch {
        $status = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($Allow404 -and $status -eq 404) {
            return $null
        }

        $message = Get-ErrorMessageFromResponse $_
        if ($status -eq 403 -and $message.ToLowerInvariant().Contains("rate limit") -and -not $env:GITHUB_TOKEN) {
            $message = "$message Set a GITHUB_TOKEN environment variable to raise the limit."
        }
        if ($status) {
            throw "GitHub request failed ($status): $message"
        }
        throw "GitHub request failed: $message"
    }
}

function Clean-RepoName([string]$Name) {
    $result = $Name.Trim()
    if ($result.EndsWith(".git")) {
        $result = $result.Substring(0, $result.Length - 4)
    }
    return $result
}

function Parse-RepoInput([string]$Value) {
    $raw = $Value.Trim()
    if (-not $raw) {
        throw "Please enter a GitHub repository URL or owner/repo."
    }
    if ($raw -match "^github\.com/") {
        $raw = "https://$raw"
    }
    if ($raw -match "^www\.github\.com/") {
        $raw = "https://$raw"
    }

    if ($raw -match "^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:\.git)?$") {
        $owner = $Matches[1]
        $repoName = Clean-RepoName $Matches[2]
        return [pscustomobject]@{ Owner = $owner; Repo = $repoName; FullName = "$owner/$repoName" }
    }

    if ($raw -match "^(?:git@|ssh://git@)github\.com[:/]([^/]+)/(.+?)(?:\.git)?/?$") {
        $owner = $Matches[1]
        $repoName = Clean-RepoName (($Matches[2] -split "/")[0])
        return [pscustomobject]@{ Owner = $owner; Repo = $repoName; FullName = "$owner/$repoName" }
    }

    try {
        $uri = [Uri]$raw
    }
    catch {
        throw "That does not look like a valid GitHub repository URL."
    }

    $hostName = $uri.Host.ToLowerInvariant()
    if ($hostName -ne "github.com" -and $hostName -ne "www.github.com") {
        throw "That does not look like a github.com repository URL."
    }

    $parts = @($uri.AbsolutePath.Trim("/") -split "/" | Where-Object { $_ })
    if ($parts.Count -lt 2) {
        throw "That GitHub URL does not include both an owner and repo name."
    }

    $owner = $parts[0]
    $repoName = Clean-RepoName $parts[1]
    return [pscustomobject]@{ Owner = $owner; Repo = $repoName; FullName = "$owner/$repoName" }
}

function Encode-PathPart([string]$Value) {
    return (($Value -split "/") | ForEach-Object { [Uri]::EscapeDataString($_) }) -join "/"
}

function Scan-Repo($RepoRef, [int]$MaxItems) {
    $info = Invoke-GitHubJson "/repos/$($RepoRef.Owner)/$($RepoRef.Repo)"
    $latest = Invoke-GitHubJson "/repos/$($RepoRef.Owner)/$($RepoRef.Repo)/releases/latest" -Allow404
    $perPage = [Math]::Min($MaxItems, 100)
    $installScript = $null
    if ($info.default_branch) {
        $installScript = Find-InstallScript $RepoRef $info.default_branch
    }

    $releaseData = Invoke-GitHubJson "/repos/$($RepoRef.Owner)/$($RepoRef.Repo)/releases?per_page=$perPage"
    $releases = @()
    if ($null -ne $releaseData) {
        $releases = @($releaseData)
    }

    if ($null -eq $latest -and $releases.Count -gt 0) {
        $latest = $releases[0]
    }

    $tagData = Invoke-GitHubJson "/repos/$($RepoRef.Owner)/$($RepoRef.Repo)/tags?per_page=$perPage"
    $tags = @()
    if ($null -ne $tagData) {
        $tags = @($tagData)
    }

    return [pscustomobject]@{
        Repo = $RepoRef
        Info = $info
        LatestRelease = $latest
        Releases = $releases
        Tags = $tags
        InstallScript = $installScript
    }
}

function Format-Bytes($Value) {
    if ($null -eq $Value) {
        return ""
    }
    $amount = [double]$Value
    foreach ($unit in @("B", "KB", "MB", "GB")) {
        if ($amount -lt 1024 -or $unit -eq "GB") {
            if ($unit -eq "B") {
                return "$([int]$amount) B"
            }
            return "{0:N1} $unit" -f $amount
        }
        $amount = $amount / 1024
    }
    return ""
}

function Get-AssetTraits([string]$Filename, [bool]$IsSource) {
    $name = if ($Filename) { $Filename.ToLowerInvariant() } else { "" }

    if ($IsSource -or $name -match "(^|[-_.\s])source[-_.\s]?code([-_.\s]|$)") {
        return [pscustomobject]@{
            Description = "Source code - developers only"
            Platform = "Source code"
            Architecture = ""
            Kind = "source"
            IsSource = $true
            IsBinary = $false
            IsSupportingFile = $false
            DeveloperOnly = $true
        }
    }

    $platform = ""
    if ($name -match "(windows|win32|win64|win-|_win|\.win|mingw|msvc)") {
        $platform = "Windows"
    }
    elseif ($name -match "(macos|darwin|osx|apple-darwin)") {
        $platform = "macOS"
    }
    elseif ($name -match "(linux|ubuntu|debian|fedora|rhel|appimage)") {
        $platform = "Linux"
    }
    elseif ($name -match "(android|apk)") {
        $platform = "Android"
    }

    $architecture = ""
    if ($name -match "(arm64|aarch64)") {
        $architecture = "ARM64"
    }
    elseif ($name -match "(x64|x86_64|amd64)") {
        $architecture = "64-bit"
    }
    elseif ($name -match "(^|[-_.])x86([-_.]|$)|(^|[-_.])386([-_.]|$)|i386|i686") {
        $architecture = "32-bit"
    }

    $kind = "download"
    $supportingFile = $false
    if ($name -match "(sha256|sha512|checksums?|checksum|signature|sbom|symbols|debug)|\.(sig|asc|sha256|sha512)$") {
        $kind = "support file"
        $supportingFile = $true
    }
    elseif ($name -match "\.(msi|msix|appinstaller)$" -or $name -match "(setup|installer)") {
        $kind = "installer"
    }
    elseif ($name -match "\.exe$") {
        $kind = "app executable"
    }
    elseif ($name -match "(portable|standalone)") {
        $kind = "portable version"
    }
    elseif ($name -match "\.(zip|7z|tar\.gz|tgz)$") {
        $kind = "portable/archive"
    }
    elseif ($name -match "\.(dmg|pkg)$") {
        $kind = "installer"
    }
    elseif ($name -match "\.(deb|rpm|appimage)$") {
        $kind = "package"
    }

    if ($supportingFile) {
        $description = "Support file"
    }
    else {
        $parts = @()
        if ($platform) {
            $parts += $platform
        }
        if ($architecture) {
            $parts += $architecture
        }
        if ($kind) {
            $parts += $kind
        }

        $description = ($parts -join " ").Trim()
        if (-not $description) {
            $description = "Download asset"
        }
    }

    return [pscustomobject]@{
        Description = $description
        Platform = $platform
        Architecture = $architecture
        Kind = $kind
        IsSource = $false
        IsBinary = -not $supportingFile
        IsSupportingFile = $supportingFile
        DeveloperOnly = $false
    }
}

function New-DownloadOption([string]$Label, [string]$Url, [string]$Filename, $Traits) {
    return [pscustomobject]@{
        Label = $Label
        Url = $Url
        Filename = $Filename
        Platform = $Traits.Platform
        Architecture = $Traits.Architecture
        Kind = $Traits.Kind
        IsSource = $Traits.IsSource
        IsBinary = $Traits.IsBinary
        IsSupportingFile = $Traits.IsSupportingFile
        DeveloperOnly = $Traits.DeveloperOnly
        IsInstallableProject = if ($Traits.PSObject.Properties.Name -contains "IsInstallableProject") { $Traits.IsInstallableProject } else { $false }
    }
}

function New-AssetDownloadOption($Asset) {
    $traits = Get-AssetTraits $Asset.name $false
    $label = $traits.Description
    if ($Asset.name) {
        $label = "$label - $($Asset.name)"
    }

    $size = Format-Bytes $Asset.size
    if ($size) {
        $label = "$label ($size)"
    }

    return New-DownloadOption $label $Asset.browser_download_url $Asset.name $traits
}

function New-SourceDownloadOption([string]$Kind, [string]$Url, [string]$Filename) {
    $traits = Get-AssetTraits $Filename $true
    $label = "Source code $Kind - developers only"
    return New-DownloadOption $label $Url $Filename $traits
}

function New-InstallableProjectDownloadOption([string]$Kind, [string]$Url, [string]$Filename, [string]$InstallScript) {
    $traits = [pscustomobject]@{
        Platform = "Windows"
        Architecture = ""
        Kind = "installable project archive"
        IsSource = $false
        IsBinary = $true
        IsSupportingFile = $false
        DeveloperOnly = $false
        IsInstallableProject = $true
    }
    $label = "Installable project $Kind - includes $InstallScript"
    return New-DownloadOption $label $Url $Filename $traits
}

function Release-Label($Release) {
    $tag = if ($Release.tag_name) { $Release.tag_name } else { "unknown tag" }
    $name = if ($Release.name) { $Release.name } else { "" }
    $date = if ($Release.published_at) { "$($Release.published_at)".Substring(0, 10) } elseif ($Release.created_at) { "$($Release.created_at)".Substring(0, 10) } else { "unknown date" }

    $markers = @()
    if ($Release.prerelease) { $markers += "pre-release" }
    if ($Release.draft) { $markers += "draft" }

    $title = if ($name -and $name -ne $tag) { "$tag - $name" } else { $tag }
    $suffix = if ($markers.Count -gt 0) { " ($($markers -join ', '))" } else { "" }
    return "$title [$date]$suffix"
}

function Get-BranchArchiveUrl($RepoRef, [string]$Branch, [string]$Extension) {
    $encoded = [Uri]::EscapeUriString($Branch)
    return "https://github.com/$($RepoRef.Owner)/$($RepoRef.Repo)/archive/refs/heads/$encoded.$Extension"
}

function Get-BranchApiArchiveUrl($RepoRef, [string]$Branch, [string]$Kind) {
    $encoded = [Uri]::EscapeDataString($Branch)
    return "$ApiRoot/repos/$($RepoRef.Owner)/$($RepoRef.Repo)/$Kind/$encoded"
}

function Get-ReleaseDownloadOptions($RepoRef, $Release, [string]$InstallScript = "") {
    $options = @()
    foreach ($asset in @($Release.assets)) {
        if ($asset.browser_download_url) {
            $options += New-AssetDownloadOption $asset
        }
    }

    $tag = if ($Release.tag_name) { $Release.tag_name } else { "source" }
    if ($Release.zipball_url) {
        if ($InstallScript) {
            $options += New-InstallableProjectDownloadOption "ZIP" $Release.zipball_url "$($RepoRef.Repo)-$tag.zip" $InstallScript
        }
        else {
            $options += New-SourceDownloadOption "ZIP" $Release.zipball_url "$($RepoRef.Repo)-$tag.zip"
        }
    }
    if ($Release.tarball_url) {
        $options += New-SourceDownloadOption "TAR.GZ" $Release.tarball_url "$($RepoRef.Repo)-$tag.tar.gz"
    }
    return @($options)
}

function Get-TagDownloadOptions($RepoRef, $Tag, [string]$InstallScript = "") {
    $name = if ($Tag.name) { $Tag.name } else { "tag" }
    $options = @()
    if ($Tag.zipball_url) {
        if ($InstallScript) {
            $options += New-InstallableProjectDownloadOption "ZIP" $Tag.zipball_url "$($RepoRef.Repo)-$name.zip" $InstallScript
        }
        else {
            $options += New-SourceDownloadOption "ZIP" $Tag.zipball_url "$($RepoRef.Repo)-$name.zip"
        }
    }
    if ($Tag.tarball_url) {
        $options += New-SourceDownloadOption "TAR.GZ" $Tag.tarball_url "$($RepoRef.Repo)-$name.tar.gz"
    }
    return @($options)
}

function Get-BranchDownloadOptions($RepoRef, [string]$Branch, [string]$InstallScript = "") {
    $zipUrl = Get-BranchApiArchiveUrl $RepoRef $Branch "zipball"
    $zipFilename = "$($RepoRef.Repo)-$Branch.zip"
    $zipOption = if ($InstallScript) {
        New-InstallableProjectDownloadOption "ZIP" $zipUrl $zipFilename $InstallScript
    }
    else {
        New-SourceDownloadOption "ZIP" $zipUrl $zipFilename
    }

    return @(
        $zipOption,
        (New-SourceDownloadOption "TAR.GZ" (Get-BranchApiArchiveUrl $RepoRef $Branch "tarball") "$($RepoRef.Repo)-$Branch.tar.gz")
    )
}

function Write-DownloadOptions($Options) {
    $items = @($Options)
    if ($items.Count -eq 0) {
        Write-Host "  No downloadable options found."
        return
    }

    $binaries = @($items | Where-Object { $_.IsBinary -and -not $_.IsSource -and -not $_.IsSupportingFile })
    if ($binaries.Count -eq 0) {
        Write-Host "  Warning: no app binaries were found; these links are source/support files." -ForegroundColor Yellow
    }

    $recommended = Select-RecommendedDownloadOption $items
    foreach ($option in $items) {
        $label = Format-DownloadOptionLabel $option $recommended
        Write-Host "  $label`: $($option.Url)"
    }
}

function Write-Summary($Scan) {
    $info = $Scan.Info
    Write-Host ""
    Write-Host "Repository: $($info.full_name)"
    if ($info.description) {
        Write-Host "About:      $($info.description)"
    }
    Write-Host "URL:        $($info.html_url)"
    Write-Host "Default:    $($info.default_branch)"
    Write-Host "Releases:   $($Scan.Releases.Count) found in this scan"
    Write-Host "Tags:       $($Scan.Tags.Count) found in this scan"

    if ($info.default_branch) {
        Write-Host "Branch ZIP: $(Get-BranchArchiveUrl $Scan.Repo $info.default_branch 'zip')"
    }

    if ($Scan.LatestRelease) {
        Write-Host ""
        Write-Host "Latest release: $(Release-Label $Scan.LatestRelease)"
        Write-Host "Release page:   $($Scan.LatestRelease.html_url)"
    }
    elseif ($Scan.Tags.Count -gt 0) {
        Write-Host ""
        Write-Host "No GitHub releases found. Newest tag: $($Scan.Tags[0].name)"
    }
    else {
        Write-Host ""
        Write-Host "No GitHub releases or tags found. Use the default branch ZIP link above."
    }
}

function Write-LatestDownloadLinks($Scan) {
    Write-Host ""
    if ($Scan.LatestRelease) {
        Write-Host "Download links for $(Release-Label $Scan.LatestRelease)"
        Write-DownloadOptions (Get-ReleaseDownloadOptions $Scan.Repo $Scan.LatestRelease $Scan.InstallScript)
        return
    }

    if ($Scan.Tags.Count -gt 0) {
        Write-Host "Download links for newest tag: $($Scan.Tags[0].name)"
        Write-DownloadOptions (Get-TagDownloadOptions $Scan.Repo $Scan.Tags[0] $Scan.InstallScript)
        return
    }

    if ($Scan.Info.default_branch) {
        Write-Host "Download link for the default branch"
        Write-DownloadOptions (Get-BranchDownloadOptions $Scan.Repo $Scan.Info.default_branch $Scan.InstallScript)
    }
}

function Format-DownloadOptionLabel($Option, $Recommended) {
    if ($null -ne $Recommended -and $Option.Url -eq $Recommended.Url) {
        return "Recommended: $($Option.Label)"
    }
    return $Option.Label
}

function Get-OptionScore($Option) {
    $name = if ($Option.Filename) { $Option.Filename.ToLowerInvariant() } else { "" }
    $label = if ($Option.Label) { $Option.Label.ToLowerInvariant() } else { "" }
    $score = 0

    if ($Option.IsBinary -and -not $Option.IsSource -and -not $Option.IsSupportingFile) {
        $score += 100
    }
    if ($Option.IsSupportingFile) {
        $score -= 160
    }
    if ($Option.IsSource) {
        $score -= 20
    }
    if ($Option.Platform -eq "Windows") {
        $score += 45
    }
    elseif ($Option.Platform -eq "macOS" -or $Option.Platform -eq "Linux") {
        $score -= 20
    }
    if ($Option.Architecture -eq "64-bit") {
        $score += 30
    }
    elseif ($Option.Architecture -eq "ARM64") {
        $score -= 15
    }
    if ($Option.Kind -eq "installer") {
        $score += 90
    }
    elseif ($Option.Kind -eq "app executable") {
        $score += 80
    }
    elseif ($Option.Kind -eq "portable version") {
        $score += 60
    }
    elseif ($Option.Kind -eq "portable/archive") {
        $score += 45
    }
    elseif ($Option.Kind -eq "installable project archive") {
        $score += 70
    }
    if ($name -match "(sha256|sha512|checksum|checksums|\.sig|\.asc|sbom|symbols|debug)") {
        $score -= 120
    }
    if ($label -match "source code zip") {
        $score += 20
    }
    if ($label -match "source code tar\.gz") {
        $score += 5
    }
    return $score
}

function Select-BestDownloadOption($Options) {
    $best = $null
    $bestScore = [int]::MinValue

    foreach ($option in @($Options)) {
        $score = Get-OptionScore $option
        if ($null -eq $best -or $score -gt $bestScore) {
            $best = $option
            $bestScore = $score
        }
    }
    return $best
}

function Select-RecommendedDownloadOption($Options) {
    $items = @($Options)
    if ($items.Count -eq 0) {
        return $null
    }

    $candidates = @($items | Where-Object { $_.IsBinary -and -not $_.IsSource -and -not $_.IsSupportingFile })
    if ($candidates.Count -eq 0) {
        $candidates = @($items | Where-Object { -not $_.IsSupportingFile })
    }
    if ($candidates.Count -eq 0) {
        $candidates = $items
    }

    return Select-BestDownloadOption $candidates
}

function Get-BestUrlOption($Scan) {
    if ($Scan.LatestRelease) {
        $option = Select-RecommendedDownloadOption (Get-ReleaseDownloadOptions $Scan.Repo $Scan.LatestRelease $Scan.InstallScript)
        if ($null -ne $option) {
            return $option
        }
    }

    if ($Scan.Tags.Count -gt 0) {
        $option = Select-RecommendedDownloadOption (Get-TagDownloadOptions $Scan.Repo $Scan.Tags[0] $Scan.InstallScript)
        if ($null -ne $option) {
            return $option
        }
    }

    if ($Scan.Info.default_branch) {
        return (Get-BranchDownloadOptions $Scan.Repo $Scan.Info.default_branch $Scan.InstallScript)[0]
    }
    return $null
}

function Write-BestUrl($Scan) {
    $option = Get-BestUrlOption $Scan
    if ($null -eq $option -or -not $option.Url) {
        throw "No latest release/tag/default-branch download option found."
    }
    Write-Host $option.Url
}

function Write-Versions($Scan, [int]$MaxItems) {
    Write-Host ""
    if ($Scan.Releases.Count -gt 0) {
        Write-Host "Releases / versions (showing up to $([Math]::Min($MaxItems, $Scan.Releases.Count)))"
        for ($i = 0; $i -lt [Math]::Min($MaxItems, $Scan.Releases.Count); $i++) {
            "{0,4}. {1}" -f ($i + 1), (Release-Label $Scan.Releases[$i]) | Write-Host
        }
    }
    else {
        Write-Host "No GitHub releases found."
    }

    Write-Host ""
    if ($Scan.Tags.Count -gt 0) {
        Write-Host "Tags (showing up to $([Math]::Min($MaxItems, $Scan.Tags.Count)))"
        for ($i = 0; $i -lt [Math]::Min($MaxItems, $Scan.Tags.Count); $i++) {
            "{0,4}. {1}" -f ($i + 1), $Scan.Tags[$i].name | Write-Host
        }
    }
    else {
        Write-Host "No tags found."
    }
}

function Get-FileText($RepoRef, [string]$Path, [string]$Ref) {
    $encodedPath = Encode-PathPart $Path
    $encodedRef = [Uri]::EscapeDataString($Ref)
    $item = Invoke-GitHubJson "/repos/$($RepoRef.Owner)/$($RepoRef.Repo)/contents/$encodedPath`?ref=$encodedRef" -Allow404
    if ($null -eq $item -or $item.type -ne "file") {
        return $null
    }

    if ($item.encoding -eq "base64" -and $item.content) {
        $clean = "$($item.content)" -replace "\s", ""
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clean))
    }
    return $null
}

function Find-Changelog($RepoRef, [string]$DefaultBranch) {
    foreach ($path in $ChangelogCandidates) {
        $text = Get-FileText $RepoRef $path $DefaultBranch
        if ($text) {
            return [pscustomobject]@{ Name = $path; Text = $text }
        }
    }
    return $null
}

function Find-InstallScript($RepoRef, [string]$DefaultBranch) {
    $encodedRef = [Uri]::EscapeDataString($DefaultBranch)
    $items = Invoke-GitHubJson "/repos/$($RepoRef.Owner)/$($RepoRef.Repo)/contents`?ref=$encodedRef" -Allow404
    if ($null -eq $items) {
        return $null
    }

    $candidates = @{}
    foreach ($path in $InstallScriptCandidates) {
        $candidates[$path.ToLowerInvariant()] = $path
    }

    foreach ($item in @($items)) {
        if ($item.type -ne "file" -or -not $item.name) {
            continue
        }

        $key = "$($item.name)".ToLowerInvariant()
        if ($candidates.ContainsKey($key)) {
            return $candidates[$key]
        }
    }
    return $null
}

function Normalize-Version([string]$Value) {
    return $Value.Trim().ToLowerInvariant().TrimStart("v")
}

function Strip-Markdown([string]$Value) {
    return [regex]::Replace($Value, "[*_'``\[\]()]|#+", "")
}

function Get-VersionTokens([string]$Text) {
    $matches = [regex]::Matches($Text, "v?\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?|v\d+(?:[-+][0-9A-Za-z.-]+)?")
    return @($matches | ForEach-Object { $_.Value })
}

function Extract-ChangelogSection([string]$Changelog, [string]$TagName) {
    if (-not $TagName) {
        return $null
    }

    $normalizedTag = Normalize-Version $TagName
    $lines = $Changelog -split "\r?\n"
    $startIndex = $null
    $startLevel = $null

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^(#{1,6})\s+(.+?)\s*$") {
            $level = $Matches[1].Length
            $heading = Strip-Markdown $Matches[2]
            foreach ($token in Get-VersionTokens $heading) {
                if ((Normalize-Version $token) -eq $normalizedTag) {
                    $startIndex = $i
                    $startLevel = $level
                    break
                }
            }
        }
        if ($null -ne $startIndex) {
            break
        }
    }

    if ($null -eq $startIndex) {
        return $null
    }

    $endIndex = $lines.Count
    for ($i = $startIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^(#{1,6})\s+" -and $Matches[1].Length -le $startLevel) {
            $endIndex = $i
            break
        }
    }

    return ($lines[$startIndex..($endIndex - 1)] -join [Environment]::NewLine).Trim()
}

function Get-CleanNotes($Value) {
    if ($null -eq $Value) {
        return $null
    }
    $text = "$Value".Trim()
    if ($text) {
        return $text
    }
    return $null
}

function Write-NoteBlock([string]$Notes, [int]$MaxLines = 90, [int]$MaxChars = 8000) {
    $text = $Notes.Trim()
    if (-not $text) {
        Write-Host "No notes were published for the latest release."
        return
    }

    $lines = @($text -split "\r?\n")
    $truncated = $false
    if ($lines.Count -gt $MaxLines) {
        $lines = $lines[0..($MaxLines - 1)]
        $truncated = $true
    }

    $block = $lines -join [Environment]::NewLine
    if ($block.Length -gt $MaxChars) {
        $block = $block.Substring(0, $MaxChars).TrimEnd()
        $truncated = $true
    }

    Write-Host ""
    foreach ($line in @($block -split "\r?\n")) {
        Write-Host "  $line"
    }
    if ($truncated) {
        Write-Host ""
        Write-Host "  ...truncated. Open the release page for the full notes."
    }
}

function Write-LatestNotes($Scan) {
    Write-Host ""
    if ($Scan.LatestRelease) {
        $body = Get-CleanNotes $Scan.LatestRelease.body
        if ($body) {
            Write-Host "What's new in $($Scan.LatestRelease.tag_name) (from GitHub release notes)"
            Write-NoteBlock $body
            return
        }
    }

    if (-not $Scan.Info.default_branch) {
        Write-Host "No release notes found, and the repo default branch is unknown."
        return
    }

    $changelog = Find-Changelog $Scan.Repo $Scan.Info.default_branch
    if ($null -eq $changelog) {
        Write-Host "No release notes or common changelog/update-log file found."
        return
    }

    $tagName = if ($Scan.LatestRelease) { $Scan.LatestRelease.tag_name } else { $null }
    $section = if ($tagName) { Extract-ChangelogSection $changelog.Text $tagName } else { $null }
    Write-Host "What's new (from $($changelog.Name))"
    if ($section) {
        Write-NoteBlock $section
    }
    else {
        Write-NoteBlock $changelog.Text
    }
}

function Sanitize-Filename([string]$Filename) {
    $result = [regex]::Replace($Filename, '[<>:"/\\|?*\x00-\x1f]', "_").Trim().Trim(".")
    if (-not $result) {
        return "download"
    }
    return $result
}

function Get-UniquePath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    $directory = [IO.Path]::GetDirectoryName($Path)
    $name = [IO.Path]::GetFileName($Path)
    if ($name.EndsWith(".tar.gz")) {
        $stem = $name.Substring(0, $name.Length - 7)
        $suffix = ".tar.gz"
    }
    else {
        $stem = [IO.Path]::GetFileNameWithoutExtension($name)
        $suffix = [IO.Path]::GetExtension($name)
    }

    for ($i = 2; $i -lt 1000; $i++) {
        $candidate = Join-Path $directory "$stem-$i$suffix"
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw "Could not choose a unique filename for $Path"
}

function Get-DownloadHeaders([string]$Url) {
    if ($Url -match "^https://api\.github\.com/repos/.+/(zipball|tarball)(/|$)") {
        return New-GitHubHeaders
    }
    return New-GitHubHeaders "application/octet-stream"
}

function Save-DownloadOption($Option, [string]$Folder) {
    $directory = New-Item -ItemType Directory -Path $Folder -Force
    $safeName = Sanitize-Filename $Option.Filename
    $target = Get-UniquePath (Join-Path $directory.FullName $safeName)
    Invoke-WebRequest -Uri $Option.Url -Headers (Get-DownloadHeaders $Option.Url) -OutFile $target -TimeoutSec 120
    return (Resolve-Path -LiteralPath $target).Path
}

function Choose-ReleaseOrTag($Scan, [int]$MaxItems) {
    $choices = @()
    foreach ($release in @($Scan.Releases | Select-Object -First $MaxItems)) {
        $choices += [pscustomobject]@{ Kind = "release"; Item = $release; Label = (Release-Label $release) }
    }
    if ($choices.Count -eq 0) {
        foreach ($tag in @($Scan.Tags | Select-Object -First $MaxItems)) {
            $choices += [pscustomobject]@{ Kind = "tag"; Item = $tag; Label = $tag.name }
        }
    }

    if ($choices.Count -eq 0) {
        Write-Host "No releases or tags are available to choose from."
        return $null
    }

    Write-Host ""
    for ($i = 0; $i -lt $choices.Count; $i++) {
        "{0,4}. {1}" -f ($i + 1), $choices[$i].Label | Write-Host
    }

    $answer = Read-Host "Pick a version number for links, or press Enter to go back"
    if (-not $answer.Trim()) {
        return $null
    }
    if ($answer -notmatch "^\d+$" -or [int]$answer -lt 1 -or [int]$answer -gt $choices.Count) {
        Write-Host "That selection is not in the list."
        return $null
    }
    return $choices[[int]$answer - 1]
}

function Get-OptionsForChoice($Scan, $Choice) {
    if ($Choice.Kind -eq "release") {
        return Get-ReleaseDownloadOptions $Scan.Repo $Choice.Item $Scan.InstallScript
    }
    return Get-TagDownloadOptions $Scan.Repo $Choice.Item $Scan.InstallScript
}

function Choose-DownloadOption($Options) {
    $items = @($Options)
    if ($items.Count -eq 0) {
        Write-Host "No downloadable options found."
        return $null
    }

    $recommended = Select-RecommendedDownloadOption $items
    Write-Host ""
    $binaries = @($items | Where-Object { $_.IsBinary -and -not $_.IsSource -and -not $_.IsSupportingFile })
    if ($binaries.Count -eq 0) {
        Write-Host "Warning: no app binaries were found; these links are source/support files." -ForegroundColor Yellow
    }
    for ($i = 0; $i -lt $items.Count; $i++) {
        "{0,4}. {1}" -f ($i + 1), (Format-DownloadOptionLabel $items[$i] $recommended) | Write-Host
        Write-Host "      $($items[$i].Url)"
    }
    $answer = Read-Host "Pick a download number, or press Enter to go back"
    if (-not $answer.Trim()) {
        return $null
    }
    if ($answer -notmatch "^\d+$" -or [int]$answer -lt 1 -or [int]$answer -gt $items.Count) {
        Write-Host "That selection is not in the list."
        return $null
    }
    return $items[[int]$answer - 1]
}

function Get-LatestDownloadOption($Scan) {
    if ($Scan.LatestRelease) {
        $options = @(Get-ReleaseDownloadOptions $Scan.Repo $Scan.LatestRelease $Scan.InstallScript)
        $recommended = Select-RecommendedDownloadOption $options
        if ($null -ne $recommended) {
            return $recommended
        }
    }

    if ($Scan.Tags.Count -gt 0) {
        $options = @(Get-TagDownloadOptions $Scan.Repo $Scan.Tags[0] $Scan.InstallScript)
        $recommended = Select-RecommendedDownloadOption $options
        if ($null -ne $recommended) {
            return $recommended
        }
    }

    if ($Scan.Info.default_branch) {
        return (Get-BranchDownloadOptions $Scan.Repo $Scan.Info.default_branch $Scan.InstallScript)[0]
    }
    return $null
}

function Start-InteractiveMenu($Scan) {
    while ($true) {
        Write-Host ""
        Write-Host "Choose an action"
        Write-Host "  1. Show latest release notes / changelog"
        Write-Host "  2. Show versions you can download"
        Write-Host "  3. Show latest download links"
        Write-Host "  4. Download a release/tag now"
        Write-Host "  5. Enter another repo"
        Write-Host "  q. Quit"
        $choice = (Read-Host ">").Trim().ToLowerInvariant()

        switch ($choice) {
            "1" { Write-LatestNotes $Scan }
            "2" {
                Write-Versions $Scan $Limit
                $selected = Choose-ReleaseOrTag $Scan $Limit
                if ($selected) {
                    Write-DownloadOptions (Get-OptionsForChoice $Scan $selected)
                }
            }
            "3" { Write-LatestDownloadLinks $Scan }
            "4" {
                $selected = Choose-ReleaseOrTag $Scan $Limit
                if ($selected) {
                    $option = Choose-DownloadOption (Get-OptionsForChoice $Scan $selected)
                }
                elseif ($Scan.Info.default_branch -and $Scan.Releases.Count -eq 0 -and $Scan.Tags.Count -eq 0) {
                    $option = Choose-DownloadOption (Get-BranchDownloadOptions $Scan.Repo $Scan.Info.default_branch $Scan.InstallScript)
                }
                else {
                    $option = $null
                }

                if ($option) {
                    $saved = Save-DownloadOption $option $OutputDir
                    Write-Host "Downloaded to: $saved"
                }
            }
            "5" { return "again" }
            "q" { return "quit" }
            "quit" { return "quit" }
            "exit" { return "quit" }
            default { Write-Host "Choose 1, 2, 3, 4, 5, or q." }
        }
    }
}

function Invoke-RunOnce([string]$RepoText) {
    $repoRef = Parse-RepoInput $RepoText
    if ($BestUrl) {
        $scan = Scan-Repo $repoRef $Limit
        Write-BestUrl $scan
        return "done"
    }

    Write-Host "Scanning $($repoRef.FullName)..."
    $scan = Scan-Repo $repoRef $Limit
    Write-Summary $scan

    $actionMode = $NoMenu -or $Versions -or $Notes -or $DownloadLatest -or $BestUrl
    if ($Versions) {
        Write-Versions $scan $Limit
    }
    if ($Notes) {
        Write-LatestNotes $scan
    }
    if ($NoMenu) {
        Write-LatestDownloadLinks $scan
    }
    if ($DownloadLatest) {
        $option = Get-LatestDownloadOption $scan
        if ($null -eq $option) {
            Write-Host "No latest release/tag/default-branch download option found."
        }
        else {
            $saved = Save-DownloadOption $option $OutputDir
            Write-Host "Downloaded to: $saved"
        }
    }

    if ($actionMode) {
        return "done"
    }
    return Start-InteractiveMenu $scan
}

try {
    if ($Help) {
        Show-Help
        exit 0
    }
    if ($Limit -lt 1) {
        throw "-Limit must be at least 1."
    }
    $Limit = [Math]::Min($Limit, 100)

    if ($Repo) {
        $result = Invoke-RunOnce $Repo
        if ($result -ne "again") {
            exit 0
        }
    }

    Write-Host "GitHub Repo Download Finder"
    Write-Host "Paste a GitHub repo URL, SSH URL, or owner/repo. Press Enter on an empty line to quit."

    while ($true) {
        $repoText = Read-Host "`nRepo URL"
        if (-not $repoText.Trim()) {
            exit 0
        }
        $result = Invoke-RunOnce $repoText
        if ($result -eq "quit") {
            exit 0
        }
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
