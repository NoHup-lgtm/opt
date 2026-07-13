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
$script:Mutex      = $null
$script:ProfilesDir = $null   # definido pela CLI/GUI após carregar o Core (layout repo vs instalado)

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
    # Escrita atômica: grava em .tmp e renomeia por cima (rename é atômico no NTFS).
    # Um crash no meio da gravação nunca pode corromper o backup — ele é a única
    # garantia de revert.
    $json = if ($script:Backup.Count -eq 0) { '{}' } else { $script:Backup | ConvertTo-Json -Depth 6 }
    $tmp = "$script:BackupFile.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $true))
    Move-Item -Path $tmp -Destination $script:BackupFile -Force
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
# Trava entre instâncias — CLI e GUI rodando juntos não podem escrever no
# backup ao mesmo tempo. Cross-process via mutex nomeado.
# ---------------------------------------------------------------------------

function Enter-OptimizerLock {
    param([int]$TimeoutMs = 5000)
    if ($script:Mutex) { return }   # esta instância já detém a trava
    $m = $null
    try { $m = New-Object Threading.Mutex($false, 'Global\OptimizerEngineLock') }
    catch { $m = New-Object Threading.Mutex($false, 'Local\OptimizerEngineLock') }
    $got = $false
    try { $got = $m.WaitOne($TimeoutMs) }
    catch [Threading.AbandonedMutexException] { $got = $true }   # o dono anterior morreu — a trava é nossa
    if (-not $got) {
        $m.Dispose()
        throw 'Outra instância do Optimizer está aplicando alterações agora. Aguarde ela terminar e tente de novo.'
    }
    $script:Mutex = $m
}

function Exit-OptimizerLock {
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:Mutex.Dispose()
        $script:Mutex = $null
    }
}

# ---------------------------------------------------------------------------
# System Restore — a regra 2 exige ponto de restauração antes de aplicar,
# mas muitos PCs vêm com o System Restore desligado de fábrica. Detectar
# ANTES de aplicar, em vez de deixar o Checkpoint-Computer falhar em silêncio.
# ---------------------------------------------------------------------------

function Test-SystemRestoreEnabled {
    # GPO pode desabilitar (DisableSR=1); fora isso, RPSessionInterval>=1 indica ativo.
    $gpo = Get-RegValueInfo -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR'
    if ($gpo.Existed -and $gpo.Value -eq 1) { return $false }
    $sr = Get-RegValueInfo -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval'
    return [bool]($sr.Existed -and $sr.Value -ge 1)
}

