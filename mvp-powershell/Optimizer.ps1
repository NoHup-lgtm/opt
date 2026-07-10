# Optimizer.ps1 — motor de otimização em linha de comando
#
# Uso:
#   .\Optimizer.ps1 list                       # lista o catálogo de tweaks
#   .\Optimizer.ps1 status                     # mostra o que está aplicado
#   .\Optimizer.ps1 apply GameDVR,Power        # aplica tweaks específicos
#   .\Optimizer.ps1 apply -All                 # aplica todos os Seguro+Moderado (Avançado só por id explícito)
#   .\Optimizer.ps1 revert GameDVR             # reverte tweaks específicos
#   .\Optimizer.ps1 revert-all                 # desfaz TUDO (tweaks + qualquer backup restante)
#   .\Optimizer.ps1 log                        # mostra as últimas linhas do log

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'status', 'apply', 'revert', 'revert-all', 'log', 'diag')]
    [string]$Command = 'list',

    [Parameter(Position = 1)]
    [string[]]$Ids,

    [switch]$All,
    [switch]$SkipRestorePoint
)

. (Join-Path $PSScriptRoot 'OptimizerCore.ps1')
Initialize-Optimizer

function Resolve-Targets {
    if ($All) {
        # Regra: nada de Avançado em lote — só por id explícito.
        return Get-Tweaks | Where-Object { $_.Risco -ne 'Avançado' }
    }
    if (-not $Ids -or $Ids.Count -eq 0) {
        throw "Informe os ids (ex.: apply GameDVR,Power) ou use -All."
    }
    $Ids | ForEach-Object { Get-TweakById -Id $_ }
}

switch ($Command) {

    'list' {
        Get-Tweaks | Format-Table -AutoSize -Wrap @(
            @{ L = 'Id';        E = { $_.Id } }
            @{ L = 'Risco';     E = { $_.Risco } }
            @{ L = 'Admin';     E = { if ($_.RequerAdmin) { 'sim' } else { '' } } }
            @{ L = 'Reinício';  E = { if ($_.RequerReinicio) { 'sim' } else { '' } } }
            @{ L = 'Nome';      E = { $_.Nome } }
            @{ L = 'Obs';       E = { $r = Get-TweakUnavailableReason $_; if ($r) { "indisponível: $r" } else { '' } } }
        )
    }

    'status' {
        Get-Tweaks | Format-Table -AutoSize -Wrap @(
            @{ L = 'Id';       E = { $_.Id } }
            @{ L = 'Aplicado'; E = { if (Test-TweakApplied $_) { 'SIM' } else { '-' } } }
            @{ L = 'Risco';    E = { $_.Risco } }
            @{ L = 'Nome';     E = { $_.Nome } }
        )
        foreach ($g in @(Get-GpuInfo)) {
            $tipo = if ($g.Integrada) { 'integrada' } else { 'dedicada' }
            Write-Host "GPU:    $($g.Name) [$($g.Vendor) · $tipo · driver $($g.Driver)]"
        }
        Write-Host "Backup: $script:BackupFile ($($script:Backup.Count) entrada(s))"
        Write-Host "Log:    $script:LogFile"
    }

    'apply' {
        $targets = Resolve-Targets
        Write-Host "Aplicando $($targets.Count) tweak(s)..." -ForegroundColor Cyan

        if (-not $SkipRestorePoint) {
            if (-not (Test-IsAdmin)) {
                Write-Warning 'Sem admin: não dá para criar ponto de restauração. Rode como Administrador ou use -SkipRestorePoint para silenciar.'
            } elseif (-not (Test-SystemRestoreEnabled)) {
                # Regra 2: ponto de restauração antes de aplicar. Se o System Restore
                # está desligado, parar e explicar — nada de falhar em silêncio.
                Write-Host 'O System Restore está DESATIVADO neste PC — impossível criar o ponto de restauração.' -ForegroundColor Red
                Write-Host 'Ative com (como admin):  Enable-ComputerRestore -Drive "C:\"'
                Write-Host 'Ou rode de novo com -SkipRestorePoint para aplicar só com o backup JSON.'
                exit 1
            } else {
                Write-Host 'Criando ponto de restauração (pode demorar ~30s)...'
                if (-not (New-OptimizerRestorePoint)) {
                    Write-Warning 'Ponto de restauração falhou (o backup JSON continua garantindo o revert).'
                }
            }
        }

        Enter-OptimizerLock
        try {
            $reboot = $false
            foreach ($t in $targets) {
                try {
                    Invoke-Tweak -Tweak $t
                    Write-Host "  [ok] $($t.Id) — $($t.Nome) (verificado)" -ForegroundColor Green
                    if ($t.RequerReinicio) { $reboot = $true }
                } catch {
                    Write-Host "  [erro] $($t.Id): $($_.Exception.Message)" -ForegroundColor Red
                    Write-OptLog "Falha aplicando $($t.Id): $_" 'ERROR'
                }
            }
            if ($reboot) { Write-Host 'Alguns tweaks só valem após REINICIAR o PC.' -ForegroundColor Yellow }
        } finally { Exit-OptimizerLock }
    }

    'revert' {
        $targets = Resolve-Targets
        Enter-OptimizerLock
        try {
            foreach ($t in $targets) {
                try {
                    Undo-Tweak -Tweak $t
                    Write-Host "  [ok] revertido $($t.Id)" -ForegroundColor Green
                } catch {
                    Write-Host "  [erro] $($t.Id): $($_.Exception.Message)" -ForegroundColor Red
                    Write-OptLog "Falha revertendo $($t.Id): $_" 'ERROR'
                }
            }
        } finally { Exit-OptimizerLock }
    }

    'revert-all' {
        Write-Host 'Desfazendo tudo...' -ForegroundColor Cyan
        Enter-OptimizerLock
        try { Undo-AllTweaks } finally { Exit-OptimizerLock }
        Write-Host 'Concluído. Confira com: .\Optimizer.ps1 status'
    }

    'diag' {
        $zip = Export-OptimizerDiagnostic
        Write-Host "Diagnóstico exportado: $zip"
    }

    'log' {
        if (Test-Path $script:LogFile) {
            Get-Content -Path $script:LogFile -Tail 30
        } else {
            Write-Host 'Sem log ainda.'
        }
    }
}
