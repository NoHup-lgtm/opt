# vm-roundtrip.ps1 — prova mecânica de apply→revert (convenção do CLAUDE.md).
#
# APLICA TODOS OS TWEAKS DE VERDADE e depois reverte tudo. Rode APENAS numa
# VM Windows descartável (com snapshot), como Administrador:
#
#   .\tests\vm-roundtrip.ps1 -EuSeiQueEstouNumaVM
#
# O que ele faz:
#   1. Fotografa o estado de TODAS as chaves que o catálogo toca (+ plano de energia).
#   2. Aplica todos os tweaks disponíveis (incl. Avançados — é uma VM).
#   3. Confere que cada um está aplicado e verificado.
#   4. Reverte tudo (Undo-AllTweaks).
#   5. Fotografa de novo e faz diff: qualquer diferença = revert incompleto = FALHA.

param(
    [switch]$EuSeiQueEstouNumaVM
)

$ErrorActionPreference = 'Stop'

if (-not $EuSeiQueEstouNumaVM) {
    Write-Host 'Este script APLICA E REVERTE tweaks reais no sistema.' -ForegroundColor Red
    Write-Host 'Rode somente numa VM descartável, com: .\vm-roundtrip.ps1 -EuSeiQueEstouNumaVM'
    exit 1
}

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'mvp-powershell\OptimizerCore.ps1')
Initialize-Optimizer

if (-not (Test-IsAdmin)) { Write-Host 'Rode como Administrador.' -ForegroundColor Red; exit 1 }

# --- Fotografa tudo que o catálogo pode tocar --------------------------------
function Get-SystemSnapshot {
    $snap = @{}
    foreach ($t in Get-Tweaks) {
        if ($t.Alvos) {
            foreach ($a in $t.Alvos) {
                $i = Get-RegValueInfo -Path $a.Path -Name $a.Name
                $snap["$($a.Path)|$($a.Name)"] = if ($i.Existed) { "$($i.Type)|$($i.Value)" } else { '(ausente)' }
            }
        }
    }
    # Nagle: todas as interfaces
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    foreach ($k in (Get-ChildItem -Path $root)) {
        foreach ($n in 'TcpAckFrequency', 'TCPNoDelay') {
            $i = Get-RegValueInfo -Path $k.PSPath -Name $n
            $snap["$($k.PSPath)|$n"] = if ($i.Existed) { "$($i.Type)|$($i.Value)" } else { '(ausente)' }
        }
    }
    # Plano de energia
    $snap['powercfg|activescheme'] = Get-ActivePowerScheme
    $snap
}

Write-Host '1/5 Fotografando estado inicial...' -ForegroundColor Cyan
$before = Get-SystemSnapshot

$targets = @(Get-Tweaks | Where-Object { -not (Get-TweakUnavailableReason -Tweak $_) })
$skipped = @(Get-Tweaks | Where-Object { Get-TweakUnavailableReason -Tweak $_ })
foreach ($s in $skipped) { Write-Host "  (pulado — indisponível: $($s.Id))" -ForegroundColor DarkGray }

Write-Host "2/5 Aplicando $($targets.Count) tweak(s)..." -ForegroundColor Cyan
$failApply = 0
Enter-OptimizerLock
try {
    foreach ($t in $targets) {
        try {
            Invoke-Tweak -Tweak $t
            Write-Host "  [ok] $($t.Id)" -ForegroundColor Green
        } catch {
            $failApply++
            Write-Host "  [erro] $($t.Id): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host '3/5 Conferindo que tudo está aplicado...' -ForegroundColor Cyan
    $notApplied = 0
    foreach ($t in $targets) {
        if (-not (Test-TweakApplied -Tweak $t)) {
            $notApplied++
            Write-Host "  [FALHA] $($t.Id) não consta como aplicado" -ForegroundColor Red
        }
    }

    Write-Host '4/5 Revertendo tudo (Undo-AllTweaks)...' -ForegroundColor Cyan
    Undo-AllTweaks
} finally { Exit-OptimizerLock }

Write-Host '5/5 Fotografando de novo e comparando...' -ForegroundColor Cyan
$after = Get-SystemSnapshot

$diffs = @()
foreach ($key in $before.Keys) {
    if ("$($before[$key])" -ne "$($after[$key])") {
        $diffs += "  $key`n    antes:  $($before[$key])`n    depois: $($after[$key])"
    }
}

Write-Host ''
Write-Host ('=' * 60)
if ($diffs.Count -eq 0 -and $failApply -eq 0 -and $notApplied -eq 0 -and $script:Backup.Count -eq 0) {
    Write-Host 'ROUND-TRIP OK — todos os valores voltaram EXATAMENTE ao estado original.' -ForegroundColor Green
    exit 0
}
if ($failApply -gt 0)  { Write-Host "$failApply tweak(s) falharam no apply" -ForegroundColor Red }
if ($notApplied -gt 0) { Write-Host "$notApplied tweak(s) não verificaram como aplicados" -ForegroundColor Red }
if ($script:Backup.Count -gt 0) { Write-Host "backup não ficou vazio ($($script:Backup.Count) entrada(s) órfãs)" -ForegroundColor Red }
if ($diffs.Count -gt 0) {
    Write-Host "REVERT INCOMPLETO — $($diffs.Count) diferença(s):" -ForegroundColor Red
    $diffs | ForEach-Object { Write-Host $_ }
}
exit 1
