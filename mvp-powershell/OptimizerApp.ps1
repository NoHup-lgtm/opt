# OptimizerApp.ps1 — painel WPF do Optimizer (MVP)
#
# Conceito visual: instrumento de diagnóstico de precisão (telemetria), NÃO "gamer RGB".
# Tokens de design: ver CLAUDE.md.
#
# Regra 3 (inviolável): o readout de telemetria NUNCA mostra número inventado.
# Ping e temperatura de GPU são medidos de verdade (ICMP / nvidia-smi);
# FPS e 1% low ficam em "—" até o PresentMon (Fase 2).

param(
    [switch]$NoElevate,   # não auto-elevar (uso em dev)
    [switch]$RenderTest   # monta a janela e sai sem exibir (teste de sanidade da UI)
)

$ErrorActionPreference = 'Stop'

# --- Elevação: os tweaks HKLM precisam de admin ---------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate -and -not $RenderTest) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -File `"$PSCommandPath`""
    exit
}

# WPF exige STA
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -File `"$PSCommandPath`" $(if ($NoElevate) {'-NoElevate'}) $(if ($RenderTest) {'-RenderTest'})" -Wait -NoNewWindow
    exit
}

# --- Motor -------------------------------------------------------------------
# O texto do Core fica em $script:CoreText para os jobs em background poderem
# recarregá-lo em runspaces próprios (e para o build .exe, que injeta o Core aqui).
# ==CORE-INJECT==
if (-not $script:CoreText) {
    $script:CoreText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OptimizerCore.ps1'), [Text.Encoding]::UTF8)
}
Invoke-Expression $script:CoreText
Initialize-Optimizer

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --- Tokens ----------------------------------------------------------------
$script:Tok = @{
    Bg      = '#0C1116'; Surface = '#131B22'; Surface2 = '#182229'
    Line    = '#233039'; Line2   = '#1B252D'
    Text    = '#E6EDF2'; Mute    = '#7C8D9A'; Dim = '#556571'
    Accent  = '#FF9432'; Gain    = '#4FD98A'; Risk = '#E85D5D'; Cold = '#4FC6D9'
}