function Enable-SystemRestoreOnSystemDrive {
    Enable-ComputerRestore -Drive "$env:SystemDrive\"
    Write-OptLog "System Restore ativado em $env:SystemDrive\"
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
# Perfis de jogo (Fase 4 — data-driven): um JSON por jogo em profiles/.
# Adicionar um jogo = soltar um JSON novo, SEM tocar em código.
# ---------------------------------------------------------------------------

function Get-GameProfiles {
    if (-not $script:ProfilesDir -or -not (Test-Path $script:ProfilesDir)) { return @() }
    $out = @()
    foreach ($f in (Get-ChildItem -Path (Join-Path $script:ProfilesDir '*.json') | Where-Object { $_.Name -ne 'index.json' })) {
        try {
            $p = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($p.id -and $p.nome -and $p.detect) { $out += $p }
            else { Write-OptLog "perfil inválido (sem id/nome/detect): $($f.Name)" 'WARN' }
        } catch {
            Write-OptLog "perfil ilegível: $($f.Name) — $_" 'WARN'
        }
    }
    $out
}

function Test-GameInstalled {
    param([Parameter(Mandatory)]$Profile)
    if ($Profile.detect.PSObject.Properties['caminhos']) {
        foreach ($c in @($Profile.detect.caminhos)) {
            if ($c -and (Test-Path ([Environment]::ExpandEnvironmentVariables($c)))) { return $true }
        }
    }
    if ($Profile.detect.PSObject.Properties['registro']) {
        foreach ($r in @($Profile.detect.registro)) {
            if ($r -and (Test-Path $r)) { return $true }
        }
    }
    $false
}

function Test-GameRunning {
    param([Parameter(Mandatory)]$Profile)
    if (-not $Profile.detect.PSObject.Properties['processo'] -or -not $Profile.detect.processo) { return $false }
    $name = [IO.Path]::GetFileNameWithoutExtension($Profile.detect.processo)
    [bool](Get-Process -Name $name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Backup de ARQUIVO (para as ações por jogo que editam .ini/.cfg).
# Mesma regra do registro: o original é salvo UMA vez, antes da 1ª edição.
# ---------------------------------------------------------------------------

function Backup-FileOnce {
    param([Parameter(Mandatory)][string]$Path)
    $key = "file|$Path"
    if ($script:Backup.ContainsKey($key)) { return }
    $dir = Join-Path $script:DataDir 'filebackups'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dest = Join-Path $dir ('{0:x8}.{1}' -f [math]::Abs($Path.ToLower().GetHashCode()), [IO.Path]::GetFileName($Path))
    Copy-Item -Path $Path -Destination $dest -Force
    $script:Backup[$key] = @{ kind = 'file'; path = $Path; backupPath = $dest; savedAt = (Get-Date).ToString('s') }
    Save-OptimizerBackup
    Write-OptLog "BACKUP arquivo $Path -> $dest"
}

function Restore-FileBacked {
    param([Parameter(Mandatory)][string]$Path)
    $key = "file|$Path"
    if (-not $script:Backup.ContainsKey($key)) { return }
    $b = $script:Backup[$key]
    if (Test-Path $b.backupPath) {
        Copy-Item -Path $b.backupPath -Destination $Path -Force
        Write-OptLog "RESTORE arquivo $Path"
    }
    $script:Backup.Remove($key)
    Save-OptimizerBackup
}

function Set-IniValue {
    # Edita chave=valor num arquivo estilo INI, preservando o resto do conteúdo.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in [IO.File]::ReadAllLines($Path)) { $lines.Add($l) }
    $kv = "$Key=$Value"
    $keyRe = '^\s*' + [regex]::Escape($Key) + '\s*='
    if ($Section) {
        $secRe = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
        $secIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $secRe) { $secIdx = $i; break } }
        if ($secIdx -lt 0) {
            $lines.Add("[$Section]")
            $lines.Add($kv)
        } else {
            $end = $lines.Count
            for ($i = $secIdx + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[') { $end = $i; break } }
            $found = $false
            for ($i = $secIdx + 1; $i -lt $end; $i++) { if ($lines[$i] -match $keyRe) { $lines[$i] = $kv; $found = $true; break } }
            if (-not $found) { $lines.Insert($end, $kv) }
        }
    } else {
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $keyRe) { $lines[$i] = $kv; $found = $true; break } }
        if (-not $found) { $lines.Add($kv) }
    }
    [IO.File]::WriteAllLines($Path, $lines)
    Write-OptLog "INI $Path $(if ($Section) { "[$Section] " })$kv"
}

# ---------------------------------------------------------------------------
# Ações por jogo (camada 2 do modelo de dados — vêm do JSON, nunca do código).
# Tipos suportados:
#   gpuPref — força o jogo na GPU dedicada (só em máquina híbrida dedicada+integrada)
#   iniEdit — edita chave em .ini/.cfg do jogo (original vai para o backup de arquivo)
# Retornam 'ok: ...' ou 'pulado: motivo'; erro real = exception.
# ---------------------------------------------------------------------------

$script:GpuPrefRegKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'

function Invoke-GameAction {
    param([Parameter(Mandatory)]$Action)
    switch ("$($Action.tipo)") {
        'gpuPref' {
            $gpus = @(Get-GpuInfo)
            $hybrid = (@($gpus | Where-Object { $_.Integrada }).Count -gt 0) -and
                      (@($gpus | Where-Object { -not $_.Integrada }).Count -gt 0)
            if (-not $hybrid) { return 'pulado: PC não tem GPU híbrida (dedicada + integrada) — o Windows já usa a única GPU' }
            $exe = $null
            foreach ($c in @($Action.exes)) {
                $p = [Environment]::ExpandEnvironmentVariables($c)
                if ($p -and (Test-Path $p)) { $exe = $p; break }
            }
            if (-not $exe) { return 'pulado: executável do jogo não encontrado' }
            Set-RegValueBacked -Path $script:GpuPrefRegKey -Name $exe -Value 'GpuPreference=2;' -Type String
            return "ok: GPU dedicada forçada para $([IO.Path]::GetFileName($exe))"
        }
        'iniEdit' {
            $file = [Environment]::ExpandEnvironmentVariables($Action.arquivo)
            if (-not (Test-Path $file)) { return 'pulado: arquivo de config não existe (abra o jogo uma vez antes)' }
            Backup-FileOnce -Path $file
            $sec = if ($Action.PSObject.Properties['secao']) { $Action.secao } else { $null }
            Set-IniValue -Path $file -Section $sec -Key $Action.chave -Value $Action.valor
            return "ok: $($Action.chave)=$($Action.valor)"
        }
        default { return "pulado: tipo de ação desconhecido '$($Action.tipo)'" }
    }
}

function Undo-GameActions {
    param([Parameter(Mandatory)]$Profile)
    foreach ($a in @($Profile.porJogo)) {
        switch ("$($a.tipo)") {
            'gpuPref' {
                foreach ($c in @($a.exes)) {
                    $p = [Environment]::ExpandEnvironmentVariables($c)
                    if ($p) { Restore-RegValueBacked -Path $script:GpuPrefRegKey -Name $p }
                }
            }
            'iniEdit' {
                Restore-FileBacked -Path ([Environment]::ExpandEnvironmentVariables($a.arquivo))
            }
        }
    }
    Write-OptLog "Ações por jogo de '$($Profile.id)' revertidas."
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
        Nome      = 'Plano de energia: Ultimate / Alto Desempenho'
        Categoria = 'Energia'
        Risco     = 'Seguro'
        Descricao = 'Cria e ativa o plano Ultimate Performance (oculto pela Microsoft no Windows Home); se não der, cai para Alto Desempenho. O plano anterior fica salvo no backup e o plano criado é apagado no revert.'
        Efeito    = 'CPU não reduz clock em micro-pausas; melhora consistência de frametime.'
        DetalhesTexto = @('powercfg -duplicatescheme (Ultimate Performance) + /setactive — plano anterior salvo no backup; o plano criado é apagado no revert')
        Apply = {
            $key = 'powercfg|activescheme'
            if (-not $script:Backup.ContainsKey($key)) {
                $script:Backup[$key] = @{ kind = 'powercfg'; value = (Get-ActivePowerScheme); savedAt = (Get-Date).ToString('s') }
                Save-OptimizerBackup
            }
            $ukey = 'powercfg|ultimatescheme'
            if (-not $script:Backup.ContainsKey($ukey)) {
                $out = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
                if ("$out" -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                    $script:Backup[$ukey] = @{ kind = 'powercfg-created'; value = $Matches[1]; savedAt = (Get-Date).ToString('s') }
                    Save-OptimizerBackup
                    Write-OptLog "Plano Ultimate Performance criado: $($Matches[1])"
                }
            }
            $target = if ($script:Backup.ContainsKey($ukey)) { $script:Backup[$ukey].value } else { $script:HighPerfGuid }
            powercfg /setactive $target
            if ($LASTEXITCODE -ne 0) { powercfg /setactive SCHEME_MIN | Out-Null }
            Write-OptLog "POWERCFG setactive $target"
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
            $ukey = 'powercfg|ultimatescheme'
            if ($script:Backup.ContainsKey($ukey)) {
                try { powercfg /delete $script:Backup[$ukey].value | Out-Null } catch { }
                $script:Backup.Remove($ukey)
                Save-OptimizerBackup
                Write-OptLog 'Plano Ultimate criado pelo app foi removido.'
            }
        }
        Test = {
            $active = Get-ActivePowerScheme
            $ukey = 'powercfg|ultimatescheme'
            ($active -eq $script:HighPerfGuid) -or ($script:Backup.ContainsKey($ukey) -and $active -eq $script:Backup[$ukey].value)
        }
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
        Id        = 'Transparency'
        Nome      = 'Desativar transparência do Windows'
        Categoria = 'Sistema'
        Risco     = 'Seguro'
        Descricao = 'Desliga os efeitos de transparência/acrílico da interface do Windows.'
        Efeito    = 'Menos trabalho de GPU na interface; ajuda PCs fracos e notebooks. Complementa o VisualFX.'
        Alvos     = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Valor = 0; Tipo = 'DWord' }
        )
    })
    (New-Tweak @{
        Id        = 'StickyKeys'
        Nome      = 'Desativar popups de acessibilidade (Shift 5x)'
        Categoria = 'Entrada'
        Risco     = 'Seguro'
        Descricao = 'Desativa os atalhos e popups de Teclas de Aderência, Alternância e Filtragem que roubam o foco no meio da partida. Não afeta FPS.'
        Efeito    = 'Nunca mais perder uma luta porque o Windows abriu popup de acessibilidade.'
        Alvos     = @(
            @{ Path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Valor = '506'; Tipo = 'String' }
            @{ Path = 'HKCU:\Control Panel\Accessibility\ToggleKeys'; Name = 'Flags'; Valor = '58'; Tipo = 'String' }
            @{ Path = 'HKCU:\Control Panel\Accessibility\Keyboard Response'; Name = 'Flags'; Valor = '122'; Tipo = 'String' }
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
            if ($touched -eq 0) { throw 'nenhuma interface de rede com IP ativo encontrada' }
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
    # Verificação pós-apply: escrever sem erro não basta — GPO, Tamper Protection
    # ou o driver podem rejeitar/reverter o valor silenciosamente.
    if (-not (Test-TweakApplied -Tweak $Tweak)) {
        throw "'$($Tweak.Id)' foi escrito mas o sistema não confirmou o novo valor (GPO ou antivírus podem ter bloqueado)."
    }
    Write-OptLog "APLICADO e verificado: $($Tweak.Id) — $($Tweak.Nome)"
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
        } elseif ($b.kind -eq 'file') {
            try { Restore-FileBacked -Path $b.path } catch { Write-OptLog "Falha restaurando arquivo ${key}: $_" 'ERROR' }
        }
    }
    Write-OptLog 'DESFAZER TUDO concluído.'
}

