# get.ps1 - roda o Optimizer com UM comando, sem clonar nada (fase de validacao).
#
# O cliente cola isto num PowerShell:
#
#   irm https://raw.githubusercontent.com/NoHup-lgtm/opt/main/get.ps1 | iex
#
# Baixa o motor + painel para %LOCALAPPDATA%\Optimizer\app e abre o painel (UAC).
#
# IMPORTANTE (manutencao): este arquivo roda via "irm | iex", entao ele NAO pode
# ter param() (nao funciona em iex), NAO pode ter BOM e NAO usa acentos - o BOM
# vira caractere invisivel que quebra o primeiro comentario e o parse inteiro.
# Para customizar, defina $BaseUrl / $NoLaunch ANTES do iex.

$ErrorActionPreference = 'Stop'

if (-not (Get-Variable -Name BaseUrl -ErrorAction SilentlyContinue) -or -not $BaseUrl) {
    $BaseUrl = 'https://raw.githubusercontent.com/NoHup-lgtm/opt/main/mvp-powershell'
}
if (-not (Get-Variable -Name NoLaunch -ErrorAction SilentlyContinue)) { $NoLaunch = $false }

# Win10 antigo pode ter TLS 1.0 como padrao - GitHub exige 1.2+
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$dir = Join-Path $env:LOCALAPPDATA 'Optimizer\app'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

foreach ($f in 'OptimizerCore.ps1', 'OptimizerApp.ps1') {
    $dest = Join-Path $dir $f
    Write-Host "baixando $f..." -ForegroundColor DarkGray
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$f" -OutFile $dest
    Unblock-File -Path $dest -ErrorAction SilentlyContinue
}

Write-Host "OK - instalado em $dir" -ForegroundColor Green
if (-not $NoLaunch) {
    Write-Host 'Abrindo o painel (vai pedir permissao de administrador)...'
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$dir\OptimizerApp.ps1`""
}