function New-Brush([string]$Hex) {
    New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

$script:RiskColor = @{
    'Seguro'   = $Tok.Gain
    'Moderado' = $Tok.Accent
    'Avançado' = $Tok.Risk
}

# --- Janela (XAML) ----------------------------------------------------------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OPT — otimizador" Width="1020" Height="740"
        WindowStartupLocation="CenterScreen"
        Background="$($Tok.Bg)" FontFamily="Segoe UI">
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="130"/>
    </Grid.RowDefinitions>

    <!-- Cabeçalho -->
    <DockPanel Grid.Row="0" Margin="2,0,2,14">
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
        <TextBlock Text="OPT" FontFamily="Consolas" FontSize="22" FontWeight="Bold" Foreground="$($Tok.Accent)"/>
        <TextBlock Text="  otimizador · painel de controle" FontSize="13" Foreground="$($Tok.Mute)" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel DockPanel.Dock="Right" HorizontalAlignment="Right" Orientation="Horizontal">
        <TextBlock x:Name="GpuBadge" FontFamily="Consolas" FontSize="12" Foreground="$($Tok.Mute)" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <TextBlock x:Name="AdminBadge" FontFamily="Consolas" FontSize="12" Foreground="$($Tok.Dim)" VerticalAlignment="Center"/>
      </StackPanel>
    </DockPanel>

    <!-- Readout de telemetria: só número REAL ou "—" -->
    <Border Grid.Row="1" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line)" BorderThickness="1" CornerRadius="8" Padding="16,12" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="FPS MÉDIO" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)"/>
          <TextBlock x:Name="FpsVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
          <TextBlock x:Name="FpsSub" Text="PresentMon — Fase 2" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)"/>
        </StackPanel>
        <StackPanel Grid.Column="1">
          <TextBlock Text="1% LOW" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)"/>
          <TextBlock x:Name="LowVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
          <TextBlock x:Name="LowSub" Text="PresentMon — Fase 2" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="PING" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)"/>
          <TextBlock x:Name="PingVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
          <TextBlock x:Name="PingSub" Text="medindo..." FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)"/>
        </StackPanel>
        <StackPanel Grid.Column="3">
          <TextBlock Text="TEMP GPU" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)"/>
          <TextBlock x:Name="TempVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Cold)"/>
          <TextBlock x:Name="TempSub" Text="sem sensor legível" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Banner de resultado -->
    <Border Grid.Row="2" x:Name="Banner" Visibility="Collapsed" Background="$($Tok.Surface)" BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,0,0,12">
      <TextBlock x:Name="BannerText" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"/>
    </Border>

    <!-- Lista de tweaks -->
    <Border Grid.Row="3" Background="$($Tok.Surface2)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="8" Padding="10">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="TweaksPanel"/>
      </ScrollViewer>
    </Border>

    <!-- Ações -->
    <DockPanel Grid.Row="4" Margin="2,12,2,12">
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
        <CheckBox x:Name="RestoreChk" IsChecked="True" VerticalAlignment="Center" Foreground="$($Tok.Mute)" FontSize="12"
                  Content="Ponto de restauração antes de aplicar"/>
        <ProgressBar x:Name="Busy" IsIndeterminate="True" Width="110" Height="5" Margin="14,0,8,0" Visibility="Collapsed"
                     Background="$($Tok.Surface)" Foreground="$($Tok.Accent)" BorderThickness="0"/>
        <TextBlock x:Name="BusyText" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Accent)" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="RevertAllBtn" Content="DESFAZER TUDO" FontFamily="Consolas" FontSize="12" Padding="12,8" Margin="0,0,8,0"
                Background="$($Tok.Surface)" Foreground="$($Tok.Risk)" BorderBrush="$($Tok.Risk)"/>
        <Button x:Name="RevertBtn" Content="REVERTER SELEÇÃO" FontFamily="Consolas" FontSize="12" Padding="12,8" Margin="0,0,8,0"
                Background="$($Tok.Surface)" Foreground="$($Tok.Mute)" BorderBrush="$($Tok.Line)"/>
        <Button x:Name="ApplyBtn" Content="APLICAR SELEÇÃO" FontFamily="Consolas" FontSize="12" Padding="12,8" Margin="0,0,10,0"
                Background="$($Tok.Surface)" Foreground="$($Tok.Text)" BorderBrush="$($Tok.Line)"/>
        <Button x:Name="OptimizeBtn" Content="⚡ OTIMIZAR" FontFamily="Consolas" FontSize="13" FontWeight="Bold" Padding="22,8"
                Background="$($Tok.Accent)" Foreground="#0C1116" BorderBrush="$($Tok.Accent)"/>
      </StackPanel>
    </DockPanel>

    <!-- Log (transparência total: tudo que o app faz aparece aqui e no arquivo) -->
    <Border Grid.Row="5" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line)" BorderThickness="1" CornerRadius="8" Padding="8">
      <DockPanel>
        <TextBlock DockPanel.Dock="Top" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)" Margin="4,0,4,4"
                   Text="log — tudo que o app altera é registrado em %LOCALAPPDATA%\Optimizer\optimizer.log e é reversível"/>
        <TextBox x:Name="LogBox" IsReadOnly="True" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="11"
                 Background="Transparent" Foreground="$($Tok.Mute)" BorderThickness="0"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)

$script:Ui = @{}
foreach ($name in 'GpuBadge','AdminBadge','TweaksPanel','RestoreChk','ApplyBtn','RevertBtn','RevertAllBtn','OptimizeBtn',
                  'LogBox','Banner','BannerText','Busy','BusyText',
                  'FpsVal','FpsSub','LowVal','LowSub','PingVal','PingSub','TempVal','TempSub') {
    $script:Ui[$name] = $window.FindName($name)
}

$script:Ui.AdminBadge.Text = if (Test-IsAdmin) { '[ admin ]' } else { '[ sem admin — tweaks de sistema bloqueados ]' }

