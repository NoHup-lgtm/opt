# OptimizerCore.ps1 — motor de otimização (biblioteca compartilhada pela CLI e pela GUI)
#
# Regras invioláveis (ver CLAUDE.md):
#   - Toda alteração de sistema passa pela camada de backup (nunca escrever no registro direto).
#   - Todo tweak tem Apply e Revert. Existe "desfazer tudo".
#   - Tudo que é aplicado/revertido vai para o log com timestamp.

$script:DataDir    = Join-Path $env:LOCALAPPDATA 'Optimizer'
$script:BackupFile = Join-Path $script:DataDir 'backup.json'
$script:LogFile    = Join-Path $script:DataDir 'optimizer.log'
$script:LogSink    = $null   # scriptblock opcional — espelha o log em outra saída
$script:Backup     = @{}
$script:GpuCache   = $null

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
# Detecção de GPU (NVIDIA / AMD / integrada)
# ---------------------------------------------------------------------------

function Get-GpuInfo {
    if ($null -ne $script:GpuCache) { return $script:GpuCache }
    $list = @()
    try {
        foreach ($v in (Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if (-not $v.Name) { continue }
            $vendor = 'Outro'
            if ($v.Name -match 'NVIDIA|GeForce|Quadro|RTX|GTX') { $vendor = 'NVIDIA' }
            elseif ($v.Name -match 'AMD|Radeon|ATI') { $vendor = 'AMD' }
            elseif ($v.Name -match 'Intel|UHD|Iris|Arc') { $vendor = 'Intel' }
            # Heurística: Intel (exceto Arc) e APUs AMD ("Radeon(TM) Graphics"/Vega) = integrada
            $integrada = ($vendor -eq 'Intel' -and $v.Name -notmatch 'Arc') -or
                         ($vendor -eq 'AMD' -and $v.Name -match '\(TM\) Graphics|Vega')
            $list += [pscustomobject]@{
                Name      = $v.Name
                Vendor    = $vendor
                Driver    = $v.DriverVersion
                Integrada = $integrada
            }
        }
    } catch {
        Write-OptLog "Falha detectando GPU: $_" 'WARN'
    }
    $script:GpuCache = $list
    return $list
}

function Get-MainGpu {
    $g = @(Get-GpuInfo)
    $dgpu = @($g | Where-Object { -not $_.Integrada })
    if ($dgpu.Count -gt 0) { return $dgpu[0] }
    if ($g.Count -gt 0) { return $g[0] }
    return $null
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
#
# Formato declarativo: tweaks de registro descrevem seus alvos em `Alvos`
# (Path/Name/Valor/Tipo) e ganham Apply/Revert/Test genéricos — o mesmo dado
# alimenta a tela de transparência ("o que exatamente vai mudar").
# Casos especiais (powercfg, Nagle) usam Apply/Revert/Test próprios.
# `Disponivel` retorna $null (ok) ou o motivo de não se aplicar a esta máquina.
# ---------------------------------------------------------------------------

function New-Tweak([hashtable]$P) {
    foreach ($k in 'Alvos','Apply','Revert','Test','Disponivel','DetalhesTexto') {
        if (-not $P.ContainsKey($k)) { $P[$k] = $null }
    }
    if (-not $P.ContainsKey('RequerAdmin'))    { $P['RequerAdmin'] = $false }
    if (-not $P.ContainsKey('RequerReinicio')) { $P['RequerReinicio'] = $false }
    [pscustomobject]$P
}

$script:Tweaks = @(
    (New-Tweak @{
        Id        = 'GameDVR'
        Nome      = 'Desativar Game DVR (gravação em segundo plano)'
        Categoria = 'Sistema'
        Risco     = 'Seguro'
        Descricao = 'Desliga a captura de gameplay do Xbox Game Bar que roda em segundo plano.'
        Efeito    = 'Remove overhead de gravação; ganho pequeno mas consistente de frametime.'
        Alvos     = @(
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Valor = 0; Tipo = 'DWord' }
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Valor = 0; Tipo = 'DWord' }
        )
    })
    (New-Tweak @{
        Id        = 'GameMode'
        Nome      = 'Ativar Modo de Jogo do Windows'
        Categoria = 'Sistema'
        Risco     = 'Seguro'
        Descricao = 'Garante que o Game Mode nativo do Windows está ligado.'
        Efeito    = 'Prioriza o jogo e evita instalação de updates/notificações durante partidas.'
        Alvos     = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Valor = 1; Tipo = 'DWord' }
        )
    })
    (New-Tweak @{
        Id        = 'Power'
        Nome      = 'Plano de energia: Alto Desempenho'
        Categoria = 'Energia'
        Risco     = 'Seguro'
        Descricao = 'Troca o plano de energia ativo para Alto Desempenho (o plano anterior fica salvo no backup).'
        Efeito    = 'CPU deixa de reduzir clock agressivamente; melhora consistência de frametime.'
        DetalhesTexto = @('powercfg /setactive → Alto Desempenho (o plano atual fica salvo no backup)')
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
    })
    (New-Tweak @{
        Id        = 'MouseAccel'
        Nome      = 'Desativar aceleração do mouse'
        Categoria = 'Entrada'
        Risco     = 'Seguro'
        Descricao = 'Desliga "Aumentar a precisão do ponteiro" (aceleração). Vale a partir do próximo logon.'
        Efeito    = 'Mira consistente: o mesmo movimento físico sempre vira o mesmo movimento na tela. Não afeta FPS.'
        Alvos     = @(
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed'; Valor = '0'; Tipo = 'String' }
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1'; Valor = '0'; Tipo = 'String' }
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2'; Valor = '0'; Tipo = 'String' }
        )
    })
    (New-Tweak @{
        Id        = 'VisualFX'
        Nome      = 'Efeitos visuais: melhor desempenho'
        Categoria = 'Sistema'
        Risco     = 'Moderado'
        Descricao = 'Configura os efeitos visuais do Windows para "melhor desempenho". Muda a aparência do Windows; vale a partir do próximo logon.'
        Efeito    = 'Libera CPU/GPU de animações e sombras do Windows; ajuda em PCs mais fracos.'
        Alvos     = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Valor = 2; Tipo = 'DWord' }
        )
    })
    (New-Tweak @{
        Id        = 'GpuPref'
        Nome      = 'Prioridade alta de GPU/CPU para jogos'
        Categoria = 'Sistema'
        Risco     = 'Moderado'
        Descricao = 'Ajusta o perfil multimídia do Windows para agendar jogos com prioridade de GPU 8 e CPU alta.'
        Efeito    = 'Jogos ganham prioridade no escalonador. Impacto debatível (depende da carga do PC), sem risco conhecido.'
        RequerAdmin = $true
        Alvos     = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'GPU Priority'; Valor = 8; Tipo = 'DWord' }
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Priority'; Valor = 6; Tipo = 'DWord' }
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Scheduling Category'; Valor = 'High'; Tipo = 'String' }
        )
    })
    (New-Tweak @{
        Id        = 'NetThrottle'
        Nome      = 'Remover limitação de rede para multimídia'
        Categoria = 'Rede'
        Risco     = 'Moderado'
        Descricao = 'Desativa o Network Throttling do Windows (que limita pacotes/ms quando há multimídia rodando) e reduz a reserva de CPU para processos em segundo plano.'
        Efeito    = 'Pode reduzir lag em jogos online. Impacto debatível — medir antes/depois.'
        RequerAdmin = $true
        RequerReinicio = $true
        Alvos     = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Valor = -1; Tipo = 'DWord' }  # 0xFFFFFFFF = desativado
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'SystemResponsiveness'; Valor = 10; Tipo = 'DWord' }     # padrão é 20
        )
    })
    (New-Tweak @{
        Id        = 'Nagle'
        Nome      = 'Desativar algoritmo de Nagle (TCP)'
        Categoria = 'Rede'
        Risco     = 'Moderado'
        Descricao = 'Desliga o agrupamento de pacotes TCP nas interfaces de rede ativas (TcpAckFrequency=1, TCPNoDelay=1).'
        Efeito    = 'Reduz latência em jogos que usam TCP (ex.: LoL). Não afeta jogos UDP (CS2, Valorant). Debatível.'
        RequerAdmin = $true
        RequerReinicio = $true
        DetalhesTexto = @('Em cada interface de rede com IP ativo: TcpAckFrequency=1, TCPNoDelay=1 (originais salvos no backup)')
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
    })
    (New-Tweak @{
        Id        = 'PowerThrottle'
        Nome      = 'Desativar Power Throttling'
        Categoria = 'Energia'
        Risco     = 'Moderado'
        Descricao = 'Impede o Windows de reduzir o clock de processos que ele considera "em segundo plano".'
        Efeito    = 'Evita que overlays, anti-cheat e apps auxiliares percam desempenho. Aumenta consumo de energia.'
        RequerAdmin = $true
        RequerReinicio = $true
        Alvos     = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff'; Valor = 1; Tipo = 'DWord' }
        )
    })
    (New-Tweak @{
        Id        = 'WindowedOpt'
        Nome      = 'Otimizações para jogos em janela'
        Categoria = 'GPU'
        Risco     = 'Seguro'
        Descricao = 'Liga as "Otimizações para jogos em janela" do Windows 11 (modelo de apresentação moderno para janela/borderless).'
        Efeito    = 'Menor latência para quem joga em janela sem borda. Recurso oficial da Microsoft.'
        Alvos     = @(
            @{ Path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; Name = 'DirectXUserGlobalSettings'; Valor = 'SwapEffectUpgradeEnable=1;'; Tipo = 'String' }
        )
        Disponivel = {
            if ([Environment]::OSVersion.Version.Build -lt 22000) { 'requer Windows 11' } else { $null }
        }
    })
    (New-Tweak @{
        Id        = 'HAGS'
        Nome      = 'Agendamento de GPU por hardware (HAGS)'
        Categoria = 'GPU'
        Risco     = 'Avançado'
        Descricao = 'Liga o Hardware-Accelerated GPU Scheduling. Requer GPU dedicada com driver compatível e REINÍCIO. O ganho varia por hardware — meça antes/depois; em alguns sistemas piora.'
        Efeito    = 'Pode reduzir latência de frame em GPUs NVIDIA (GTX 10xx+) e AMD (RX 5000+) recentes.'
        RequerAdmin = $true
        RequerReinicio = $true
        Alvos     = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; Valor = 2; Tipo = 'DWord' }
        )
        Disponivel = {
            if ([Environment]::OSVersion.Version.Build -lt 19041) { return 'requer Windows 10 2004 ou superior' }
            $dgpu = @(Get-GpuInfo | Where-Object { $_.Vendor -in 'NVIDIA', 'AMD' -and -not $_.Integrada })
            if ($dgpu.Count -eq 0) { 'requer GPU dedicada NVIDIA/AMD (sem suporte confiável em GPU integrada)' } else { $null }
        }
    })
    (New-Tweak @{
        Id        = 'MPO'
        Nome      = 'Desativar Multi-Plane Overlay (MPO)'
        Categoria = 'GPU'
        Risco     = 'Avançado'
        Descricao = 'Desliga o MPO do compositor do Windows. Correção conhecida (recomendada pela própria NVIDIA em KB) para stutter, flicker e tela preta com G-Sync/FreeSync e overlays. Se você NÃO tem esses sintomas, não aplique.'
        Efeito    = 'Elimina stutter/flicker causado por MPO em setups NVIDIA e AMD afetados.'
        RequerAdmin = $true
        RequerReinicio = $true
        Alvos     = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'; Name = 'OverlayTestMode'; Valor = 5; Tipo = 'DWord' }
        )
    })
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

