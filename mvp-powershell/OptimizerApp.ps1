# OptimizerApp.ps1 — painel WPF do Optimizer (MVP)
#
# Conceito visual: instrumento de diagnóstico de precisão, clean — janela sem
# borda com cantos arredondados, toggles, botões pill. Tokens: ver CLAUDE.md.
#
# Regra 3 (inviolável): o readout de telemetria NUNCA mostra número inventado.
# Ping e temperatura de GPU são medidos de verdade (ICMP / nvidia-smi);
# FPS e 1% low ficam em "—" até o PresentMon (Fase 2).
#
# Jogos: perfis data-driven em profiles/*.json (detecção de instalado + em
# execução). Selecionar um jogo marca os tweaks do perfil dele.

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

# profiles/: instalado via get.ps1 = .\profiles ; repo dev = ..\profiles
foreach ($cand in (Join-Path $PSScriptRoot 'profiles'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'profiles')) {
    if (Test-Path $cand) { $script:ProfilesDir = $cand; break }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --- Tokens ----------------------------------------------------------------
$script:Tok = @{
    Bg      = '#0B0D12'; Surface = '#12151D'; Surface2 = '#161A24'
    Line    = '#232838'; Line2   = '#1C2130'
    Text    = '#EDEEF4'; Mute    = '#8A91A8'; Dim = '#565D73'
    Accent  = '#7C6CFF'; Accent2 = '#4EA8FF'; Warn = '#FFB454'
    Gain    = '#4ADE97'; Risk    = '#F0566A'; Cold = '#4EC9E8'
}

function New-Brush([string]$Hex) {
    New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

$script:RiskColor = @{
    'Seguro'   = $Tok.Gain
    'Moderado' = $Tok.Warn
    'Avançado' = $Tok.Risk
}

# --- Janela (XAML) ----------------------------------------------------------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OPT — otimizador" Width="1188" Height="808"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI" TextOptions.TextRenderingMode="ClearType">

  <Window.Resources>
    <!-- gradiente do acento (CTA e logo) -->
    <LinearGradientBrush x:Key="AccentGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="$($Tok.Accent)" Offset="0"/>
      <GradientStop Color="$($Tok.Accent2)" Offset="1"/>
    </LinearGradientBrush>

    <!-- toggle estilo switch -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="$($Tok.Mute)"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Track" Width="38" Height="22" CornerRadius="11" Background="$($Tok.Line)" VerticalAlignment="Center">
                <Ellipse x:Name="Thumb" Width="16" Height="16" Fill="$($Tok.Mute)" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="3,0,3,0"/>
              </Border>
              <ContentPresenter VerticalAlignment="Center" Margin="8,0,0,0"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="$($Tok.Accent)"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Fill" Value="$($Tok.Bg)"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Track" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- botão pill com hover suave -->
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="$($Tok.Text)"/>
      <Setter Property="Background" Value="$($Tok.Surface)"/>
      <Setter Property="BorderBrush" Value="$($Tok.Line)"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="10" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- scrollbar fininha -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.DecreaseRepeatButton>
                <RepeatButton Opacity="0" Focusable="False"/>
              </Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton>
                <RepeatButton Opacity="0" Focusable="False"/>
              </Track.IncreaseRepeatButton>
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="4" Background="$($Tok.Line)" Margin="2,0,0,0"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="14">
    <!-- sombra da janela (borda separada para não desfocar o conteúdo) -->
    <Border CornerRadius="16" Background="#000000">
      <Border.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="26" ShadowDepth="0" Opacity="0.6"/>
      </Border.Effect>
    </Border>
  <Border CornerRadius="14" Background="$($Tok.Bg)" BorderBrush="$($Tok.Line)" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="46"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- barra de título (arrastável) -->
      <DockPanel Grid.Row="0" x:Name="TitleBar" Background="Transparent" Margin="20,8,10,0">
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
          <TextBlock Text="OPT" FontFamily="Consolas" FontSize="20" FontWeight="Bold" Foreground="{StaticResource AccentGrad}" VerticalAlignment="Center"/>
          <TextBlock Text="  otimizador" FontSize="13" Foreground="$($Tok.Mute)" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right">
          <TextBlock x:Name="GpuBadge" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Mute)" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock x:Name="AdminBadge" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Dim)" VerticalAlignment="Center" Margin="0,0,14,0"/>
          <Button x:Name="MinBtn" Content="–" Style="{StaticResource Pill}" Width="32" Height="26" Padding="0"
                  Background="Transparent" BorderBrush="Transparent" Foreground="$($Tok.Mute)"/>
          <Button x:Name="CloseBtn" Content="✕" Style="{StaticResource Pill}" Width="32" Height="26" Padding="0" Margin="4,0,0,0"
                  Background="Transparent" BorderBrush="Transparent" Foreground="$($Tok.Mute)"/>
        </StackPanel>
      </DockPanel>

      <Grid Grid.Row="1" Margin="20,10,20,20">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="225"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- sidebar: jogos detectados (perfis JSON) -->
        <Border Grid.Column="0" Background="$($Tok.Surface2)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="12" Padding="12">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="JOGOS DETECTADOS" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Dim)" Margin="4,2,0,10"/>
            <TextBlock DockPanel.Dock="Bottom" x:Name="ShowAllLink" Text="mostrar todos os perfis" FontFamily="Consolas" FontSize="10"
                       Foreground="$($Tok.Cold)" Cursor="Hand" Margin="4,10,0,2"/>
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="GamesPanel"/>
            </ScrollViewer>
          </DockPanel>
        </Border>

        <!-- conteúdo principal -->
        <Grid Grid.Column="1" Margin="16,0,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="112"/>
          </Grid.RowDefinitions>

          <!-- readout de telemetria: só número REAL ou "—" -->
          <Grid Grid.Row="0" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="12" Padding="14,10" Margin="0,0,10,0">
              <StackPanel>
                <TextBlock Text="FPS MÉDIO" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Mute)"/>
                <TextBlock x:Name="FpsVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
                <TextBlock x:Name="FpsSub" Text="PresentMon — Fase 2" FontFamily="Consolas" FontSize="9" Foreground="$($Tok.Dim)"/>
              </StackPanel>
            </Border>
            <Border Grid.Column="1" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="12" Padding="14,10" Margin="0,0,10,0">
              <StackPanel>
                <TextBlock Text="1% LOW" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Mute)"/>
                <TextBlock x:Name="LowVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
                <TextBlock x:Name="LowSub" Text="PresentMon — Fase 2" FontFamily="Consolas" FontSize="9" Foreground="$($Tok.Dim)"/>
              </StackPanel>
            </Border>
            <Border Grid.Column="2" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="12" Padding="14,10" Margin="0,0,10,0">
              <StackPanel>
                <TextBlock Text="PING" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Mute)"/>
                <TextBlock x:Name="PingVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Text)"/>
                <TextBlock x:Name="PingSub" Text="medindo..." FontFamily="Consolas" FontSize="9" Foreground="$($Tok.Dim)"/>
              </StackPanel>
            </Border>
            <Border Grid.Column="3" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="12" Padding="14,10">
              <StackPanel>
                <TextBlock Text="TEMP GPU" FontFamily="Consolas" FontSize="10" Foreground="$($Tok.Mute)"/>
                <TextBlock x:Name="TempVal" Text="—" FontFamily="Consolas" FontSize="30" Foreground="$($Tok.Cold)"/>
                <TextBlock x:Name="TempSub" Text="sem sensor legível" FontFamily="Consolas" FontSize="9" Foreground="$($Tok.Dim)"/>
              </StackPanel>
            </Border>
          </Grid>

          <!-- banner de resultado -->
          <Border Grid.Row="1" x:Name="Banner" Visibility="Collapsed" Background="$($Tok.Surface)" BorderThickness="1" CornerRadius="10" Padding="12,8" Margin="0,0,0,12">
            <TextBlock x:Name="BannerText" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"/>
          </Border>

          <!-- lista de tweaks -->
          <Border Grid.Row="2" Background="$($Tok.Surface2)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="12" Padding="8">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="TweaksPanel"/>
            </ScrollViewer>
          </Border>

          <!-- ações -->
          <DockPanel Grid.Row="3" Margin="2,14,2,14">
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
              <CheckBox x:Name="RestoreChk" IsChecked="True" Style="{StaticResource Switch}" FontSize="11"
                        Content="ponto de restauração"/>
              <ProgressBar x:Name="Busy" IsIndeterminate="True" Width="100" Height="4" Margin="14,0,8,0" Visibility="Collapsed"
                           Background="$($Tok.Surface)" Foreground="$($Tok.Accent)" BorderThickness="0"/>
              <TextBlock x:Name="BusyText" FontFamily="Consolas" FontSize="11" Foreground="$($Tok.Accent)" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="RevertAllBtn" Content="DESFAZER TUDO" Style="{StaticResource Pill}" FontFamily="Consolas" FontSize="11" Padding="14,9" Margin="0,0,8,0"
                      Foreground="$($Tok.Risk)" BorderBrush="$($Tok.Risk)"/>
              <Button x:Name="RevertBtn" Content="REVERTER SELEÇÃO" Style="{StaticResource Pill}" FontFamily="Consolas" FontSize="11" Padding="14,9" Margin="0,0,8,0"
                      Foreground="$($Tok.Mute)"/>
              <Button x:Name="ApplyBtn" Content="APLICAR SELEÇÃO" Style="{StaticResource Pill}" FontFamily="Consolas" FontSize="11" Padding="14,9" Margin="0,0,10,0"/>
              <Button x:Name="OptimizeBtn" Content="⚡ OTIMIZAR" Style="{StaticResource Pill}" FontFamily="Consolas" FontSize="13" FontWeight="Bold" Padding="24,9"
                      Background="{StaticResource AccentGrad}" BorderBrush="Transparent" Foreground="#FFFFFF">
                <Button.Effect>
                  <DropShadowEffect Color="$($Tok.Accent)" BlurRadius="16" ShadowDepth="0" Opacity="0.55"/>
                </Button.Effect>
              </Button>
            </StackPanel>
          </DockPanel>

          <!-- log -->
          <Border Grid.Row="4" Background="$($Tok.Surface)" BorderBrush="$($Tok.Line2)" BorderThickness="1" CornerRadius="12" Padding="10,8">
            <DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="2,0,2,4">
                <TextBlock DockPanel.Dock="Left" FontFamily="Consolas" FontSize="9" Foreground="$($Tok.Dim)"
                           Text="log — tudo que o app altera é registrado e reversível"/>
                <TextBlock x:Name="DiagLink" HorizontalAlignment="Right" FontFamily="Consolas" FontSize="9"
                           Foreground="$($Tok.Cold)" Cursor="Hand" Text="[ exportar diagnóstico ]"/>
              </DockPanel>
              <TextBox x:Name="LogBox" IsReadOnly="True" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="10"
                       Background="Transparent" Foreground="$($Tok.Mute)" BorderThickness="0"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Hidden"/>
            </DockPanel>
          </Border>
        </Grid>
      </Grid>
    </Grid>
  </Border>
  </Grid>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)

