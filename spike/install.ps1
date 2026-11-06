$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$node = '24.22.2';    $nodeSha = 'ca1bff5d8ead13c9f2ea404a176db46bd430704d5b5113734049fa365e7799e2'
$gitV = '2.56.0.4';   $gitTag = 'v2.56.0.windows.4'; $gitSha = 'b1f3e52216e2ed6882d1bebfd4d3fdf319bec40d2edbbf9fd26ec4fd3fce7ed1'
$py   = '3.14.10'
$rg   = '15.2.0';     $rgSha = '71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5'
$jq   = '1.8.2';      $jqSha = 'a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627'

function Get-Verified($url, $out, $sha) {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out
    if ($sha -and (Get-FileHash $out -Algorithm SHA256).Hash.ToLower() -ne $sha) { throw "checksum mismatch for $url" }
}

New-Item -ItemType Directory -Force C:\tools, C:\dl | Out-Null

Get-Verified "https://nodejs.org/dist/v$node/node-v$node-win-x64.zip" C:\dl\node.zip $nodeSha
Expand-Archive C:\dl\node.zip C:\dl\node
Move-Item "C:\dl\node\node-v$node-win-x64" C:\node

Get-Verified "https://github.com/git-for-windows/git/releases/download/$gitTag/PortableGit-$gitV-64-bit.7z.exe" C:\dl\git.exe $gitSha
Start-Process C:\dl\git.exe -ArgumentList '-o', 'C:\git', '-y' -Wait -NoNewWindow
if (-not (Test-Path C:\git\bin\bash.exe)) { throw 'PortableGit extraction failed' }

# python.org publishes no sha256 for the embeddable zip (only md5/sigstore).
Get-Verified "https://www.python.org/ftp/python/$py/python-$py-embed-amd64.zip" C:\dl\py.zip $null
Expand-Archive C:\dl\py.zip C:\python
Copy-Item C:\python\python.exe C:\python\python3.exe

Get-Verified "https://github.com/BurntSushi/ripgrep/releases/download/$rg/ripgrep-$rg-x86_64-pc-windows-msvc.zip" C:\dl\rg.zip $rgSha
Expand-Archive C:\dl\rg.zip C:\dl\rg
Copy-Item "C:\dl\rg\ripgrep-$rg-x86_64-pc-windows-msvc\rg.exe" C:\tools\rg.exe

Get-Verified "https://github.com/jqlang/jq/releases/download/jq-$jq/jq-windows-amd64.exe" C:\tools\jq.exe $jqSha

Remove-Item -Recurse -Force C:\dl

# Probe dirs for the mount experiments: one empty and one non-empty under the container user's profile.
New-Item -ItemType Directory -Force C:\npm-global, C:\Users\ContainerUser\empty, C:\Users\ContainerUser\nonempty | Out-Null
Set-Content C:\Users\ContainerUser\nonempty\baked.txt 'baked in image'
icacls C:\npm-global /grant 'ContainerUser:(OI)(CI)M' | Out-Null