# GPU detectada no cabeçalho (informação real, base para os tweaks de GPU)
$gpu = Get-MainGpu
$script:Ui.GpuBadge.Text = if ($gpu) {
    $tipo = if ($gpu.Integrada) { 'integrada' } else { 'dedicada' }
    "[ $($gpu.Name) · $tipo ]"
} else { '[ GPU não detectada ]' }

# nvidia-smi disponível? (única leitura de temperatura de GPU confiável sem lib externa)
$script:NvSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($script:NvSmi) { $script:Ui.TempSub.Text = 'GPU · nvidia-smi · real' }

# --- Linhas de tweak (construídas em código a partir do catálogo) -----------
$script:Rows = @{}   # Id -> @{ Check; Dot; StatusText; Reason }

function Update-RowStatus {
    foreach ($t in Get-Tweaks) {
        $row = $script:Rows[$t.Id]
        if ($row.Reason) { continue }  # indisponível: estado fixo
        if (Test-TweakApplied $t) {
            $row.Dot.Fill = New-Brush $Tok.Gain
            $row.StatusText.Text = 'aplicado'
            $row.StatusText.Foreground = New-Brush $Tok.Gain
        } else {
            $row.Dot.Fill = New-Brush $Tok.Dim
            $row.StatusText.Text = '—'
            $row.StatusText.Foreground = New-Brush $Tok.Dim
        }
    }
}

