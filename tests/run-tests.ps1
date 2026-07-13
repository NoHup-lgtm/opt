# run-tests.ps1 — testes do motor do Optimizer.
#
# Sem dependência de Pester (o Windows traz o 3.4, o CI traz o 5 — sintaxes
# incompatíveis). Runner próprio: PASS/FAIL por asserção, exit 1 se algo falhar.
#
# Seguro para rodar em qualquer máquina: usa só uma chave descartável em
# HKCU:\Software\_OptimizerSelfTest e redireciona os dados do app para %TEMP%.
# NÃO aplica nenhum tweak real.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'mvp-powershell\OptimizerCore.ps1')

# Redireciona dados do app (não polui %LOCALAPPDATA%\Optimizer nem o backup real)
$testRoot = Join-Path $env:TEMP ('opt-tests-' + [guid]::NewGuid().ToString('N'))
$script:DataDir    = $testRoot
$script:BackupFile = Join-Path $testRoot 'backup.json'
$script:LogFile    = Join-Path $testRoot 'optimizer.log'
Initialize-Optimizer

$script:Pass = 0
$script:Fail = 0

function Assert {
    param([bool]$Cond, [string]$Name)
    if ($Cond) {
        $script:Pass++
        Write-Host "  [ok]   $Name" -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
    }
}

function Assert-Throws {
    param([scriptblock]$Block, [string]$Name)
    $threw = $false
    try { & $Block } catch { $threw = $true }
    Assert $threw $Name
}

$testKey = 'HKCU:\Software\_OptimizerSelfTest'
if (Test-Path $testKey) { Remove-Item $testKey -Recurse -Force }
New-Item -Path $testKey -Force | Out-Null

