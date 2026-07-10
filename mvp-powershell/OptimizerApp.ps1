# OptimizerApp.ps1 — painel WPF do Optimizer (MVP)
#
# Conceito visual: instrumento de diagnóstico de precisão (telemetria), NÃO "gamer RGB".
# Tokens de design: ver CLAUDE.md.
#
# Regra 3 (inviolável): o readout de telemetria NUNCA mostra número inventado.
# Enquanto o PresentMon não está integrado (Fase 2), mostra "—" e diz isso na cara.

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

. (Join-Path $PSScriptRoot 'OptimizerCore.ps1')
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
        Title="OPT — otimizador" Width="1020" Height="720"
        WindowStartupLocation="CenterScreen"
        Background="$($Tok.Bg)" FontFamily="Segoe UI">
  <Grid Margin="18">
    <Grid.RowDefinitions>
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
      <TextBlock x:Name="AdminBadge" DockPanel.Dock="Right" HorizontalAlignment="Right"
                 FontFamily="Consolas" FontSize="12" Foreground="$($Tok.Dim)" VerticalAlignment="Center"/>
    </DockPanel>

    <!-- Readout de telemetria (assinatura visual). Sem PresentMon (Fase 2) = sem números. -->
    <Border Grid.Row="1" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line)" BorderThickness="1" CornerRadius="8" Padding="16,12" Margin="0,0,0,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="FPS MÉDIO" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)"/>
          <TextBlock x:Name="FpsVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
          <TextBlock Text="sem medição" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)"/>
        </StackPanel>
        <StackPanel Grid.Column="1">
          <TextBlock Text="1% LOW" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)"/>
          <TextBlock x:Name="LowVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
          <TextBlock Text="sem medição" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="PING" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)"/>
          <TextBlock x:Name="PingVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
          <TextBlock Text="sem medição" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)"/>
        </StackPanel>
        <StackPanel Grid.Column="3">
          <TextBlock Text="TEMP" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)"/>
          <TextBlock x:Name="TempVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Cold)"/>
          <TextBlock Text="sem medição" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Lista de tweaks -->
    <Border Grid.Row="2" Background="$($Tok.Surface2)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="8" Padding="10">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="TweaksPanel"/>
      </ScrollViewer>
    </Border>

    <!-- Ações -->
    <DockPanel Grid.Row="3" Margin="2,12,2,12">
      <CheckBox x:Name="RestoreChk" IsChecked="True" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="$($Tok.Mute)" FontSize="12"
                Content="Criar ponto de restauração antes de aplicar"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="RevertAllBtn" Content="DESFAZER TUDO" FontFamily="Consolas" FontSize="12" Padding="14,8" Margin="0,0,8,0"
                Background="$($Tok.Surface)" Foreground="$($Tok.Risk)" BorderBrush="$($Tok.Risk)"/>
        <Button x:Name="RevertBtn" Content="REVERTER SELECIONADOS" FontFamily="Consolas" FontSize="12" Padding="14,8" Margin="0,0,8,0"
                Background="$($Tok.Surface)" Foreground="$($Tok.Mute)" BorderBrush="$($Tok.Line)"/>
        <Button x:Name="ApplyBtn" Content="APLICAR SELECIONADOS" FontFamily="Consolas" FontSize="12" FontWeight="Bold" Padding="16,8"
                Background="$($Tok.Accent)" Foreground="#0C1116" BorderBrush="$($Tok.Accent)"/>
      </StackPanel>
    </DockPanel>

    <!-- Log (transparência total: tudo que o app faz aparece aqui e no arquivo) -->
    <Border Grid.Row="4" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line)" BorderThickness="1" CornerRadius="8" Padding="8">
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
foreach ($name in 'AdminBadge','TweaksPanel','RestoreChk','ApplyBtn','RevertBtn','RevertAllBtn','LogBox','FpsVal','LowVal','PingVal','TempVal') {
    $script:Ui[$name] = $window.FindName($name)
}

$script:Ui.AdminBadge.Text = if (Test-IsAdmin) { '[ admin ]' } else { '[ sem admin — tweaks de sistema bloqueados ]' }

# Espelha o log do motor na tela
$script:LogSink = {
    param($line)
    $script:Ui.LogBox.AppendText($line + [Environment]::NewLine)
    $script:Ui.LogBox.ScrollToEnd()
}