function Get-TweakUnavailableReason {
    # $null = disponível; string = motivo de não se aplicar a esta máquina
    param([Parameter(Mandatory)]$Tweak)
    if ($Tweak.Disponivel) {
        try { return (& $Tweak.Disponivel) } catch { return $null }
    }
    $null
}

function Get-TweakDetail {
    # Linhas "chave: valor atual → valor novo" para a tela de transparência
    param([Parameter(Mandatory)]$Tweak)
    $lines = @()
    if ($Tweak.DetalhesTexto) { $lines += $Tweak.DetalhesTexto }
    if ($Tweak.Alvos) {
        foreach ($a in $Tweak.Alvos) {
            $cur = Get-RegValueInfo -Path $a.Path -Name $a.Name
            $curTxt = if ($cur.Existed) { "$($cur.Value)" } else { '(ausente)' }
            $shortPath = $a.Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
            $lines += "$shortPath\$($a.Name):  $curTxt  →  $($a.Valor)"
        }
    }
    $lines
}

function Test-TweakApplied {
    param([Parameter(Mandatory)]$Tweak)
    try {
        if ($Tweak.Test) { return [bool](& $Tweak.Test) }
        foreach ($a in $Tweak.Alvos) {
            $cur = Get-RegValueInfo -Path $a.Path -Name $a.Name
            if (-not $cur.Existed -or "$($cur.Value)" -ne "$($a.Valor)") { return $false }
        }
        return $true
    } catch { return $false }
}