foreach ($t in Get-Tweaks) {
    $reason = Get-TweakUnavailableReason -Tweak $t

    $border = New-Object Windows.Controls.Border
    $border.Background = New-Brush $Tok.Surface
    $border.BorderBrush = New-Brush $Tok.Line2
    $border.BorderThickness = 1
    $border.CornerRadius = 6
    $border.Margin = '4,4,4,4'
    $border.Padding = '12,10,12,10'
    if ($reason) { $border.Opacity = 0.45 }

    $outer = New-Object Windows.Controls.StackPanel

    $grid = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto','*','Auto','Auto') {
        $col = New-Object Windows.Controls.ColumnDefinition
        $col.Width = if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { [Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($col)
    }

    $check = New-Object Windows.Controls.CheckBox
    $check.VerticalAlignment = 'Center'
    $check.Margin = '0,0,12,0'
    $check.IsChecked = ($t.Risco -eq 'Seguro' -and -not $reason)  # pré-seleciona só o que é seguro
    $check.IsEnabled = -not $reason
    [Windows.Controls.Grid]::SetColumn($check, 0)
    $grid.Children.Add($check) | Out-Null

    $texts = New-Object Windows.Controls.StackPanel
    $nome = New-Object Windows.Controls.TextBlock
    $flags = @()
    if ($t.RequerAdmin)    { $flags += 'admin' }
    if ($t.RequerReinicio) { $flags += 'reinício' }
    $nome.Text = $t.Nome + $(if ($flags) { '  [' + ($flags -join ' · ') + ']' } else { '' })
    $nome.FontSize = 14; $nome.FontWeight = 'SemiBold'
    $nome.Foreground = New-Brush $Tok.Text
    $desc = New-Object Windows.Controls.TextBlock
    $desc.Text = "$($t.Descricao) $($t.Efeito)"
    $desc.FontSize = 12; $desc.TextWrapping = 'Wrap'
    $desc.Foreground = New-Brush $Tok.Mute
    $desc.Margin = '0,2,0,0'
    $toggle = New-Object Windows.Controls.TextBlock
    $toggle.Text = '▸ o que muda exatamente'
    $toggle.FontFamily = 'Consolas'; $toggle.FontSize = 11
    $toggle.Foreground = New-Brush $Tok.Cold
    $toggle.Cursor = [Windows.Input.Cursors]::Hand
    $toggle.Margin = '0,4,0,0'
    $texts.Children.Add($nome) | Out-Null
    $texts.Children.Add($desc) | Out-Null
    $texts.Children.Add($toggle) | Out-Null
    [Windows.Controls.Grid]::SetColumn($texts, 1)
    $grid.Children.Add($texts) | Out-Null

    $chip = New-Object Windows.Controls.Border
    $chip.BorderBrush = New-Brush $script:RiskColor[$t.Risco]
    $chip.BorderThickness = 1
    $chip.CornerRadius = 9
    $chip.Padding = '8,2,8,2'
    $chip.Margin = '12,0,12,0'
    $chip.VerticalAlignment = 'Center'
    $chipText = New-Object Windows.Controls.TextBlock
    $chipText.Text = $t.Risco.ToUpper()
    $chipText.FontFamily = 'Consolas'; $chipText.FontSize = 10
    $chipText.Foreground = New-Brush $script:RiskColor[$t.Risco]
    $chip.Child = $chipText
    [Windows.Controls.Grid]::SetColumn($chip, 2)
    $grid.Children.Add($chip) | Out-Null

    $status = New-Object Windows.Controls.StackPanel
    $status.Orientation = 'Horizontal'
    $status.VerticalAlignment = 'Center'
    $status.Width = 100
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 8; $dot.Height = 8
    $dot.Margin = '0,0,6,0'; $dot.VerticalAlignment = 'Center'
    $statusText = New-Object Windows.Controls.TextBlock
    $statusText.FontFamily = 'Consolas'; $statusText.FontSize = 11
    $statusText.VerticalAlignment = 'Center'
    $statusText.TextWrapping = 'Wrap'
    if ($reason) {
        $dot.Fill = New-Brush $Tok.Dim
        $statusText.Text = 'indisponível'
        $statusText.Foreground = New-Brush $Tok.Dim
        $statusText.ToolTip = $reason
        $border.ToolTip = $reason
    }
    $status.Children.Add($dot) | Out-Null
    $status.Children.Add($statusText) | Out-Null
    [Windows.Controls.Grid]::SetColumn($status, 3)
    $grid.Children.Add($status) | Out-Null

    # Painel de transparência: chave por chave, valor atual → valor novo
    $detail = New-Object Windows.Controls.StackPanel
    $detail.Visibility = 'Collapsed'
    $detail.Margin = '30,8,0,2'

    $toggle.Add_MouseLeftButtonUp({
        if ($detail.Visibility -eq 'Visible') {
            $detail.Visibility = 'Collapsed'
            $toggle.Text = '▸ o que muda exatamente'
        } else {
            $detail.Children.Clear()
            foreach ($line in @(Get-TweakDetail -Tweak $t)) {
                $tb = New-Object Windows.Controls.TextBlock
                $tb.Text = $line
                $tb.FontFamily = 'Consolas'; $tb.FontSize = 11
                $tb.TextWrapping = 'Wrap'
                $tb.Foreground = New-Brush $Tok.Dim
                $detail.Children.Add($tb) | Out-Null
            }
            $detail.Visibility = 'Visible'
            $toggle.Text = '▾ o que muda exatamente'
        }
    }.GetNewClosure())

    $outer.Children.Add($grid) | Out-Null
    $outer.Children.Add($detail) | Out-Null
    $border.Child = $outer
    $script:Ui.TweaksPanel.Children.Add($border) | Out-Null
    $script:Rows[$t.Id] = @{ Check = $check; Dot = $dot; StatusText = $statusText; Reason = $reason }
}

Update-RowStatus

# --- Execução em background (a UI nunca congela) -----------------------------
# O trabalho roda num runspace próprio que recarrega o Core; o estado é
# compartilhado via backup.json e o progresso via tail do arquivo de log.

$script:Job = $null

function Set-Busy {
    param([bool]$On, [string]$Msg = '')
    $script:Ui.Busy.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    $script:Ui.BusyText.Text = $Msg
    foreach ($b in 'ApplyBtn','RevertBtn','RevertAllBtn','OptimizeBtn') { $script:Ui[$b].IsEnabled = -not $On }
}

function Show-Banner {
    param([string]$Text, [string]$ColorHex)
    $script:Ui.Banner.Visibility = 'Visible'
    $script:Ui.Banner.BorderBrush = New-Brush $ColorHex
    $script:Ui.BannerText.Foreground = New-Brush $ColorHex
    $script:Ui.BannerText.Text = $Text
}

function Start-EngineJob {
    param([string]$Action, [string[]]$Ids, [bool]$RestorePoint)
    if ($script:Job) { return }
    Set-Busy $true $(if ($Action -like 'revert*') { 'revertendo...' } else { 'aplicando...' })
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($coreText, $action, $ids, $rp)
        Invoke-Expression $coreText
        Initialize-Optimizer
        $result = @{ ok = 0; fail = 0; reboot = $false }
        if ($rp) {
            Write-OptLog 'Criando ponto de restauração (pode demorar ~30s)...'
            New-OptimizerRestorePoint | Out-Null
        }
        switch ($action) {
            'apply' {
                foreach ($id in $ids) {
                    $t = Get-TweakById -Id $id
                    try {
                        Invoke-Tweak -Tweak $t
                        $result.ok++
                        if ($t.RequerReinicio) { $result.reboot = $true }
                    } catch {
                        $result.fail++
                        Write-OptLog "Falha aplicando ${id}: $($_.Exception.Message)" 'ERROR'
                    }
                }
            }
            'revert' {
                foreach ($id in $ids) {
                    $t = Get-TweakById -Id $id
                    try { Undo-Tweak -Tweak $t; $result.ok++ }
                    catch { $result.fail++; Write-OptLog "Falha revertendo ${id}: $($_.Exception.Message)" 'ERROR' }
                }
            }
            'revert-all' { Undo-AllTweaks; $result.ok = 1 }
        }
        $result
    }).AddArgument($script:CoreText).AddArgument($Action).AddArgument($Ids).AddArgument($RestorePoint)
    $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Action = $Action }
}

