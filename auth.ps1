param(
    [string]$ConfigDir = (Join-Path $env:LOCALAPPDATA "GitHubRepoDownloadFinder"),
    [switch]$Clear
)

$ErrorActionPreference = "Stop"
$TokenFile = Join-Path $ConfigDir "github_token.securestring"

function Convert-SecureStringToPlainText([securestring]$SecureString) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Normalize-GitHubToken([string]$Token) {
    if (-not $Token) {
        return $null
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($char in $Token.ToCharArray()) {
        if (-not [char]::IsControl($char) -and -not [char]::IsWhiteSpace($char)) {
            [void]$builder.Append($char)
        }
    }

    $clean = $builder.ToString().Trim()
    if ($clean) {
        return $clean
    }
    return $null
}

if ($Clear) {
    if (Test-Path -LiteralPath $TokenFile) {
        Remove-Item -LiteralPath $TokenFile -Force
        Write-Host "Removed saved GitHub token."
    }
    else {
        Write-Host "No saved GitHub token was found."
    }
    exit 0
}

Write-Host "GitHub authentication setup"
Write-Host ""
Write-Host "Paste a GitHub token when prompted. It will be encrypted for this Windows user"
Write-Host "and saved here:"
Write-Host $TokenFile
Write-Host ""
Write-Host "Use the least permissions possible. Public repo/rate-limit use does not"
Write-Host "need write access. Private repos need read-only access to the repos you want."
Write-Host ""

$secureToken = Read-Host "GitHub token" -AsSecureString
$plainToken = Convert-SecureStringToPlainText $secureToken
$cleanToken = Normalize-GitHubToken $plainToken
if (-not $cleanToken) {
    throw "Token cannot be empty."
}
$secureToken = ConvertTo-SecureString $cleanToken -AsPlainText -Force

New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
$secureToken | ConvertFrom-SecureString | Set-Content -LiteralPath $TokenFile -Encoding ASCII

Write-Host ""
Write-Host "Saved GitHub token for this Windows user."
Write-Host "Future scans will use authenticated GitHub API requests automatically."