function Invoke-Tweak {
    param([Parameter(Mandatory)]$Tweak)
    $reason = Get-TweakUnavailableReason -Tweak $Tweak
    if ($reason) { throw "'$($Tweak.Id)' indisponível nesta máquina: $reason" }
    if ($Tweak.RequerAdmin -and -not (Test-IsAdmin)) {
        throw "'$($Tweak.Id)' precisa de PowerShell como Administrador."
    }
    if ($Tweak.Apply) {
        & $Tweak.Apply
    } else {
        foreach ($a in $Tweak.Alvos) {
            Set-RegValueBacked -Path $a.Path -Name $a.Name -Value $a.Valor -Type $a.Tipo
        }
    }
    Write-OptLog "APLICADO: $($Tweak.Id) — $($Tweak.Nome)"
}

function Undo-Tweak {
    param([Parameter(Mandatory)]$Tweak)
    if ($Tweak.RequerAdmin -and -not (Test-IsAdmin)) {
        throw "'$($Tweak.Id)' precisa de PowerShell como Administrador para reverter."
    }
    if ($Tweak.Revert) {
        & $Tweak.Revert
    } else {
        foreach ($a in $Tweak.Alvos) {
            Restore-RegValueBacked -Path $a.Path -Name $a.Name
        }
    }
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
