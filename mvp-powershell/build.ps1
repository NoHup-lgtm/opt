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

# Perfis de jogo viajam junto do .exe (data-driven: o app lê .\profiles)
$profSrc = Join-Path (Split-Path $root -Parent) 'profiles'
if (Test-Path $profSrc) {
    $profDst = Join-Path $dist 'profiles'
    New-Item -ItemType Directory -Path $profDst -Force | Out-Null
    Copy-Item (Join-Path $profSrc '*.json') $profDst -Force
    Write-Host "Copiado: profiles\ ($(@(Get-ChildItem $profDst).Count) arquivos)"
}

if (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue) {
    $exePath = Join-Path $dist 'Optimizer.exe'
    Invoke-PS2EXE -InputFile $mergedPath -OutputFile $exePath -NoConsole -RequireAdmin -Title 'Optimizer' -STA
    Write-Host "Gerado: $exePath"

    # Assinatura (regra 7): defina OPT_CODESIGN_THUMBPRINT com o thumbprint do
    # certificado de code signing instalado em Cert:\CurrentUser\My.
    if ($env:OPT_CODESIGN_THUMBPRINT) {
        $cert = Get-Item "Cert:\CurrentUser\My\$($env:OPT_CODESIGN_THUMBPRINT)"
        $sig = Set-AuthenticodeSignature -FilePath $exePath -Certificate $cert `
            -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
        if ($sig.Status -ne 'Valid') { throw "Assinatura falhou: $($sig.StatusMessage)" }
        Write-Host "Assinado: $($cert.Subject)"
    } else {
        Write-Warning 'EXE NÃO ASSINADO — sem assinatura o SmartScreen/Defender vai bloquear na máquina do cliente. Ver docs/distribuicao.md.'
    }

    # Hash para publicar junto do download (o cliente confere a integridade)
    $hash = (Get-FileHash $exePath -Algorithm SHA256).Hash
    Set-Content -Path "$exePath.sha256.txt" -Value $hash -Encoding ASCII
    Write-Host "SHA256: $hash"
} else {
    Write-Warning 'Módulo ps2exe não encontrado — só o .ps1 mesclado foi gerado. Instale com: Install-Module ps2exe -Scope CurrentUser'
}