# ---------------------------------------------------------------------------
# Diagnóstico exportável (suporte na validação com usuários)
# ---------------------------------------------------------------------------

function Export-OptimizerDiagnostic {
    # Gera um .zip local com log, backup e estado do sistema. NADA é enviado
    # automaticamente — o usuário decide se manda o arquivo.
    param([string]$OutDir = [Environment]::GetFolderPath('Desktop'))
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $work = Join-Path $env:TEMP "opt-diag-$stamp"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $lines = @(
            "Optimizer — diagnóstico $stamp"
            "OS: $($os.Caption) build $($os.BuildNumber)"
            "PowerShell: $($PSVersionTable.PSVersion)"
            "Admin: $(Test-IsAdmin)"
            "System Restore ativo: $(Test-SystemRestoreEnabled)"
            "Plano de energia ativo: $(Get-ActivePowerScheme)"
            ''
            'GPUs:'
        )
        foreach ($g in @(Get-GpuInfo)) {
            $tipo = if ($g.Integrada) { 'integrada' } else { 'dedicada' }
            $lines += "  $($g.Name) [$($g.Vendor) · $tipo · driver $($g.Driver)]"
        }
        $lines += ''
        $lines += 'Tweaks:'
        foreach ($t in Get-Tweaks) {
            $st = if (Test-TweakApplied $t) { 'APLICADO' } else { '-' }
            $reason = Get-TweakUnavailableReason -Tweak $t
            if ($reason) { $st = "indisponível: $reason" }
            $lines += ('  {0,-14} {1,-9} {2}' -f $t.Id, $t.Risco, $st)
        }
        Set-Content -Path (Join-Path $work 'info.txt') -Value $lines -Encoding UTF8
        if (Test-Path $script:BackupFile) { Copy-Item $script:BackupFile (Join-Path $work 'backup.json') }
        if (Test-Path $script:LogFile) {
            Get-Content $script:LogFile -Tail 500 | Set-Content (Join-Path $work 'optimizer.log.txt') -Encoding UTF8
        }
        $zip = Join-Path $OutDir "Optimizer-diagnostico-$stamp.zip"
        Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force
        Write-OptLog "Diagnóstico exportado: $zip"
        return $zip
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
