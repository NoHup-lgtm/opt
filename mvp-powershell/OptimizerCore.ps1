# OptimizerCore.ps1 — motor de otimização (biblioteca compartilhada pela CLI e pela GUI)
#
# Regras invioláveis (ver CLAUDE.md):
#   - Toda alteração de sistema passa pela camada de backup (nunca escrever no registro direto).
#   - Todo tweak tem Apply e Revert. Existe "desfazer tudo".
#   - Tudo que é aplicado/revertido vai para o log com timestamp.

$script:DataDir    = Join-Path $env:LOCALAPPDATA 'Optimizer'
$script:BackupFile = Join-Path $script:DataDir 'backup.json'
$script:LogFile    = Join-Path $script:DataDir 'optimizer.log'
$script:LogSink    = $null   # scriptblock opcional — a GUI pluga aqui para espelhar o log na tela
$script:Backup     = @{}

# ---------------------------------------------------------------------------
# Infraestrutura: log e backup
# ---------------------------------------------------------------------------

function Write-OptLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
    if ($script:LogSink) { & $script:LogSink $line }
}

function Initialize-Optimizer {
    if (-not (Test-Path $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
    $script:Backup = @{}
    if (Test-Path $script:BackupFile) {
        try {
            $raw = Get-Content -Path $script:BackupFile -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                $obj = $raw | ConvertFrom-Json
                foreach ($p in $obj.PSObject.Properties) { $script:Backup[$p.Name] = $p.Value }
            }
        } catch {
            Write-OptLog "backup.json ilegível, iniciando vazio: $_" 'WARN'
        }
    }
}

function Save-OptimizerBackup {
    if ($script:Backup.Count -eq 0) {
        Set-Content -Path $script:BackupFile -Value '{}' -Encoding UTF8
    } else {
        $script:Backup | ConvertTo-Json -Depth 6 | Set-Content -Path $script:BackupFile -Encoding UTF8
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-OptimizerRestorePoint {
    # O Windows limita a criação a 1 ponto a cada 24h por padrão; se falhar,
    # avisa mas não bloqueia — os backups em JSON continuam garantindo o revert.
    try {
        Checkpoint-Computer -Description 'Optimizer - antes de aplicar' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-OptLog 'Ponto de restauração criado.'
        return $true
    } catch {
        Write-OptLog "Não foi possível criar ponto de restauração: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Camada de escrita reversível no registro
# ---------------------------------------------------------------------------

function Get-RegValueInfo {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-Item -Path $Path -ErrorAction Stop
        if ($item.GetValueNames() -contains $Name) {
            return @{
                Existed = $true
                Value   = $item.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                Type    = $item.GetValueKind($Name).ToString()
            }
        }
    } catch { }
    return @{ Existed = $false; Value = $null; Type = $null }
}

function Set-RegValueBacked {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Type = 'DWord'
    )
    $key = "reg|$Path|$Name"
    if (-not $script:Backup.ContainsKey($key)) {
        # Guarda só o valor ORIGINAL: reaplicar um tweak não pode sobrescrever o backup.
        $info = Get-RegValueInfo -Path $Path -Name $Name
        $script:Backup[$key] = @{
            kind    = 'registry'
            path    = $Path
            name    = $Name
            existed = $info.Existed
            value   = $info.Value
            type    = $info.Type
            savedAt = (Get-Date).ToString('s')
        }
        Save-OptimizerBackup
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
    Write-OptLog "SET $Path\$Name = $Value ($Type)"
}

function Restore-RegValueBacked {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $key = "reg|$Path|$Name"
    if (-not $script:Backup.ContainsKey($key)) { return }
    $b = $script:Backup[$key]
    if ($b.existed) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $b.value -Type $b.type
        Write-OptLog "RESTORE $Path\$Name = $($b.value)"
    } else {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        Write-OptLog "RESTORE $Path\$Name (valor não existia — removido)"
    }
    $script:Backup.Remove($key)
    Save-OptimizerBackup
}

# ---------------------------------------------------------------------------
# powercfg (plano de energia) com backup
# ---------------------------------------------------------------------------

function Get-ActivePowerScheme {
    $out = powercfg /getactivescheme
    # regex no GUID em vez de parsear o texto (que é localizado em pt-BR)
    if ("$out" -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        return $Matches[1]
    }
    return $null
}

$script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

# ---------------------------------------------------------------------------
# Catálogo de otimizações de SISTEMA (camada 1 — vale para qualquer jogo).
# Otimizações POR JOGO virão dos perfis JSON (Fase 4), nunca deste catálogo.
# ---------------------------------------------------------------------------

$script:Tweaks = @(
    [pscustomobject]@{
        Id            = 'GameDVR'
        Nome          = 'Desativar Game DVR (gravação em segundo plano)'
        Categoria     = 'Sistema'
        Risco         = 'Seguro'
        Descricao     = 'Desliga a captura de gameplay do Xbox Game Bar que roda em segundo plano.'
        Efeito        = 'Remove overhead de gravação; ganho pequeno mas consistente de frametime.'
        RequerAdmin   = $false
        RequerReinicio = $false
        Apply = {
            Set-RegValueBacked -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord
            Set-RegValueBacked -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -Type DWord
        }
        Revert = {
            Restore-RegValueBacked -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled'
            Restore-RegValueBacked -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled'
        }
        Test = {
            $a = Get-RegValueInfo -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled'
            $b = Get-RegValueInfo -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled'
            ($a.Existed -and $a.Value -eq 0) -and ($b.Existed -and $b.Value -eq 0)
        }
    }
    [pscustomobject]@{
        Id            = 'GameMode'
        Nome          = 'Ativar Modo de Jogo do Windows'
        Categoria     = 'Sistema'
        Risco         = 'Seguro'
        Descricao     = 'Garante que o Game Mode nativo do Windows está ligado.'
        Efeito        = 'Prioriza o jogo e evita instalação de updates/notificações durante partidas.'
        RequerAdmin   = $false
        RequerReinicio = $false
        Apply = {
            Set-RegValueBacked -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1 -Type DWord
        }
        Revert = {
            Restore-RegValueBacked -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AutoGameModeEnabled'
        }
        Test = {
            $a = Get-RegValueInfo -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AutoGameModeEnabled'
            $a.Existed -and $a.Value -eq 1
        }
    }
    [pscustomobject]@{
        Id            = 'Power'
        Nome          = 'Plano de energia: Alto Desempenho'
        Categoria     = 'Energia'
        Risco         = 'Seguro'
        Descricao     = 'Troca o plano de energia ativo para Alto Desempenho (o plano anterior fica salvo no backup).'
        Efeito        = 'CPU deixa de reduzir clock agressivamente; melhora consistência de frametime.'
        RequerAdmin   = $false
        RequerReinicio = $false
        Apply = {
            $key = 'powercfg|activescheme'
            if (-not $script:Backup.ContainsKey($key)) {
                $script:Backup[$key] = @{
                    kind    = 'powercfg'
                    value   = (Get-ActivePowerScheme)
                    savedAt = (Get-Date).ToString('s')
                }
                Save-OptimizerBackup
            }
            powercfg /setactive $script:HighPerfGuid 2>$null
            if ($LASTEXITCODE -ne 0) { powercfg /setactive SCHEME_MIN | Out-Null }
            Write-OptLog "POWERCFG setactive $script:HighPerfGuid"
        }
        Revert = {
            $key = 'powercfg|activescheme'
            if ($script:Backup.ContainsKey($key)) {
                $prev = $script:Backup[$key].value
                if ($prev) {
                    powercfg /setactive $prev | Out-Null
                    Write-OptLog "POWERCFG restaurado para $prev"
                }
                $script:Backup.Remove($key)
                Save-OptimizerBackup
            }
        }
        Test = { (Get-ActivePowerScheme) -eq $script:HighPerfGuid }
    }
    [pscustomobject]@{
        Id            = 'MouseAccel'
        Nome          = 'Desativar aceleração do mouse'
        Categoria     = 'Entrada'
        Risco         = 'Seguro'
        Descricao     = 'Desliga "Aumentar a precisão do ponteiro" (aceleração). Vale a partir do próximo logon.'
        Efeito        = 'Mira consistente: o mesmo movimento físico sempre vira o mesmo movimento na tela. Não afeta FPS.'
        RequerAdmin   = $false
        RequerReinicio = $false
        Apply = {
            Set-RegValueBacked -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '0' -Type String
            Set-RegValueBacked -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0' -Type String
            Set-RegValueBacked -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0' -Type String
        }
        Revert = {
            Restore-RegValueBacked -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed'
            Restore-RegValueBacked -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1'
            Restore-RegValueBacked -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2'
        }
        Test = {
            $a = Get-RegValueInfo -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed'
            $a.Existed -and $a.Value -eq '0'
        }
    }
    [pscustomobject]@{
        Id            = 'VisualFX'
        Nome          = 'Efeitos visuais: melhor desempenho'
        Categoria     = 'Sistema'
        Risco         = 'Moderado'
        Descricao     = 'Configura os efeitos visuais do Windows para "Ajustar para obter melhor desempenho". Muda a aparência do Windows; vale a partir do próximo logon.'
        Efeito        = 'Libera CPU/GPU de animações e sombras do Windows; ajuda em PCs mais fracos.'
        RequerAdmin   = $false
        RequerReinicio = $false
        Apply = {
            Set-RegValueBacked -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -Type DWord
        }
        Revert = {
            Restore-RegValueBacked -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting'
        }
        Test = {
            $a = Get-RegValueInfo -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting'
            $a.Existed -and $a.Value -eq 2
        }
    }
    [pscustomobject]@{
        Id            = 'GpuPref'
        Nome          = 'Prioridade alta de GPU/CPU para jogos'
        Categoria     = 'Sistema'
        Risco         = 'Moderado'
        Descricao     = 'Ajusta o perfil multimídia do Windows para agendar jogos com prioridade de GPU 8 e CPU alta.'
        Efeito        = 'Jogos ganham prioridade no escalonador. Impacto debatível (depende da carga do PC), sem risco conhecido.'
        RequerAdmin   = $true
        RequerReinicio = $false
        Apply = {
            $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
            Set-RegValueBacked -Path $p -Name 'GPU Priority' -Value 8 -Type DWord
            Set-RegValueBacked -Path $p -Name 'Priority' -Value 6 -Type DWord
            Set-RegValueBacked -Path $p -Name 'Scheduling Category' -Value 'High' -Type String
        }
        Revert = {
            $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
            Restore-RegValueBacked -Path $p -Name 'GPU Priority'
            Restore-RegValueBacked -Path $p -Name 'Priority'
            Restore-RegValueBacked -Path $p -Name 'Scheduling Category'
        }
        Test = {
            $a = Get-RegValueInfo -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -Name 'GPU Priority'
            $a.Existed -and $a.Value -eq 8
        }
    }
    [pscustomobject]@{
        Id            = 'NetThrottle'
        Nome          = 'Remover limitação de rede para multimídia'
        Categoria     = 'Rede'
        Risco         = 'Moderado'
        Descricao     = 'Desativa o Network Throttling do Windows (que limita pacotes/ms quando há multimídia rodando) e reduz a reserva de CPU para processos em segundo plano.'
        Efeito        = 'Pode reduzir lag em jogos online. Impacto debatível — medir antes/depois.'
        RequerAdmin   = $true
        RequerReinicio = $true
        Apply = {
            $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
            Set-RegValueBacked -Path $p -Name 'NetworkThrottlingIndex' -Value (-1) -Type DWord  # 0xFFFFFFFF = desativado
            Set-RegValueBacked -Path $p -Name 'SystemResponsiveness' -Value 10 -Type DWord      # padrão é 20
        }
        Revert = {
            $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
            Restore-RegValueBacked -Path $p -Name 'NetworkThrottlingIndex'
            Restore-RegValueBacked -Path $p -Name 'SystemResponsiveness'
        }
        Test = {
            $a = Get-RegValueInfo -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex'
            $a.Existed -and $a.Value -eq -1
        }
    }
    [pscustomobject]@{
        Id            = 'Nagle'
        Nome          = 'Desativar algoritmo de Nagle (TCP)'
        Categoria     = 'Rede'
        Risco         = 'Moderado'
        Descricao     = 'Desliga o agrupamento de pacotes TCP nas interfaces de rede ativas (TcpAckFrequency=1, TCPNoDelay=1).'
        Efeito        = 'Reduz latência em jogos que usam TCP (ex.: LoL). Não afeta jogos UDP (CS2, Valorant). Debatível.'
        RequerAdmin   = $true
        RequerReinicio = $true
        Apply = {
            $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
            $touched = 0
            foreach ($k in (Get-ChildItem -Path $root)) {
                $p = Get-ItemProperty -Path $k.PSPath
                $hasIp = $false
                if ($p.PSObject.Properties['DhcpIPAddress'] -and $p.DhcpIPAddress -and $p.DhcpIPAddress -ne '0.0.0.0') { $hasIp = $true }
                if (-not $hasIp -and $p.PSObject.Properties['IPAddress']) {
                    if (@($p.IPAddress | Where-Object { $_ -and $_ -ne '0.0.0.0' }).Count -gt 0) { $hasIp = $true }
                }
                if ($hasIp) {
                    Set-RegValueBacked -Path $k.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord
                    Set-RegValueBacked -Path $k.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord
                    $touched++
                }
            }
            Write-OptLog "Nagle desativado em $touched interface(s) com IP ativo"
        }
        Revert = {
            # Restaura toda interface que tiver backup (a lista de interfaces pode ter mudado desde o apply)
            foreach ($key in @($script:Backup.Keys)) {
                $b = $script:Backup[$key]
                if ($b.kind -eq 'registry' -and $b.path -like '*Tcpip\Parameters\Interfaces*') {
                    Restore-RegValueBacked -Path $b.path -Name $b.name
                }
            }
        }
        Test = {
            $applied = $false
            foreach ($key in @($script:Backup.Keys)) {
                $b = $script:Backup[$key]
                if ($b.kind -eq 'registry' -and $b.path -like '*Tcpip\Parameters\Interfaces*') { $applied = $true; break }
            }
            $applied
        }
    }
    [pscustomobject]@{
        Id            = 'PowerThrottle'
        Nome          = 'Desativar Power Throttling'
        Categoria     = 'Energia'
        Risco         = 'Moderado'
        Descricao     = 'Impede o Windows de reduzir o clock de processos que ele considera "em segundo plano".'
        Efeito        = 'Evita que overlays, anti-cheat e apps auxiliares percam desempenho. Aumenta consumo de energia.'
        RequerAdmin   = $true
        RequerReinicio = $true
        Apply = {
            Set-RegValueBacked -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Name 'PowerThrottlingOff' -Value 1 -Type DWord
        }
        Revert = {
            Restore-RegValueBacked -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Name 'PowerThrottlingOff'
        }
        Test = {
            $a = Get-RegValueInfo -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Name 'PowerThrottlingOff'
            $a.Existed -and $a.Value -eq 1
        }
    }
    [pscustomobject]@{
        Id            = 'HAGS'
        Nome          = 'Agendamento de GPU por hardware (HAGS)'
        Categoria     = 'GPU'
        Risco         = 'Avançado'
        Descricao     = 'Liga o Hardware-Accelerated GPU Scheduling. Requer GPU/driver compatível e REINÍCIO. O ganho varia por hardware — meça antes/depois; em alguns sistemas piora.'
        Efeito        = 'Pode reduzir latência de frame em GPUs recentes. Resultado depende do driver.'
        RequerAdmin   = $true
        RequerReinicio = $true
        Apply = {
            Set-RegValueBacked -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 -Type DWord
        }
        Revert = {
            Restore-RegValueBacked -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode'
        }
        Test = {
            $a = Get-RegValueInfo -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode'
            $a.Existed -and $a.Value -eq 2
        }
    }
)

# ---------------------------------------------------------------------------
# Operações sobre o catálogo
# ---------------------------------------------------------------------------

function Get-Tweaks { $script:Tweaks }

function Get-TweakById {
    param([Parameter(Mandatory)][string]$Id)
    $t = $script:Tweaks | Where-Object { $_.Id -eq $Id }
    if (-not $t) { throw "Tweak desconhecido: '$Id'. Use 'list' para ver os disponíveis." }
    $t
}

function Test-TweakApplied {
    param([Parameter(Mandatory)]$Tweak)
    try { [bool](& $Tweak.Test) } catch { $false }
}

function Invoke-Tweak {
    param([Parameter(Mandatory)]$Tweak)
    if ($Tweak.RequerAdmin -and -not (Test-IsAdmin)) {
        throw "'$($Tweak.Id)' precisa de PowerShell como Administrador."
    }
    & $Tweak.Apply
    Write-OptLog "APLICADO: $($Tweak.Id) — $($Tweak.Nome)"
}

function Undo-Tweak {
    param([Parameter(Mandatory)]$Tweak)
    if ($Tweak.RequerAdmin -and -not (Test-IsAdmin)) {
        throw "'$($Tweak.Id)' precisa de PowerShell como Administrador para reverter."
    }
    & $Tweak.Revert
    Write-OptLog "REVERTIDO: $($Tweak.Id) — $($Tweak.Nome)"
}

function Undo-AllTweaks {
    # 1º: revert de cada tweak; 2º: varredura de segurança em qualquer backup restante.
    foreach ($t in $script:Tweaks) {
        try { Undo-Tweak -Tweak $t } catch { Write-OptLog "Falha revertendo $($t.Id): $_" 'ERROR' }
    }
    foreach ($key in @($script:Backup.Keys)) {
        $b = $script:Backup[$key]
        if ($b.kind -eq 'registry') {
            try { Restore-RegValueBacked -Path $b.path -Name $b.name } catch { Write-OptLog "Falha restaurando ${key}: $_" 'ERROR' }
        }
    }
    Write-OptLog 'DESFAZER TUDO concluído.'
}
