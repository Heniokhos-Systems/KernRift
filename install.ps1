# KernRift Self-Hosted Compiler Installer for Windows
# Run: irm https://raw.githubusercontent.com/Heniokhos-Systems/KernRift/main/install.ps1 | iex

$ErrorActionPreference = "Stop"
$Repo = "Heniokhos-Systems/KernRift"
$InstallDir = "$env:LOCALAPPDATA\KernRift\bin"

Write-Host "=== KernRift Self-Hosted Compiler Installer ==="

# Architecture detection
$arch = [System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
$ArchName = switch ($arch) {
    "AMD64" { "x86_64" }
    "ARM64" { "arm64" }
    default {
        Write-Host "error: unsupported architecture: $arch" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Platform: windows $ArchName"
Write-Host "Install to: $InstallDir"
Write-Host ""

# Create install directory
if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# Download krc compiler from GitHub releases
$BinaryName = "krc-windows-$ArchName.exe"
$Url = "https://github.com/$Repo/releases/latest/download/$BinaryName"
$Dest = "$InstallDir\krc.exe"

Write-Host "Downloading $BinaryName..."
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
} catch {
    Write-Host "error: download failed: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Manual install: download from https://github.com/$Repo/releases"
    exit 1
}

# Download kr runner
$KrBinaryName = "kr-windows-$ArchName.exe"
$KrUrl = "https://github.com/$Repo/releases/latest/download/$KrBinaryName"
$KrDest = "$InstallDir\kr.exe"
Write-Host "Downloading $KrBinaryName..."
try {
    Invoke-WebRequest -Uri $KrUrl -OutFile $KrDest -UseBasicParsing
} catch {
    Write-Host "  warning: could not download kr runner" -ForegroundColor Yellow
}

# Download standard library
$StdDir = "$env:LOCALAPPDATA\KernRift\std"
if (!(Test-Path $StdDir)) {
    New-Item -ItemType Directory -Path $StdDir -Force | Out-Null
}
Write-Host "Installing standard library..."
foreach ($mod in @("alloc", "string", "io", "math", "math_float", "fmt", "mem", "memfast", "vec", "map", "color", "fb", "fixedpoint", "font", "widget", "time", "log", "net", "sha256")) {
    $modUrl = "https://raw.githubusercontent.com/$Repo/main/std/$mod.kr"
    try {
        Invoke-WebRequest -Uri $modUrl -OutFile "$StdDir\$mod.kr" -UseBasicParsing
    } catch {
        Write-Host "  warning: could not download std/$mod.kr" -ForegroundColor Yellow
    }
}
Write-Host "Standard library: $StdDir"

# Add to PATH if not already there
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($UserPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("PATH", "$InstallDir;$UserPath", "User")
    Write-Host "Added $InstallDir to user PATH"
    Write-Host "Restart your terminal for PATH changes to take effect."
}

Write-Host ""
Write-Host "Installed: $Dest"
Write-Host ""
Write-Host "Usage:"
Write-Host "  krc --emit=pe program.kr -o program.exe   # compile for Windows"
Write-Host "  krc --arch=x86_64 prog.kr                 # native x86_64 ELF"
Write-Host "  krc program.kr -o program.krbo             # fat binary (7 slices)"
Write-Host "  krc --version                              # show version"
Write-Host ""
Write-Host "=== Installation complete ==="