function Complete-EngineJob {
    $out = $script:Job.PS.EndInvoke($script:Job.Handle)
    $action = $script:Job.Action
    $script:Job.PS.Dispose()
    $script:Job = $null
    Set-Busy $false

    Initialize-Optimizer   # recarrega backup.json alterado pelo job
    Update-RowStatus

    $r = if ($out.Count -gt 0) { $out[$out.Count - 1] } else { $null }
    if (-not $r) { Show-Banner 'operação terminou sem resultado — ver log' $Tok.Risk; return }
    switch ($action) {
        'apply' {
            $msg = "✓ $($r.ok) tweak(s) aplicado(s)"
            if ($r.fail -gt 0) { $msg += " · $($r.fail) falhou(aram) — ver log" }
            if ($r.reboot)     { $msg += ' · reinicie o PC para todos valerem' }
            Show-Banner $msg $(if ($r.fail -gt 0) { $Tok.Risk } else { $Tok.Gain })
        }
        'revert' {
            $msg = "✓ $($r.ok) tweak(s) revertido(s)"
            if ($r.fail -gt 0) { $msg += " · $($r.fail) falhou(aram) — ver log" }
            Show-Banner $msg $(if ($r.fail -gt 0) { $Tok.Risk } else { $Tok.Gain })
        }
        'revert-all' { Show-Banner '✓ tudo desfeito — valores originais restaurados' $Tok.Gain }
    }
}

# --- Tail do log para a tela --------------------------------------------------
$script:LogPos = if (Test-Path $script:LogFile) { (Get-Item $script:LogFile).Length } else { 0 }

function Update-LogView {
    if (-not (Test-Path $script:LogFile)) { return }
    $len = (Get-Item $script:LogFile).Length
    if ($len -lt $script:LogPos) { $script:LogPos = 0 }   # log rotacionado/apagado
    if ($len -eq $script:LogPos) { return }
    $fs = [IO.File]::Open($script:LogFile, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($script:LogPos, 'Begin')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $new = $sr.ReadToEnd()
        $script:LogPos = $fs.Position
    } finally { $fs.Close() }
    if ($new) {
        $script:Ui.LogBox.AppendText($new)
        $script:Ui.LogBox.ScrollToEnd()
    }
}

# --- Telemetria real: ping (ICMP) e temperatura de GPU (nvidia-smi) -----------
$script:PingTask = $null
$script:PingHost = '1.1.1.1'
$script:Tick = 0