$script:Ui = @{}
foreach ($name in 'TitleBar','MinBtn','CloseBtn','GpuBadge','AdminBadge','GamesPanel','ShowAllLink',
                  'TweaksPanel','RestoreChk','ApplyBtn','RevertBtn','RevertAllBtn','OptimizeBtn',
                  'LogBox','DiagLink','Banner','BannerText','Busy','BusyText',
                  'FpsVal','FpsSub','LowVal','LowSub','PingVal','PingSub','TempVal','TempSub') {
    $script:Ui[$name] = $window.FindName($name)
}

# janela sem borda: arrastar pela barra de título + botões próprios
$script:Ui.TitleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$script:Ui.CloseBtn.Add_Click({ $window.Close() })
$script:Ui.MinBtn.Add_Click({ $window.WindowState = 'Minimized' })

$script:Ui.AdminBadge.Text = if (Test-IsAdmin) { '[ admin ]' } else { '[ sem admin ]' }

$gpu = Get-MainGpu
$script:Ui.GpuBadge.Text = if ($gpu) {
    $tipo = if ($gpu.Integrada) { 'integrada' } else { 'dedicada' }
    "[ $($gpu.Name) · $tipo ]"
} else { '[ GPU não detectada ]' }

$script:NvSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($script:NvSmi) { $script:Ui.TempSub.Text = 'GPU · nvidia-smi · real' }

