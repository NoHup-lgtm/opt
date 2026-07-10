# build.ps1 — gera um .ps1 único (Core embutido) e, se o módulo ps2exe estiver
# instalado, compila para dist\Optimizer.exe.
#
# Instalar o ps2exe (uma vez):  Install-Module ps2exe -Scope CurrentUser

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }

$core = Get-Content (Join-Path $root 'OptimizerCore.ps1') -Raw -Encoding UTF8
$app  = Get-Content (Join-Path $root 'OptimizerApp.ps1')  -Raw -Encoding UTF8

# Injeta o texto do Core no marcador (o .exe precisa ser um arquivo só; o App
# usa $script:CoreText tanto para si quanto para os jobs em background)
$marker = '# ==CORE-INJECT=='
if (-not $app.Contains($marker)) { throw "Marcador '$marker' não encontrado em OptimizerApp.ps1 — build desatualizado." }
$inject = "`$script:CoreText = @'`n$core`n'@"
$merged = $app.Replace($marker, $inject)

$mergedPath = Join-Path $dist 'OptimizerApp.merged.ps1'
[IO.File]::WriteAllText($mergedPath, $merged, (New-Object Text.UTF8Encoding $true))
Write-Host "Gerado: $mergedPath"

if (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue) {
    $exePath = Join-Path $dist 'Optimizer.exe'
    Invoke-PS2EXE -InputFile $mergedPath -OutputFile $exePath -NoConsole -RequireAdmin -Title 'Optimizer' -STA
    Write-Host "Gerado: $exePath"
    Write-Host 'Lembrete: para distribuir, assinar o .exe com certificado de code signing (regra 7 do CLAUDE.md).'
} else {
    Write-Warning 'Módulo ps2exe não encontrado — só o .ps1 mesclado foi gerado. Instale com: Install-Module ps2exe -Scope CurrentUser'
}
