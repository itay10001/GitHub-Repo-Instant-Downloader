#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

AppTitle := "GitHub Repo Download Finder"
ConfigPath := A_ScriptDir "\github_repo_download_finder_hotkey.ini"
DownloadHotkey := ReadConfiguredHotkey()

SetupTrayMenu()

try {
    Hotkey DownloadHotkey, OpenGitHubDownloadPicker
} catch as err {
    MsgBox "The configured hotkey is invalid:`n" DownloadHotkey "`n`nFalling back to Ctrl+Alt+G.`n`n" err.Message, AppTitle
    DownloadHotkey := "^!g"
    Hotkey DownloadHotkey, OpenGitHubDownloadPicker
}

SetupTrayMenu() {
    global AppTitle

    A_TrayMenu.Delete()
    A_TrayMenu.Add("Open downloader", OpenDownloaderPrompt)
    A_TrayMenu.Add("Reload", (*) => Reload())
    A_TrayMenu.Add("Exit", (*) => ExitApp())
}

ReadConfiguredHotkey() {
    global ConfigPath

    try {
        value := Trim(IniRead(ConfigPath, "Settings", "Hotkey", "^!g"))
    } catch {
        value := "^!g"
    }

    return value != "" ? value : "^!g"
}

OpenDownloaderPrompt(*) {
    global AppTitle

    launcherPath := GetGitHubDownloaderLauncher()
    if launcherPath = "" {
        MsgBox "GitHub Repo Downloader launcher was not found.", AppTitle
        return
    }

    try {
        Run QuoteArg(launcherPath)
    } catch as err {
        MsgBox "Could not open the GitHub Repo Downloader.`n`n" err.Message, AppTitle
    }
}

OpenGitHubDownloadPicker(*) {
    global AppTitle

    source := FindGitHubRepoUrlForDownload()
    if source.Url = "" {
        MsgBox "I did not find a GitHub repo URL in the clipboard or selected text.`n`nClipboard:`n" ShortenForMessage(source.ClipboardText, 240), AppTitle
        return
    }

    launcherPath := GetGitHubDownloaderLauncher()
    if launcherPath = "" {
        MsgBox "GitHub Repo Downloader launcher was not found.", AppTitle
        return
    }

    try {
        Run QuoteArg(launcherPath) " " QuoteArg(source.Url)
        ToolTip "Opened GitHub version picker from " source.SourceLabel
        SetTimer ClearToolTip, -1800
    } catch as err {
        MsgBox "Could not open the GitHub Repo Downloader.`n`n" err.Message, AppTitle
    }
}

GetGitHubDownloaderLauncher() {
    candidates := [
        A_ScriptDir "\..\..\GitHub Repo Downloader.bat",
        A_ScriptDir "\..\GitHub Repo Downloader.bat",
        A_ScriptDir "\GitHub Repo Downloader.bat"
    ]

    for candidate in candidates {
        if FileExist(candidate) {
            return candidate
        }
    }

    return ""
}

FindGitHubRepoUrlForDownload() {
    clipboardText := Trim(A_Clipboard)
    repoUrl := ExtractGitHubRepoUrl(clipboardText)

    if repoUrl != "" {
        return { Url: repoUrl, SourceLabel: "clipboard", ClipboardText: clipboardText, SelectedText: "" }
    }

    selectedText := ReadSelectedTextWithoutKeepingClipboard()
    repoUrl := ExtractGitHubRepoUrl(selectedText)

    if repoUrl != "" {
        return { Url: repoUrl, SourceLabel: "selected text", ClipboardText: clipboardText, SelectedText: selectedText }
    }

    return { Url: "", SourceLabel: "", ClipboardText: clipboardText, SelectedText: selectedText }
}

ReadSelectedTextWithoutKeepingClipboard() {
    clipSaved := ClipboardAll()
    selectedText := ""

    try {
        A_Clipboard := ""
        Send "^c"

        if ClipWait(0.6) {
            selectedText := A_Clipboard
        }
    } finally {
        Sleep 50
        A_Clipboard := clipSaved
    }

    return Trim(selectedText)
}

ExtractGitHubRepoUrl(text) {
    text := Trim(text)

    if RegExMatch(text, "i)^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?)$", &match) {
        return TrimGithubRepoUrl(match[1])
    }
    if RegExMatch(text, "i)(https?://(?:www\.)?github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?)", &match) {
        return TrimGithubRepoUrl(match[1])
    }
    if RegExMatch(text, "i)(?:^|\s)(github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?)", &match) {
        return "https://" TrimGithubRepoUrl(match[1])
    }
    if RegExMatch(text, "i)(git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?)", &match) {
        return TrimGithubRepoUrl(match[1])
    }
    return ""
}

TrimGithubRepoUrl(url) {
    return RTrim(url, ".,;:)]}")
}

ShortenForMessage(text, limit) {
    text := Trim(text)
    text := StrReplace(text, "`r", " ")
    text := StrReplace(text, "`n", " ")

    if StrLen(text) <= limit {
        return text
    }
    return SubStr(text, 1, limit - 3) "..."
}

ClearToolTip(*) {
    ToolTip
}

QuoteArg(text) {
    return '"' StrReplace(text, '"', '\"') '"'
}