function Update-Telemetry {
    # ping: dispara async, colhe no tick seguinte (nunca bloqueia a UI)
    if ($script:PingTask) {
        if ($script:PingTask.IsCompleted) {
            try {
                $r = $script:PingTask.Result
                if ($r.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                    $script:Ui.PingVal.Text = "$($r.RoundtripTime)ms"
                    $script:Ui.PingSub.Text = "internet · $script:PingHost · real"
                } else {
                    $script:Ui.PingVal.Text = '—'
                    $script:Ui.PingSub.Text = 'sem resposta'
                }
            } catch {
                $script:Ui.PingVal.Text = '—'
                $script:Ui.PingSub.Text = 'sem rede'
            }
            $script:PingTask = $null
        }
    } elseif (($script:Tick % 8) -eq 0) {   # ~3,2s
        try { $script:PingTask = (New-Object Net.NetworkInformation.Ping).SendPingAsync($script:PingHost, 1500) } catch { $script:PingTask = $null }
    }

    # temperatura de GPU: só NVIDIA tem leitura confiável sem lib externa
    if ($script:NvSmi -and ($script:Tick % 25) -eq 1) {   # ~10s
        try {
            $tRaw = & $script:NvSmi.Source '--query-gpu=temperature.gpu' '--format=csv,noheader,nounits' | Select-Object -First 1
            if ("$tRaw".Trim() -match '^\d+$') { $script:Ui.TempVal.Text = "$("$tRaw".Trim())°C" }
        } catch { }
    }
}

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:Timer.Add_Tick({
    $script:Tick++
    Update-LogView
    Update-Telemetry
    if ($script:Job -and $script:Job.Handle.IsCompleted) { Complete-EngineJob }
})

# --- Ações ---------------------------------------------------------------------
function Get-SelectedIds {
    @(Get-Tweaks | Where-Object { -not $script:Rows[$_.Id].Reason -and $script:Rows[$_.Id].Check.IsChecked } | ForEach-Object { $_.Id })
}

# Um clique: aplica todo o preset Seguro+Moderado disponível nesta máquina.
# Avançado NUNCA entra em lote (regra 5) — só via seleção manual.
$script:Ui.OptimizeBtn.Add_Click({
    $ids = @(Get-Tweaks | Where-Object { $_.Risco -ne 'Avançado' -and -not $script:Rows[$_.Id].Reason } | ForEach-Object { $_.Id })
    Write-OptLog "OTIMIZAR (um clique): preset Seguro+Moderado — $($ids -join ', ')"
    Start-EngineJob -Action 'apply' -Ids $ids -RestorePoint ([bool]$script:Ui.RestoreChk.IsChecked)
})

$script:Ui.ApplyBtn.Add_Click({
    $ids = Get-SelectedIds
    if ($ids.Count -eq 0) { Show-Banner 'nada selecionado' $Tok.Mute; return }
    Start-EngineJob -Action 'apply' -Ids $ids -RestorePoint ([bool]$script:Ui.RestoreChk.IsChecked)
})

$script:Ui.RevertBtn.Add_Click({
    $ids = Get-SelectedIds
    if ($ids.Count -eq 0) { Show-Banner 'nada selecionado' $Tok.Mute; return }
    Start-EngineJob -Action 'revert' -Ids $ids -RestorePoint $false
})

$script:Ui.RevertAllBtn.Add_Click({
    $ok = [Windows.MessageBox]::Show(
        "Desfazer TUDO?`n`nCada valor alterado pelo app volta ao estado original salvo no backup.",
        'Optimizer — desfazer tudo',
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Warning)
    if ($ok -eq [Windows.MessageBoxResult]::Yes) {
        Start-EngineJob -Action 'revert-all' -Ids @() -RestorePoint $false
    }
})

Write-OptLog 'Painel aberto.'
Update-LogView

if ($RenderTest) {
    $unavailable = @(Get-Tweaks | Where-Object { $script:Rows[$_.Id].Reason }).Count
    Write-Host "RENDERTEST OK — janela montada com $($script:Rows.Count) tweaks ($unavailable indisponíveis nesta máquina). GPU: $($script:Ui.GpuBadge.Text)"
    exit 0
}

$script:Timer.Start()
$window.ShowDialog() | Out-Null
$script:Timer.Stop()