# --- Linhas de tweak (construídas em código a partir do catálogo) -----------
$script:Rows = @{}   # Id -> @{ Check; Dot; StatusText }

function Update-RowStatus {
    foreach ($t in Get-Tweaks) {
        $row = $script:Rows[$t.Id]
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
    $border = New-Object Windows.Controls.Border
    $border.Background = New-Brush $Tok.Surface
    $border.BorderBrush = New-Brush $Tok.Line2
    $border.BorderThickness = 1
    $border.CornerRadius = 6
    $border.Margin = '4,4,4,4'
    $border.Padding = '12,10,12,10'

    $grid = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto','*','Auto','Auto') {
        $col = New-Object Windows.Controls.ColumnDefinition
        $col.Width = if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { [Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($col)
    }

    $check = New-Object Windows.Controls.CheckBox
    $check.VerticalAlignment = 'Center'
    $check.Margin = '0,0,12,0'
    $check.IsChecked = ($t.Risco -eq 'Seguro')  # pré-seleciona só o que é seguro
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
    $texts.Children.Add($nome) | Out-Null
    $texts.Children.Add($desc) | Out-Null
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
    $status.Width = 90
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 8; $dot.Height = 8
    $dot.Margin = '0,0,6,0'; $dot.VerticalAlignment = 'Center'
    $statusText = New-Object Windows.Controls.TextBlock
    $statusText.FontFamily = 'Consolas'; $statusText.FontSize = 11
    $statusText.VerticalAlignment = 'Center'
    $status.Children.Add($dot) | Out-Null
    $status.Children.Add($statusText) | Out-Null
    [Windows.Controls.Grid]::SetColumn($status, 3)
    $grid.Children.Add($status) | Out-Null

    $border.Child = $grid
    $script:Ui.TweaksPanel.Children.Add($border) | Out-Null
    $script:Rows[$t.Id] = @{ Check = $check; Dot = $dot; StatusText = $statusText }
}

Update-RowStatus

# --- Ações -------------------------------------------------------------------
function Get-SelectedTweaks {
    Get-Tweaks | Where-Object { $script:Rows[$_.Id].Check.IsChecked }
}

function Invoke-Busy([scriptblock]$Work) {
    $window.Cursor = [Windows.Input.Cursors]::Wait
    foreach ($b in 'ApplyBtn','RevertBtn','RevertAllBtn') { $script:Ui[$b].IsEnabled = $false }
    try { & $Work } finally {
        $window.Cursor = $null
        foreach ($b in 'ApplyBtn','RevertBtn','RevertAllBtn') { $script:Ui[$b].IsEnabled = $true }
        Update-RowStatus
    }
}

$script:Ui.ApplyBtn.Add_Click({
    Invoke-Busy {
        $sel = @(Get-SelectedTweaks)
        if ($sel.Count -eq 0) { Write-OptLog 'Nada selecionado.' 'WARN'; return }
        if ($script:Ui.RestoreChk.IsChecked) {
            Write-OptLog 'Criando ponto de restauração (pode demorar ~30s)...'
            New-OptimizerRestorePoint | Out-Null
        }
        $reboot = $false
        foreach ($t in $sel) {
            try {
                Invoke-Tweak -Tweak $t
                if ($t.RequerReinicio) { $reboot = $true }
            } catch {
                Write-OptLog "Falha aplicando $($t.Id): $($_.Exception.Message)" 'ERROR'
            }
        }
        if ($reboot) { Write-OptLog 'Atenção: alguns tweaks só valem após REINICIAR o PC.' 'WARN' }
    }
})

$script:Ui.RevertBtn.Add_Click({
    Invoke-Busy {
        foreach ($t in @(Get-SelectedTweaks)) {
            try { Undo-Tweak -Tweak $t } catch { Write-OptLog "Falha revertendo $($t.Id): $($_.Exception.Message)" 'ERROR' }
        }
    }
})

$script:Ui.RevertAllBtn.Add_Click({
    Invoke-Busy { Undo-AllTweaks }
})

Write-OptLog 'Painel aberto.'

if ($RenderTest) {
    Write-Host "RENDERTEST OK — janela montada com $($script:Rows.Count) tweaks."
    exit 0
}

$window.ShowDialog() | Out-Null
