# get.ps1 — roda o Optimizer com UM comando, sem clonar nada (fase de validação).
#
# O cliente cola isto num PowerShell:
#
#   irm https://raw.githubusercontent.com/NoHup-lgtm/opt/main/get.ps1 | iex
#
# O que faz: baixa o motor + painel para %LOCALAPPDATA%\Optimizer\app e abre o
# painel pedindo elevação (UAC). Requer o repo público no GitHub.
#
# NOTA de produto: isto é para os usuários de VALIDAÇÃO (pessoas que confiam em
# você). O produto vendido continua sendo o .exe assinado (docs/distribuicao.md) —
# não ensine cliente pagante a dar pipe de internet direto no PowerShell.

param(
    # Troque se o repo tiver outro nome/branch
    [string]$BaseUrl = 'https://raw.githubusercontent.com/NoHup-lgtm/opt/main/mvp-powershell',
    [switch]$NoLaunch   # só baixa, não abre (teste)
)

$ErrorActionPreference = 'Stop'

# Win10 antigo pode ter TLS 1.0 como padrão — GitHub exige 1.2+
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$dir = Join-Path $env:LOCALAPPDATA 'Optimizer\app'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

foreach ($f in 'OptimizerCore.ps1', 'OptimizerApp.ps1') {
    $dest = Join-Path $dir $f
    Write-Host "baixando $f..." -ForegroundColor DarkGray
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$f" -OutFile $dest
    Unblock-File -Path $dest -ErrorAction SilentlyContinue
}

Write-Host "OK — instalado em $dir" -ForegroundColor Green
if ($NoLaunch) { return }

Write-Host 'Abrindo o painel (vai pedir permissão de administrador)...'
Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$dir\OptimizerApp.ps1`""