# --- Linhas de tweak ----------------------------------------------------------
$script:Rows = @{}   # Id -> @{ Check; Dot; StatusText; Reason }

function Update-RowStatus {
    foreach ($t in Get-Tweaks) {
        $row = $script:Rows[$t.Id]
        if ($row.Reason) { continue }
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

$switchStyle = $window.FindResource('Switch')

foreach ($t in Get-Tweaks) {
    $reason = Get-TweakUnavailableReason -Tweak $t

    $border = New-Object Windows.Controls.Border
    $border.Background = New-Brush $Tok.Surface
    $border.BorderBrush = New-Brush $Tok.Line2
    $border.BorderThickness = 1
    $border.CornerRadius = 10
    $border.Margin = '4,4,4,4'
    $border.Padding = '14,11,14,11'
    if ($reason) { $border.Opacity = 0.45 }

    $outer = New-Object Windows.Controls.StackPanel

    $grid = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto','*','Auto','Auto') {
        $col = New-Object Windows.Controls.ColumnDefinition
        $col.Width = if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { [Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($col)
    }

    $check = New-Object Windows.Controls.CheckBox
    $check.Style = $switchStyle
    $check.VerticalAlignment = 'Center'
    $check.Margin = '0,0,14,0'
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
    $toggle.Margin = '0,5,0,0'
    $texts.Children.Add($nome) | Out-Null
    $texts.Children.Add($desc) | Out-Null
    $texts.Children.Add($toggle) | Out-Null
    [Windows.Controls.Grid]::SetColumn($texts, 1)
    $grid.Children.Add($texts) | Out-Null

    $chip = New-Object Windows.Controls.Border
    $chip.BorderBrush = New-Brush $script:RiskColor[$t.Risco]
    $chip.BorderThickness = 1
    $chip.CornerRadius = 9
    $chip.Padding = '9,2,9,2'
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
    $status.Width = 96
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

    # painel de transparência: chave por chave, valor atual → valor novo
    $detail = New-Object Windows.Controls.StackPanel
    $detail.Visibility = 'Collapsed'
    $detail.Margin = '52,8,0,2'

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

# --- Sidebar de jogos (perfis data-driven) -------------------------------------
$script:GameCards    = @{}    # id -> @{ Profile; Border; Dot; Status }
$script:SelectedGame = $null
$script:ShowAllGames = $false
$script:AutoSelected = $false

function Select-GameProfile {
    param($Profile)
    $script:SelectedGame = $Profile
    foreach ($id in $script:GameCards.Keys) {
        $c = $script:GameCards[$id]
        $c.Border.BorderBrush = if ($id -eq $Profile.id) { New-Brush $Tok.Accent } else { New-Brush $Tok.Line2 }
    }
    # marca os tweaks do perfil (só os disponíveis nesta máquina)
    $sistema = @($Profile.sistema)
    foreach ($t in Get-Tweaks) {
        $row = $script:Rows[$t.Id]
        if ($row.Reason) { continue }
        $row.Check.IsChecked = ($sistema -contains $t.Id)
    }
    Write-OptLog "Perfil '$($Profile.nome)' selecionado — tweaks do perfil marcados."
    Show-Banner "perfil $($Profile.nome): $($sistema.Count) tweaks marcados — revise e aplique" $Tok.Cold
}

function Build-GamesPanel {
    $script:Ui.GamesPanel.Children.Clear()
    $script:GameCards = @{}
    $profiles = @(Get-GameProfiles)
    $shown = 0
    foreach ($p in $profiles) {
        $installed = Test-GameInstalled -Profile $p
        if (-not $installed -and -not $script:ShowAllGames) { continue }
        $shown++

        $card = New-Object Windows.Controls.Border
        $card.Background = New-Brush $Tok.Surface
        $card.BorderBrush = New-Brush $Tok.Line2
        $card.BorderThickness = 1
        $card.CornerRadius = 10
        $card.Margin = '2,3,2,3'
        $card.Padding = '11,9,11,9'
        $card.Cursor = [Windows.Input.Cursors]::Hand
        if (-not $installed) { $card.Opacity = 0.5 }

        $stack = New-Object Windows.Controls.StackPanel
        $nomeTb = New-Object Windows.Controls.TextBlock
        $nomeTb.Text = $p.nome
        $nomeTb.FontSize = 13; $nomeTb.FontWeight = 'SemiBold'
        $nomeTb.Foreground = New-Brush $Tok.Text
        $statusRow = New-Object Windows.Controls.StackPanel
        $statusRow.Orientation = 'Horizontal'
        $statusRow.Margin = '0,3,0,0'
        $gdot = New-Object Windows.Shapes.Ellipse
        $gdot.Width = 7; $gdot.Height = 7
        $gdot.Margin = '0,0,5,0'; $gdot.VerticalAlignment = 'Center'
        $gdot.Fill = New-Brush $(if ($installed) { $Tok.Mute } else { $Tok.Dim })
        $gstatus = New-Object Windows.Controls.TextBlock
        $gstatus.Text = if ($installed) { 'instalado' } else { 'não detectado' }
        $gstatus.FontFamily = 'Consolas'; $gstatus.FontSize = 10
        $gstatus.Foreground = New-Brush $Tok.Dim
        $statusRow.Children.Add($gdot) | Out-Null
        $statusRow.Children.Add($gstatus) | Out-Null
        $stack.Children.Add($nomeTb) | Out-Null
        $stack.Children.Add($statusRow) | Out-Null
        $card.Child = $stack

        $card.Add_MouseLeftButtonUp({ Select-GameProfile -Profile $p }.GetNewClosure())

        $script:Ui.GamesPanel.Children.Add($card) | Out-Null
        $script:GameCards[$p.id] = @{ Profile = $p; Border = $card; Dot = $gdot; Status = $gstatus }
    }
    if ($shown -eq 0) {
        $none = New-Object Windows.Controls.TextBlock
        $none.Text = if ($profiles.Count -eq 0) { 'nenhum perfil em profiles\' } else { 'nenhum jogo detectado neste PC' }
        $none.FontFamily = 'Consolas'; $none.FontSize = 11
        $none.TextWrapping = 'Wrap'
        $none.Foreground = New-Brush $Tok.Dim
        $none.Margin = '4,4,4,4'
        $script:Ui.GamesPanel.Children.Add($none) | Out-Null
    }
}

function Update-GameStatus {
    # marca ao vivo o que está em execução; se nada foi selecionado ainda,
    # seleciona sozinho o perfil do jogo rodando (uma vez só)
    foreach ($id in $script:GameCards.Keys) {
        $c = $script:GameCards[$id]
        if (Test-GameRunning -Profile $c.Profile) {
            $c.Dot.Fill = New-Brush $Tok.Gain
            $c.Status.Text = 'em execução'
            $c.Status.Foreground = New-Brush $Tok.Gain
            if (-not $script:SelectedGame -and -not $script:AutoSelected) {
                $script:AutoSelected = $true
                Select-GameProfile -Profile $c.Profile
                Show-Banner "$($c.Profile.nome) detectado em execução — perfil carregado, revise e aplique" $Tok.Gain
            }
        } elseif ($c.Status.Text -eq 'em execução') {
            $c.Dot.Fill = New-Brush $Tok.Mute
            $c.Status.Text = 'instalado'
            $c.Status.Foreground = New-Brush $Tok.Dim
        }
    }
}

$script:Ui.ShowAllLink.Add_MouseLeftButtonUp({
    $script:ShowAllGames = -not $script:ShowAllGames
    $script:Ui.ShowAllLink.Text = if ($script:ShowAllGames) { 'mostrar só detectados' } else { 'mostrar todos os perfis' }
    Build-GamesPanel
    Update-GameStatus
})

Build-GamesPanel

# --- Execução em background (a UI nunca congela) -----------------------------
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
        try {
            Enter-OptimizerLock   # impede outra instância (CLI/GUI) de escrever junto
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
        } catch {
            $result.fail++
            Write-OptLog "ERRO na operação: $($_.Exception.Message)" 'ERROR'
        } finally {
            Exit-OptimizerLock
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
            $msg = "✓ $($r.ok) tweak(s) aplicado(s) e verificado(s)"
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
    if (($script:Tick % 12) -eq 2) { Update-GameStatus }   # ~5s: jogo em execução?
    if ($script:Job -and $script:Job.Handle.IsCompleted) { Complete-EngineJob }
})

# --- Ações ---------------------------------------------------------------------
function Get-SelectedIds {
    @(Get-Tweaks | Where-Object { -not $script:Rows[$_.Id].Reason -and $script:Rows[$_.Id].Check.IsChecked } | ForEach-Object { $_.Id })
}

# Regra 2: ponto de restauração antes de aplicar. Se o System Restore está
# desligado (comum em PC de fábrica), perguntar em vez de falhar em silêncio.
# Retorna $true/$false (criar ponto?) ou $null (usuário cancelou).
function Resolve-RestorePointChoice {
    if (-not $script:Ui.RestoreChk.IsChecked) { return $false }
    if (Test-SystemRestoreEnabled) { return $true }
    $ans = [Windows.MessageBox]::Show(
        "O System Restore está DESATIVADO neste PC — sem ele não dá para criar o ponto de restauração.`n`nSim — ativar o System Restore agora e continuar`nNão — continuar só com o backup JSON do app`nCancelar — não aplicar nada",
        'Optimizer — ponto de restauração',
        [Windows.MessageBoxButton]::YesNoCancel,
        [Windows.MessageBoxImage]::Warning)
    switch ($ans) {
        'Yes' {
            try { Enable-SystemRestoreOnSystemDrive; return $true }
            catch {
                Show-Banner "não consegui ativar o System Restore: $($_.Exception.Message)" $Tok.Risk
                return $null
            }
        }
        'No'    { return $false }
        default { return $null }
    }
}

# Um clique: com jogo selecionado, aplica o perfil dele; sem jogo, o preset
# Seguro+Moderado. Avançado NUNCA entra em lote (regra 5) — só seleção manual.
$script:Ui.OptimizeBtn.Add_Click({
    $rp = Resolve-RestorePointChoice
    if ($null -eq $rp) { return }
    if ($script:SelectedGame) {
        $sistema = @($script:SelectedGame.sistema)
        $ids = @(Get-Tweaks | Where-Object { $_.Risco -ne 'Avançado' -and -not $script:Rows[$_.Id].Reason -and $sistema -contains $_.Id } | ForEach-Object { $_.Id })
        Write-OptLog "OTIMIZAR: perfil $($script:SelectedGame.nome) — $($ids -join ', ')"
    } else {
        $ids = @(Get-Tweaks | Where-Object { $_.Risco -ne 'Avançado' -and -not $script:Rows[$_.Id].Reason } | ForEach-Object { $_.Id })
        Write-OptLog "OTIMIZAR (um clique): preset Seguro+Moderado — $($ids -join ', ')"
    }
    Start-EngineJob -Action 'apply' -Ids $ids -RestorePoint $rp
})

$script:Ui.ApplyBtn.Add_Click({
    $ids = Get-SelectedIds
    if ($ids.Count -eq 0) { Show-Banner 'nada selecionado' $Tok.Mute; return }
    $rp = Resolve-RestorePointChoice
    if ($null -eq $rp) { return }
    Start-EngineJob -Action 'apply' -Ids $ids -RestorePoint $rp
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

$script:Ui.DiagLink.Add_MouseLeftButtonUp({
    try {
        $zip = Export-OptimizerDiagnostic
        Show-Banner "✓ diagnóstico salvo em: $zip (nada é enviado — você decide se manda)" $Tok.Cold
    } catch {
        Show-Banner "falha exportando diagnóstico: $($_.Exception.Message)" $Tok.Risk
    }
})

Write-OptLog 'Painel aberto.'
Update-LogView
Update-GameStatus

if ($RenderTest) {
    $unavailable = @(Get-Tweaks | Where-Object { $script:Rows[$_.Id].Reason }).Count
    $nGames = @(Get-GameProfiles).Count
    $nInstalled = @(Get-GameProfiles | Where-Object { Test-GameInstalled -Profile $_ }).Count
    Write-Host "RENDERTEST OK — $($script:Rows.Count) tweaks ($unavailable indisponíveis) · $nGames perfis de jogo ($nInstalled instalados) · GPU: $($script:Ui.GpuBadge.Text)"
    exit 0
}

$script:Timer.Start()
$window.ShowDialog() | Out-Null
$script:Timer.Stop()
