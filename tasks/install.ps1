<#
    .SYNOPSIS
    Downloads and installs zlint on the local machine.

    .DESCRIPTION
    Retrieves the zlint exe for the latest or a specified version, and
    downloads and installs the application to the local machine.

    .NOTES
    =====================================================================
    MIT License

    Copyright (c) 2024 Don Isaac

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    =====================================================================

    .LINK
    For more information, please see https://donisaac.github.io/zlint/docs/installation

#>
param (
    # Specifies a target version of ZLint to install.
    # By default, the latest version is installed.
    # This will use the value in $env:ZLintVersion, if that environment variable is present.
    [Parameter(Mandatory = $false)]
    [string]
    $ZLintVersion = $env:ZLintVersion,

    # Specifies a GitHub URL to download ZLint releases from.
    # By default, https://github.com is used.
    # This will use the value in $env:GitHubUrl, if that environment variable is present.
    [Parameter(Mandatory = $false)]
    [string]
    $GitHubUrl = $env:GitHubUrl
)

if (-not $GitHubUrl) {
    $GitHubUrl = "https://github.com"
}

# Determine target
$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$Target = switch ($Architecture) {
    'X64'    { 'x86_64' }
    'Arm64'  { 'aarch64' }
    default {
        throw "Unsupported architecture: $Architecture"
    }
}

# Determine download URL
$GitHubRepo = "$GitHubUrl/DonIsaac/zlint"
$ZlintDownloadUrl = if ($ZLintVersion) {
    "$GitHubRepo/releases/download/$ZLintVersion/zlint-windows-$Target.exe"
} else {
    "$GitHubRepo/releases/latest/download/zlint-windows-$Target.exe"
}

if ($ZLintVersion) {
    Write-Host "Downloading ZLint $ZLintVersion from: $ZlintDownloadUrl"
} else {
    Write-Host "Downloading latest ZLint from: $ZlintDownloadUrl"
}

# Prepare destination
$zLintDir = "$env:LOCALAPPDATA\Programs\zlint"

if (-not (Test-Path $zLintDir -PathType Container)) {
    $null = New-Item -Path $zLintDir -ItemType Directory
}

# Download ZLint
$zLint = Join-Path $zLintDir "zlint.exe"
Invoke-WebRequest -Uri "$ZlintDownloadUrl" -OutFile $zLint -ErrorAction Stop

# Add ZLint to the PATH

function Set-UserPath {
    Param(
        [string]$Value
    )

    [Environment]::SetEnvironmentVariable('PATH', "$Value", 'User')
}

function Add-UserPath
{
    Param(
        [string]$Value
    )
    
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ((-not $userPath) -or ($userPath.Trim().Length -eq 0)) {
        Set-UserPath -Value "$Value"
        return $true
    }

    if ($userPath.Split(";").Contains($Value)) {
        return $false
    } else {
        Set-UserPath -Value "$userPath;$Value"
        return $true
    }
}

if (Add-UserPath -Value $zLintDir) {
    Write-Host "Added $zLintDir to user PATH. Restart PowerShell to use zlint."
}
