# Installs the base image's tools (agents/base/Dockerfile.windows runs this; versions come from
# its ARGs). Node, ripgrep and jq are checked against the checksum list their release publishes;
# PortableGit and Python publish none in a usable form, so the Dockerfile pins those hashes.
param(
    [Parameter(Mandatory)] [string] $Node,
    [Parameter(Mandatory)] [string] $GitTag,      # v2.56.0.windows.4 (the .windows.1 release has no suffix in its file name)
    [Parameter(Mandatory)] [string] $GitSha256,
    [Parameter(Mandatory)] [string] $Python,
    [Parameter(Mandatory)] [string] $PythonSha256,
    [Parameter(Mandatory)] [string] $Ripgrep,
    [Parameter(Mandatory)] [string] $Jq
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Release assets come back as bytes (octet-stream), the node list as text.
function Get-Text($url) {
    $c = (Invoke-WebRequest -UseBasicParsing -Uri $url).Content
    if ($c -is [byte[]]) { [Text.Encoding]::UTF8.GetString($c) } else { $c }
}

# Downloads $url to $out and checks it against $sha, or against the first 64-hex word of the
# checksum file at $sumsUrl (the line for $name when the file lists several).
function Get-Verified($url, $out, $sha, $sumsUrl, $name) {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out
    if (-not $sha) {
        $lines = (Get-Text $sumsUrl) -split "`r?`n" | Where-Object { $_ -and (-not $name -or $_ -like "*$name*") }
        $m = [regex]::Match(($lines -join "`n"), '[0-9a-fA-F]{64}')
        if (-not $m.Success) { throw "no checksum for $name at $sumsUrl" }
        $sha = $m.Value
    }
    if ((Get-FileHash $out -Algorithm SHA256).Hash.ToLower() -ne $sha.ToLower()) { throw "checksum mismatch for $url" }
}

New-Item -ItemType Directory -Force C:\tools, C:\dl, C:\npm-global | Out-Null

$nodeZip = "node-v$Node-win-x64.zip"
Get-Verified "https://nodejs.org/dist/v$Node/$nodeZip" C:\dl\node.zip $null "https://nodejs.org/dist/v$Node/SHASUMS256.txt" $nodeZip
Expand-Archive C:\dl\node.zip C:\dl\node
Move-Item "C:\dl\node\node-v$Node-win-x64" C:\node

# v2.56.0.windows.4 -> PortableGit-2.56.0.4-64-bit; the first release of a version has no build suffix.
if ($GitTag -notmatch '^v(\d+\.\d+\.\d+)\.windows\.(\d+)$') { throw "unexpected git tag $GitTag" }
$gitV = if ($Matches[2] -eq '1') { $Matches[1] } else { "$($Matches[1]).$($Matches[2])" }
Get-Verified "https://github.com/git-for-windows/git/releases/download/$GitTag/PortableGit-$gitV-64-bit.7z.exe" C:\dl\git.exe $GitSha256
Start-Process C:\dl\git.exe -ArgumentList '-o', 'C:\git', '-y' -Wait -NoNewWindow
if (-not (Test-Path C:\git\bin\bash.exe)) { throw 'PortableGit extraction failed' }
# Git's own helper would prompt in a container; ours is set through the environment (Dockerfile.windows).
& C:\git\cmd\git.exe config --system --unset-all credential.helper
# Bind mounts have the host's owner.
& C:\git\cmd\git.exe config --system --add safe.directory '*'

# The embeddable Python has only python.exe; the scripts say python3.
Get-Verified "https://www.python.org/ftp/python/$Python/python-$Python-embed-amd64.zip" C:\dl\py.zip $PythonSha256
Expand-Archive C:\dl\py.zip C:\python
Copy-Item C:\python\python.exe C:\python\python3.exe

$rgDir = "ripgrep-$Ripgrep-x86_64-pc-windows-msvc"
Get-Verified "https://github.com/BurntSushi/ripgrep/releases/download/$Ripgrep/$rgDir.zip" C:\dl\rg.zip $null "https://github.com/BurntSushi/ripgrep/releases/download/$Ripgrep/$rgDir.zip.sha256"
Expand-Archive C:\dl\rg.zip C:\dl\rg
Copy-Item "C:\dl\rg\$rgDir\rg.exe" C:\tools\rg.exe

Get-Verified "https://github.com/jqlang/jq/releases/download/jq-$Jq/jq-windows-amd64.exe" C:\tools\jq.exe $null "https://github.com/jqlang/jq/releases/download/jq-$Jq/sha256sum.txt" 'jq-windows-amd64.exe'

Remove-Item -Recurse -Force C:\dl
# Not the exit code of the last native command (the credential.helper unset may have returned 5).
exit 0