try {

# ---------------------------------------------------------------------------
Write-Host "`n== Integridade do catálogo ==" -ForegroundColor Cyan

$tweaks = @(Get-Tweaks)
Assert ($tweaks.Count -ge 14) "catálogo tem >= 14 tweaks (tem $($tweaks.Count))"
Assert ((@($tweaks.Id | Select-Object -Unique)).Count -eq $tweaks.Count) 'ids são únicos'

foreach ($t in $tweaks) {
    $okRisco = $t.Risco -in 'Seguro', 'Moderado', 'Avançado'
    $okCampos = $t.Id -and $t.Nome -and $t.Categoria -and $t.Descricao -and $t.Efeito
    $okAcoes = ($t.Alvos) -or ($t.Apply -and $t.Revert -and $t.Test)
    Assert ($okRisco -and $okCampos -and $okAcoes) "$($t.Id): campos, risco e ações válidos"

    # Transparência: todo tweak precisa conseguir dizer o que muda
    Assert (@(Get-TweakDetail -Tweak $t).Count -ge 1) "$($t.Id): Get-TweakDetail retorna >= 1 linha"

    if ($t.Alvos) {
        $okAlvos = $true
        $precisaAdmin = $false
        foreach ($a in $t.Alvos) {
            if (-not ($a.Path -and $a.Name -and $null -ne $a.Valor -and $a.Tipo)) { $okAlvos = $false }
            if ($a.Tipo -notin 'DWord', 'QWord', 'String', 'MultiString', 'ExpandString', 'Binary') { $okAlvos = $false }
            if ($a.Path -like 'HKLM:*') { $precisaAdmin = $true }
        }
        Assert $okAlvos "$($t.Id): alvos bem formados"
        if ($precisaAdmin) {
            Assert ([bool]$t.RequerAdmin) "$($t.Id): alvo HKLM exige RequerAdmin=true"
        }
    }
}

# ---------------------------------------------------------------------------
Write-Host "`n== Camada de backup/revert ==" -ForegroundColor Cyan

# Valor existente: backup -> apply -> reaplicar (não sobrescreve backup) -> restore
Set-ItemProperty -Path $testKey -Name 'Existente' -Value 42 -Type DWord
Set-RegValueBacked -Path $testKey -Name 'Existente' -Value 99 -Type DWord
Set-RegValueBacked -Path $testKey -Name 'Existente' -Value 77 -Type DWord
Restore-RegValueBacked -Path $testKey -Name 'Existente'
Assert ((Get-ItemProperty $testKey).Existente -eq 42) 'valor existente restaurado ao original (reaplicar não sobrescreve backup)'

# Valor inexistente: apply -> restore remove
Set-RegValueBacked -Path $testKey -Name 'Novo' -Value 1 -Type DWord
Restore-RegValueBacked -Path $testKey -Name 'Novo'
Assert (-not ((Get-Item $testKey).GetValueNames() -contains 'Novo')) 'valor que não existia é removido no restore'

# Persistência: recarregar backup.json do disco (simula fechar/abrir o app)
Set-ItemProperty -Path $testKey -Name 'Persist' -Value 'original' -Type String
Set-RegValueBacked -Path $testKey -Name 'Persist' -Value 'mudado' -Type String
Initialize-Optimizer
Restore-RegValueBacked -Path $testKey -Name 'Persist'
Assert ((Get-ItemProperty $testKey).Persist -eq 'original') 'backup sobrevive a reinício do app (persistência em disco)'

# Chave que sumiu (ex.: placa de rede trocada): restore recria valor original
Set-ItemProperty -Path "$testKey\Sub" -Name 'X' -Value 7 -Type DWord -ErrorAction SilentlyContinue
if (-not (Test-Path "$testKey\Sub")) { New-Item -Path "$testKey\Sub" -Force | Out-Null; Set-ItemProperty -Path "$testKey\Sub" -Name 'X' -Value 7 -Type DWord }
Set-RegValueBacked -Path "$testKey\Sub" -Name 'X' -Value 99 -Type DWord
Remove-Item "$testKey\Sub" -Recurse -Force
Restore-RegValueBacked -Path "$testKey\Sub" -Name 'X'
Assert ((Get-ItemProperty "$testKey\Sub").X -eq 7) 'restore recria chave apagada com o valor original'

# Backup vazio ao final
Assert ($script:Backup.Count -eq 0) 'backup vazio depois de restaurar tudo'

# Escrita atômica: sem .tmp órfão e JSON válido
Assert (-not (Test-Path "$script:BackupFile.tmp")) 'sem arquivo .tmp órfão após salvar'
$null = Get-Content $script:BackupFile -Raw | ConvertFrom-Json
Assert $true 'backup.json é JSON válido'

# ---------------------------------------------------------------------------
Write-Host "`n== Verificação pós-apply ==" -ForegroundColor Cyan

$good = New-Tweak @{
    Id = '_TestOk'; Nome = 't'; Categoria = 'Teste'; Risco = 'Seguro'; Descricao = 'd'; Efeito = 'e'
    Alvos = @(@{ Path = $testKey; Name = 'VerifyMe'; Valor = 123; Tipo = 'DWord' })
}
Invoke-Tweak -Tweak $good
Assert (Test-TweakApplied -Tweak $good) 'tweak aplicado passa na verificação'
Undo-Tweak -Tweak $good
Assert (-not ((Get-Item $testKey).GetValueNames() -contains 'VerifyMe')) 'undo do tweak remove o valor'

# Apply que não surte efeito (simula GPO/antivírus bloqueando) tem que FALHAR alto
$bad = New-Tweak @{
    Id = '_TestBloqueado'; Nome = 't'; Categoria = 'Teste'; Risco = 'Seguro'; Descricao = 'd'; Efeito = 'e'
    Apply = { }; Revert = { }; Test = { $false }
}
Assert-Throws { Invoke-Tweak -Tweak $bad } 'apply sem efeito real lança erro (nada de sucesso falso)'

# Tweak indisponível não pode ser aplicado
$navl = New-Tweak @{
    Id = '_TestIndisp'; Nome = 't'; Categoria = 'Teste'; Risco = 'Seguro'; Descricao = 'd'; Efeito = 'e'
    Alvos = @(@{ Path = $testKey; Name = 'Nunca'; Valor = 1; Tipo = 'DWord' })
    Disponivel = { 'não se aplica a esta máquina' }
}
Assert-Throws { Invoke-Tweak -Tweak $navl } 'tweak indisponível recusa apply'

# ---------------------------------------------------------------------------
Write-Host "`n== Trava entre instâncias ==" -ForegroundColor Cyan

$coreText = [IO.File]::ReadAllText((Join-Path $repoRoot 'mvp-powershell\OptimizerCore.ps1'), [Text.Encoding]::UTF8)

Enter-OptimizerLock 1000
$ps = [powershell]::Create()
[void]$ps.AddScript({ param($core) Invoke-Expression $core; try { Enter-OptimizerLock 300; 'acquired' } catch { 'blocked' } }).AddArgument($coreText)
$r1 = $ps.Invoke(); $ps.Dispose()
Assert ("$r1" -eq 'blocked') 'segunda instância é bloqueada enquanto a trava está ativa'

Exit-OptimizerLock
$ps = [powershell]::Create()
[void]$ps.AddScript({ param($core) Invoke-Expression $core; try { Enter-OptimizerLock 300; 'acquired' } catch { 'blocked' } }).AddArgument($coreText)
$r2 = $ps.Invoke(); $ps.Dispose()
Assert ("$r2" -eq 'acquired') 'trava liberada permite nova instância'

# ---------------------------------------------------------------------------
Write-Host "`n== Perfis de jogo (data-driven) ==" -ForegroundColor Cyan

$script:ProfilesDir = Join-Path $repoRoot 'profiles'
$profiles = @(Get-GameProfiles)
Assert ($profiles.Count -ge 8) "profiles/ carrega >= 8 perfis (tem $($profiles.Count))"
Assert ((@($profiles.id | Select-Object -Unique)).Count -eq $profiles.Count) 'ids de perfil são únicos'

$tweakIds = @(Get-Tweaks).Id
foreach ($p in $profiles) {
    Assert ([bool]($p.id -and $p.nome -and $p.detect)) "$($p.id): campos obrigatórios (id/nome/detect)"
    $temDeteccao = ($p.detect.PSObject.Properties['processo'] -and $p.detect.processo) -or
                   ($p.detect.PSObject.Properties['caminhos'] -and @($p.detect.caminhos).Count -gt 0)
    Assert $temDeteccao "$($p.id): tem ao menos um critério de detecção"
    $desconhecidos = @($p.sistema | Where-Object { $_ -notin $tweakIds })
    Assert ($desconhecidos.Count -eq 0) "$($p.id): todos os tweaks do perfil existem no catálogo$(if ($desconhecidos) { ' (desconhecidos: ' + ($desconhecidos -join ',') + ')' })"
    # Detecção não pode lançar erro em máquina sem o jogo
    $null = Test-GameInstalled -Profile $p
    $null = Test-GameRunning -Profile $p
    Assert $true "$($p.id): detecção roda sem erro"
    # Ações porJogo bem formadas (tipos conhecidos + campos obrigatórios)
    foreach ($a in @($p.porJogo)) {
        $okA = switch ("$($a.tipo)") {
            'iniEdit' { [bool]($a.arquivo -and $a.chave -and $null -ne $a.valor) }
            'gpuPref' { @($a.exes).Count -gt 0 }
            default   { $false }
        }
        Assert $okA "$($p.id): ação porJogo válida ($($a.tipo))"
    }
}

# index.json (usado pelo get.ps1) tem que listar exatamente os perfis existentes
# -InputObject (não pipeline): no PS 5.1 o pipeline entrega o array JSON como
# objeto único e o @() aninharia errado
$index = @([string[]](ConvertFrom-Json -InputObject (Get-Content (Join-Path $script:ProfilesDir 'index.json') -Raw -Encoding UTF8)))
$onDisk = @(Get-ChildItem (Join-Path $script:ProfilesDir '*.json') | Where-Object { $_.Name -ne 'index.json' } | ForEach-Object { $_.Name })
$soNoIndex = @($index | Where-Object { $_ -notin $onDisk })
$soNoDisco = @($onDisk | Where-Object { $_ -notin $index })
Assert ($soNoIndex.Count -eq 0 -and $soNoDisco.Count -eq 0) "index.json sincronizado com profiles/ $(if ($soNoIndex) { '(faltando no disco: ' + ($soNoIndex -join ',') + ')' })$(if ($soNoDisco) { '(faltando no index: ' + ($soNoDisco -join ',') + ')' })"

# ---------------------------------------------------------------------------
Write-Host "`n== Ações por jogo (iniEdit / gpuPref / backup de arquivo) ==" -ForegroundColor Cyan

# Set-IniValue: substituir, adicionar em seção existente, criar seção nova
$ini = Join-Path $testRoot 'teste.ini'
@('[Video]', 'Quality=3', 'VSync=1', '', '[Audio]', 'Volume=10') | Set-Content -Path $ini -Encoding ASCII
Set-IniValue -Path $ini -Section 'Video' -Key 'Quality' -Value '0'
Assert ((Get-Content $ini) -contains 'Quality=0') 'iniEdit substitui chave existente na seção'
Set-IniValue -Path $ini -Section 'Video' -Key 'FpsMax' -Value '240'
$content = Get-Content $ini
$vIdx = [array]::IndexOf($content, '[Video]'); $aIdx = [array]::IndexOf($content, '[Audio]')
$fIdx = [array]::IndexOf($content, 'FpsMax=240')
Assert ($fIdx -gt $vIdx -and $fIdx -lt $aIdx) 'iniEdit adiciona chave nova DENTRO da seção certa'
Set-IniValue -Path $ini -Section 'Rede' -Key 'Nagle' -Value 'off'
Assert (((Get-Content $ini) -contains '[Rede]') -and ((Get-Content $ini) -contains 'Nagle=off')) 'iniEdit cria seção nova quando não existe'
Assert ((Get-Content $ini) -contains 'Volume=10') 'iniEdit preserva o resto do arquivo'

# Backup de arquivo: original preservado, restore volta byte a byte
$original = Get-Content $ini -Raw
$acao = [pscustomobject]@{ tipo = 'iniEdit'; arquivo = $ini; secao = 'Video'; chave = 'Quality'; valor = '9' }
$res = Invoke-GameAction -Action $acao
Assert ("$res" -like 'ok*') "ação iniEdit aplica e retorna ok ($res)"
Assert ((Get-Content $ini) -contains 'Quality=9') 'ação iniEdit alterou o arquivo'
Restore-FileBacked -Path $ini
Assert ((Get-Content $ini -Raw) -eq $original) 'restore de arquivo volta EXATAMENTE ao original'
Assert (-not $script:Backup.ContainsKey("file|$ini")) 'entrada de backup de arquivo removida após restore'

# iniEdit com arquivo inexistente = pulado (jogo nunca aberto), nunca erro
$res = Invoke-GameAction -Action ([pscustomobject]@{ tipo = 'iniEdit'; arquivo = (Join-Path $testRoot 'nao-existe.ini'); chave = 'x'; valor = '1' })
Assert ("$res" -like 'pulado*') "iniEdit sem arquivo é pulado com aviso ($res)"

# gpuPref com exe inexistente = pulado (nunca escreve lixo no registro)
$res = Invoke-GameAction -Action ([pscustomobject]@{ tipo = 'gpuPref'; exes = @('C:\jogo\que\nao\existe.exe') })
Assert ("$res" -like 'pulado*') "gpuPref sem exe/GPU híbrida é pulado ($res)"

# tipo desconhecido = pulado (perfil JSON futuro não pode quebrar app antigo)
$res = Invoke-GameAction -Action ([pscustomobject]@{ tipo = 'foo' })
Assert ("$res" -like 'pulado*') 'tipo de ação desconhecido é pulado sem quebrar'

# ---------------------------------------------------------------------------
Write-Host "`n== Ambiente e diagnóstico ==" -ForegroundColor Cyan

$sre = Test-SystemRestoreEnabled
Assert ($sre -is [bool]) "Test-SystemRestoreEnabled retorna bool (aqui: $sre)"

Assert (@(Get-GpuInfo).Count -ge 0) 'Get-GpuInfo não lança erro'

$zip = Export-OptimizerDiagnostic -OutDir $testRoot
Assert (Test-Path $zip) 'diagnóstico exportado gera .zip'

} finally {
    if (Test-Path $testKey) { Remove-Item $testKey -Recurse -Force }
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 50)
Write-Host "PASS: $script:Pass   FAIL: $script:Fail" -ForegroundColor $(if ($script:Fail -gt 0) { 'Red' } else { 'Green' })
if ($script:Fail -gt 0) { exit 1 }
exit 0
