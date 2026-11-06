# escape=`
# Spike image: servercore + Node + Git for Windows (bash, coreutils) + Python + ripgrep + jq.
FROM mcr.microsoft.com/windows/servercore:ltsc2025

COPY install.ps1 C:/install.ps1
RUN powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\install.ps1 && del C:\install.ps1

# Git's usr\bin (coreutils) and bin before System32.
ENV PATH="C:\git\usr\bin;C:\git\bin;C:\node;C:\python;C:\tools;C:\npm-global;C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0"
ENV CLAUDE_CODE_GIT_BASH_PATH="C:\git\bin\bash.exe" `
    NPM_CONFIG_PREFIX="C:\npm-global"

COPY in/ C:/spike/
