#Requires -Version 5.1
<#
    DisableDefender GUI v0.0.7
    Premium WPF dark interface for the DisableDefender module

    Features:
      - Catppuccin Mocha dark palette, custom chrome, glassmorphic panels
      - Live status tiles (AV, Real-time, Behavior, Tamper, Firewall, Safe Mode)
      - Async worker runspace so the UI never blocks
      - Streaming log pane with level colors + auto-scroll
      - Confirmation modal for destructive ops
      - Toast notifications for success/failure
      - Tamper Protection banner with direct link to Windows Security
#>

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Self-elevate
# ---------------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# Hide console window (when launched directly via powershell.exe)
# ---------------------------------------------------------------------------
Add-Type -Namespace DisableDefenderGui -Name ConsoleCtl -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
try {
    $consoleHandle = [DisableDefenderGui.ConsoleCtl]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [DisableDefenderGui.ConsoleCtl]::ShowWindow($consoleHandle, 0) | Out-Null
    }
} catch {}

# ---------------------------------------------------------------------------
# WPF assemblies
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# ---------------------------------------------------------------------------
# Core module
# ---------------------------------------------------------------------------
$modulePath = Join-Path $PSScriptRoot 'DisableDefender.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    [System.Windows.MessageBox]::Show("DisableDefender module manifest not found alongside GUI.`nExpected: $modulePath", 'DisableDefender', 'OK', 'Error') | Out-Null
    exit 1
}
Import-Module -Name $modulePath -Force -ErrorAction Stop
$script:Version = (Get-Module -Name DisableDefender).Version.ToString()
$script:AppName = 'DisableDefender'
$script:AppDir = Join-Path $env:ProgramData $script:AppName
$script:LogPath = Join-Path $script:AppDir "$script:AppName.log"
if (-not (Test-Path -LiteralPath $script:AppDir)) {
    New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Synchronized UI state (queue for IPC between worker runspace and dispatcher)
# ---------------------------------------------------------------------------
$script:UIState = [hashtable]::Synchronized(@{
    LogQueue  = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    Busy      = $false
    LastAction = ''
    LastResult = ''
    StatusSnapshot = $null
})

# Override Write-Log in the main scope so Get-DefenderStatus calls from UI thread queue too.
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $entry = [PSCustomObject]@{ Time = $stamp; Level = $Level; Message = $Message }
    $script:UIState.LogQueue.Enqueue($entry)
    $fileLine = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    try { Add-Content -LiteralPath $script:LogPath -Value $fileLine -ErrorAction Stop } catch {}
}

# ---------------------------------------------------------------------------
# XAML - Catppuccin Mocha theme
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DisableDefender"
        Width="1180" Height="760"
        MinWidth="1000" MinHeight="640"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        ResizeMode="CanResize"
        Background="#1e1e2e"
        FontFamily="Segoe UI">

    <Window.Resources>
        <!-- Palette -->
        <SolidColorBrush x:Key="Base"     Color="#1e1e2e"/>
        <SolidColorBrush x:Key="Mantle"   Color="#181825"/>
        <SolidColorBrush x:Key="Crust"    Color="#11111b"/>
        <SolidColorBrush x:Key="Surface0" Color="#313244"/>
        <SolidColorBrush x:Key="Surface1" Color="#45475a"/>
        <SolidColorBrush x:Key="Surface2" Color="#585b70"/>
        <SolidColorBrush x:Key="Overlay0" Color="#6c7086"/>
        <SolidColorBrush x:Key="Text"     Color="#cdd6f4"/>
        <SolidColorBrush x:Key="Subtext0" Color="#a6adc8"/>
        <SolidColorBrush x:Key="Subtext1" Color="#bac2de"/>
        <SolidColorBrush x:Key="Red"      Color="#f38ba8"/>
        <SolidColorBrush x:Key="Maroon"   Color="#eba0ac"/>
        <SolidColorBrush x:Key="Peach"    Color="#fab387"/>
        <SolidColorBrush x:Key="Yellow"   Color="#f9e2af"/>
        <SolidColorBrush x:Key="Green"    Color="#a6e3a1"/>
        <SolidColorBrush x:Key="Teal"     Color="#94e2d5"/>
        <SolidColorBrush x:Key="Sky"      Color="#89dceb"/>
        <SolidColorBrush x:Key="Blue"     Color="#89b4fa"/>
        <SolidColorBrush x:Key="Lavender" Color="#b4befe"/>
        <SolidColorBrush x:Key="Mauve"    Color="#cba6f7"/>
        <SolidColorBrush x:Key="Pink"     Color="#f5c2e7"/>

        <!-- Scrollbar dark -->
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="#1e1e2e"/>
            <Setter Property="Width" Value="8"/>
        </Style>

        <!-- Base button -->
        <Style x:Key="BaseButton" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Background" Value="{StaticResource Surface0}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Surface1}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,10"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8"
                                SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#45475a"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="#89b4fa"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#585b70"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Primary action button (bigger, accent) -->
        <Style x:Key="PrimaryAction" TargetType="Button" BasedOn="{StaticResource BaseButton}">
            <Setter Property="Padding" Value="18,14"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
        </Style>

        <!-- Danger action -->
        <Style x:Key="DangerAction" TargetType="Button" BasedOn="{StaticResource PrimaryAction}">
            <Setter Property="Background" Value="#3b1f2e"/>
            <Setter Property="BorderBrush" Value="#f38ba8"/>
            <Setter Property="Foreground" Value="#f38ba8"/>
        </Style>

        <!-- Success action -->
        <Style x:Key="SuccessAction" TargetType="Button" BasedOn="{StaticResource PrimaryAction}">
            <Setter Property="Background" Value="#1e3329"/>
            <Setter Property="BorderBrush" Value="#a6e3a1"/>
            <Setter Property="Foreground" Value="#a6e3a1"/>
        </Style>

        <!-- Title bar icon button -->
        <Style x:Key="ChromeButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
            <Setter Property="Width" Value="44"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#45475a"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Close button (red hover) -->
        <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource ChromeButton}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#f38ba8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Status tile container -->
        <Style x:Key="Tile" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource Mantle}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Surface0}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Padding" Value="16"/>
            <Setter Property="Margin" Value="6"/>
        </Style>

        <!-- Section header -->
        <Style x:Key="SectionHeader" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="{StaticResource Subtext0}"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
            <Setter Property="Text" Value=""/>
        </Style>

        <!-- TextBox dark -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource Crust}"/>
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Surface0}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8"/>
            <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
        </Style>

        <!-- RichTextBox dark for log -->
        <Style TargetType="RichTextBox">
            <Setter Property="Background" Value="{StaticResource Crust}"/>
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Surface0}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="IsDocumentEnabled" Value="True"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>

        <!-- Progress bar -->
        <Style TargetType="ProgressBar">
            <Setter Property="Background" Value="{StaticResource Surface0}"/>
            <Setter Property="Foreground" Value="{StaticResource Mauve}"/>
            <Setter Property="Height" Value="4"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
    </Window.Resources>

    <Border CornerRadius="0" Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="44"/>    <!-- title bar -->
                <RowDefinition Height="Auto"/>  <!-- tamper banner -->
                <RowDefinition Height="*"/>     <!-- body -->
                <RowDefinition Height="40"/>    <!-- status bar -->
            </Grid.RowDefinitions>

            <!-- ============ TITLE BAR ============ -->
            <Border x:Name="titleBar" Grid.Row="0" Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface0}" BorderThickness="0,0,0,1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
                        <Border Width="26" Height="26" CornerRadius="6" Background="#f38ba8">
                            <TextBlock Text="D" Foreground="White" FontWeight="Bold" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text="DisableDefender" Foreground="{StaticResource Text}" FontSize="14" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="versionText" Text="v0.0.7" Foreground="{StaticResource Overlay0}" FontSize="11" Margin="8,2,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" Orientation="Horizontal">
                        <Button x:Name="btnMin" Style="{StaticResource ChromeButton}" Content="&#xE921;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Text}" ToolTip="Minimize"/>
                        <Button x:Name="btnClose" Style="{StaticResource CloseButton}" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Text}" ToolTip="Close"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- ============ TAMPER PROTECTION BANNER ============ -->
            <Border x:Name="tamperBanner" Grid.Row="1" Background="#3b1f2e" BorderBrush="#f38ba8" BorderThickness="0,0,0,1" Padding="16,10" Visibility="Collapsed">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Vertical">
                        <TextBlock Text="Tamper Protection is ON" FontWeight="SemiBold" Foreground="{StaticResource Red}" FontSize="13"/>
                        <TextBlock Text="Disable Tamper Protection in Windows Security first. No scripted bypass exists on 24H2+." Foreground="{StaticResource Subtext1}" FontSize="11" Margin="0,2,0,0"/>
                    </StackPanel>
                    <Button x:Name="btnOpenSecurity" Grid.Column="1" Style="{StaticResource BaseButton}" Content="Open Windows Security" Padding="12,6" FontSize="12"/>
                </Grid>
            </Border>

            <!-- ============ BODY ============ -->
            <Grid Grid.Row="2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="280"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- LEFT RAIL -->
                <Border Grid.Column="0" Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface0}" BorderThickness="0,0,1,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Overall status indicator -->
                        <Border Grid.Row="0" Margin="16,20,16,10" Padding="14" CornerRadius="10" Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}" BorderThickness="1">
                            <StackPanel>
                                <TextBlock Text="OVERALL" Style="{StaticResource SectionHeader}"/>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="overallDot" Width="14" Height="14" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="overallLabel" Text="Checking..." Margin="10,0,0,0" Foreground="{StaticResource Text}" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                </StackPanel>
                                <TextBlock x:Name="overallSubLabel" Text="" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>

                        <!-- Actions -->
                        <StackPanel Grid.Row="1" Margin="16,14,16,0">
                            <TextBlock Text="ACTIONS" Style="{StaticResource SectionHeader}"/>
                            <Button x:Name="btnDisable" Style="{StaticResource PrimaryAction}" Content="Disable Defender"/>
                            <Button x:Name="btnRemove"  Style="{StaticResource DangerAction}"  Content="Full Remove"/>
                            <Button x:Name="btnRestore" Style="{StaticResource SuccessAction}" Content="Restore Defender"/>
                            <Button x:Name="btnRefresh" Style="{StaticResource PrimaryAction}" Content="Refresh Status"/>
                        </StackPanel>

                        <!-- System info -->
                        <Border Grid.Row="2" Margin="16,0,16,16" Padding="14" CornerRadius="10" Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}" BorderThickness="1">
                            <StackPanel>
                                <TextBlock Text="SYSTEM" Style="{StaticResource SectionHeader}"/>
                                <Grid Margin="0,0,0,4">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="OS Build" Foreground="{StaticResource Subtext0}" FontSize="11"/>
                                    <TextBlock Grid.Column="1" x:Name="sysOsText" Text="-" Foreground="{StaticResource Text}" FontSize="11"/>
                                </Grid>
                                <Grid Margin="0,0,0,4">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Safe Mode" Foreground="{StaticResource Subtext0}" FontSize="11"/>
                                    <TextBlock Grid.Column="1" x:Name="sysSafeText" Text="-" Foreground="{StaticResource Text}" FontSize="11"/>
                                </Grid>
                                <Grid Margin="0,0,0,4">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Elevated" Foreground="{StaticResource Subtext0}" FontSize="11"/>
                                    <TextBlock Grid.Column="1" x:Name="sysElevText" Text="Yes" Foreground="{StaticResource Green}" FontSize="11"/>
                                </Grid>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Tamper Prot." Foreground="{StaticResource Subtext0}" FontSize="11"/>
                                    <TextBlock Grid.Column="1" x:Name="sysTamperText" Text="-" Foreground="{StaticResource Text}" FontSize="11"/>
                                </Grid>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <!-- RIGHT PANE -->
                <Grid Grid.Column="1">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>   <!-- tiles -->
                        <RowDefinition Height="*"/>      <!-- log -->
                    </Grid.RowDefinitions>

                    <!-- Status tiles grid -->
                    <Grid Grid.Row="0" Margin="14,14,14,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Tile: Antivirus -->
                        <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource Tile}">
                            <StackPanel>
                                <TextBlock Text="ANTIVIRUS ENGINE" Style="{StaticResource SectionHeader}"/>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotAV" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valAV" Text="-" Margin="8,0,0,0" Foreground="{StaticResource Text}" FontSize="22" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subAV" Text="WinDefend service" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,6,0,0"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Real-time -->
                        <Border Grid.Row="0" Grid.Column="1" Style="{StaticResource Tile}">
                            <StackPanel>
                                <TextBlock Text="REAL-TIME PROTECTION" Style="{StaticResource SectionHeader}"/>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotRT" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valRT" Text="-" Margin="8,0,0,0" Foreground="{StaticResource Text}" FontSize="22" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subRT" Text="Behavior + IOAV + script scan" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,6,0,0"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Tamper Protection -->
                        <Border Grid.Row="0" Grid.Column="2" Style="{StaticResource Tile}">
                            <StackPanel>
                                <TextBlock Text="TAMPER PROTECTION" Style="{StaticResource SectionHeader}"/>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotTP" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valTP" Text="-" Margin="8,0,0,0" Foreground="{StaticResource Text}" FontSize="22" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subTP" Text="Must be OFF to proceed" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,6,0,0"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Firewall -->
                        <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource Tile}">
                            <StackPanel>
                                <TextBlock Text="FIREWALL" Style="{StaticResource SectionHeader}"/>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotFW" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valFW" Text="-" Margin="8,0,0,0" Foreground="{StaticResource Text}" FontSize="22" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subFW" Text="mpssvc + BFE preserved" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,6,0,0"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Services -->
                        <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource Tile}">
                            <StackPanel>
                                <TextBlock Text="DEFENDER SERVICES" Style="{StaticResource SectionHeader}"/>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotSvc" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valSvc" Text="-" Margin="8,0,0,0" Foreground="{StaticResource Text}" FontSize="22" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subSvc" Text="Disabled / Total" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,6,0,0"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Passive Mode -->
                        <Border Grid.Row="1" Grid.Column="2" Style="{StaticResource Tile}">
                            <StackPanel>
                                <TextBlock Text="MAPS TELEMETRY" Style="{StaticResource SectionHeader}"/>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotMAPS" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valMAPS" Text="-" Margin="8,0,0,0" Foreground="{StaticResource Text}" FontSize="22" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subMAPS" Text="Cloud-based protection" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,6,0,0"/>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <!-- Log panel -->
                    <Border Grid.Row="1" Margin="20,6,20,10" CornerRadius="10" Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface0}" BorderThickness="1">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Grid Grid.Row="0" Margin="14,10">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="LIVE LOG" Foreground="{StaticResource Subtext0}" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" Orientation="Horizontal">
                                    <Button x:Name="btnCopyLog" Style="{StaticResource BaseButton}" Content="Copy" Padding="10,4" FontSize="11" Margin="0,0,6,0"/>
                                    <Button x:Name="btnExportLog" Style="{StaticResource BaseButton}" Content="Export" Padding="10,4" FontSize="11" Margin="0,0,6,0"/>
                                    <Button x:Name="btnClearLog" Style="{StaticResource BaseButton}" Content="Clear" Padding="10,4" FontSize="11"/>
                                </StackPanel>
                            </Grid>
                            <RichTextBox x:Name="logBox" Grid.Row="1" Margin="14,0,14,14" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                <FlowDocument>
                                    <Paragraph x:Name="logPara" Margin="0"/>
                                </FlowDocument>
                            </RichTextBox>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>

            <!-- ============ STATUS BAR ============ -->
            <Border Grid.Row="3" Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface0}" BorderThickness="0,1,0,0">
                <Grid Margin="16,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="200"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <ProgressBar Grid.Column="0" x:Name="progressBar" IsIndeterminate="False" VerticalAlignment="Center" Width="180"/>
                    <TextBlock Grid.Column="1" x:Name="statusText" Text="Idle" Foreground="{StaticResource Subtext0}" FontSize="12" VerticalAlignment="Center" Margin="14,0,0,0"/>
                    <TextBlock Grid.Column="2" x:Name="footerText" Text="firewall preserved" Foreground="{StaticResource Overlay0}" FontSize="11" VerticalAlignment="Center"/>
                </Grid>
            </Border>

            <!-- ============ TOAST OVERLAY ============ -->
            <Border x:Name="toast" Grid.Row="2" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,24,24"
                    Background="{StaticResource Mantle}" BorderBrush="{StaticResource Mauve}" BorderThickness="1" CornerRadius="10"
                    Padding="16,12" MaxWidth="360" Visibility="Collapsed">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="toastDot" Width="8" Height="8" Fill="{StaticResource Mauve}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="toastText" Text="" Foreground="{StaticResource Text}" FontSize="13" Margin="12,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <!-- ============ CONFIRMATION OVERLAY ============ -->
            <Grid x:Name="confirmOverlay" Grid.Row="0" Grid.RowSpan="4" Background="#BB000000" Visibility="Collapsed">
                <Border Background="{StaticResource Base}" BorderBrush="{StaticResource Surface1}" BorderThickness="1" CornerRadius="12"
                        Padding="28" MaxWidth="520" HorizontalAlignment="Center" VerticalAlignment="Center">
                    <StackPanel>
                        <TextBlock x:Name="confirmTitle" Text="Confirm Action" Foreground="{StaticResource Text}" FontSize="18" FontWeight="SemiBold"/>
                        <TextBlock x:Name="confirmBody" Text="" Foreground="{StaticResource Subtext1}" FontSize="13" Margin="0,10,0,0" TextWrapping="Wrap"/>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
                            <Button x:Name="btnConfirmCancel" Style="{StaticResource BaseButton}" Content="Cancel" Padding="18,8" Margin="0,0,10,0"/>
                            <Button x:Name="btnConfirmOk" Style="{StaticResource DangerAction}" Content="Proceed" Padding="18,8" Margin="0"/>
                        </StackPanel>
                    </StackPanel>
                </Border>
            </Grid>
        </Grid>
    </Border>
</Window>
'@

# ---------------------------------------------------------------------------
# Parse XAML
# ---------------------------------------------------------------------------
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Lookup table for named elements
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $name = $_.Attributes['x:Name'].Value
    if ($name) { $ui[$name] = $window.FindName($name) }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Set-TileState {
    param(
        [string]$DotName,
        [string]$ValName,
        [string]$SubName,
        $Value,
        [string]$GoodText = 'OFF',
        [string]$BadText  = 'ON',
        [switch]$InvertColor,   # when "ON" means bad
        [string]$SubText
    )
    $dot = $ui[$DotName]; $val = $ui[$ValName]; $sub = $ui[$SubName]
    if ($null -eq $val) { return }
    if ($null -eq $Value) {
        $val.Text = 'N/A'
        $dot.Fill = $window.Resources['Overlay0']
        if ($SubText) { $sub.Text = $SubText }
        return
    }
    $isOn = [bool]$Value
    if ($isOn) {
        $val.Text = $BadText
        $dot.Fill = if ($InvertColor) { $window.Resources['Red'] } else { $window.Resources['Green'] }
    } else {
        $val.Text = $GoodText
        $dot.Fill = if ($InvertColor) { $window.Resources['Green'] } else { $window.Resources['Overlay0'] }
    }
    if ($SubText) { $sub.Text = $SubText }
}

function Show-Toast {
    param([string]$Message, [ValidateSet('info','ok','warn','error')][string]$Kind = 'info')
    $ui.toastText.Text = $Message
    $border = $ui.toast
    $dot    = $ui.toastDot
    switch ($Kind) {
        'ok'    { $border.BorderBrush = $window.Resources['Green'];  $dot.Fill = $window.Resources['Green'] }
        'warn'  { $border.BorderBrush = $window.Resources['Yellow']; $dot.Fill = $window.Resources['Yellow'] }
        'error' { $border.BorderBrush = $window.Resources['Red'];    $dot.Fill = $window.Resources['Red'] }
        default { $border.BorderBrush = $window.Resources['Mauve'];  $dot.Fill = $window.Resources['Mauve'] }
    }
    $border.Opacity = 0
    $border.Visibility = 'Visible'
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 1, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(200))
    $border.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
    # Auto-hide after 4s
    $tmr = New-Object System.Windows.Threading.DispatcherTimer
    $tmr.Interval = [TimeSpan]::FromSeconds(4)
    $tmr.Add_Tick({
        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(300))
        $fadeOut.add_Completed({ $ui.toast.Visibility = 'Collapsed' }.GetNewClosure())
        $ui.toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
        $this.Stop()
    })
    $tmr.Start()
}

function Show-Confirm {
    param([string]$Title, [string]$Body, [scriptblock]$OnProceed)
    $ui.confirmTitle.Text = $Title
    $ui.confirmBody.Text  = $Body
    $script:ConfirmAction = $OnProceed
    $ui.confirmOverlay.Visibility = 'Visible'
}

function Add-LogEntry {
    param($Entry)
    $para = $ui.logPara
    $run = New-Object System.Windows.Documents.Run
    $color = switch ($Entry.Level) {
        'OK'    { '#a6e3a1' }
        'WARN'  { '#f9e2af' }
        'ERROR' { '#f38ba8' }
        'DEBUG' { '#6c7086' }
        default { '#cdd6f4' }
    }
    $run.Text = "[{0}] [{1}] {2}`r`n" -f $Entry.Time, $Entry.Level.PadRight(5), $Entry.Message
    $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($color)
    if ($Entry.Level -eq 'OK' -or $Entry.Level -eq 'ERROR') {
        $run.FontWeight = 'SemiBold'
    }
    $para.Inlines.Add($run)
    $ui.logBox.ScrollToEnd()
}

function Set-Busy {
    param([bool]$IsBusy, [string]$Label = 'Idle')
    $script:UIState.Busy = $IsBusy
    $ui.statusText.Text = $Label
    $ui.progressBar.IsIndeterminate = $IsBusy
    $ui.btnDisable.IsEnabled = -not $IsBusy
    $ui.btnRemove.IsEnabled  = -not $IsBusy
    $ui.btnRestore.IsEnabled = -not $IsBusy
    $ui.btnRefresh.IsEnabled = -not $IsBusy
}

# ---------------------------------------------------------------------------
# Status polling (runs on UI thread; lightweight enough)
# ---------------------------------------------------------------------------
function Update-StatusTiles {
    try {
        $mp = $null
        try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {}

        if ($mp) {
            Set-TileState -DotName dotAV  -ValName valAV  -SubName subAV  -Value $mp.AntivirusEnabled -GoodText 'OFF' -BadText 'ON' -SubText 'Antivirus engine state'
            Set-TileState -DotName dotRT  -ValName valRT  -SubName subRT  -Value $mp.RealTimeProtectionEnabled -GoodText 'OFF' -BadText 'ON' -SubText 'Real-time monitoring'
            Set-TileState -DotName dotTP  -ValName valTP  -SubName subTP  -Value $mp.IsTamperProtected -GoodText 'OFF' -BadText 'ON' -InvertColor -SubText 'Required OFF to modify'
        } else {
            Set-TileState -DotName dotAV -ValName valAV -SubName subAV -Value $null -SubText 'Defender query failed'
            Set-TileState -DotName dotRT -ValName valRT -SubName subRT -Value $null -SubText 'Defender query failed'
            Set-TileState -DotName dotTP -ValName valTP -SubName subTP -Value $null -SubText 'Cannot read TP state'
        }

        # MAPS
        try {
            $pref = Get-MpPreference -ErrorAction Stop
            $mapsOn = $pref.MAPSReporting -ne 'Disabled' -and $pref.MAPSReporting -ne 0
            Set-TileState -DotName dotMAPS -ValName valMAPS -SubName subMAPS -Value $mapsOn -GoodText 'OFF' -BadText 'ON' -SubText "MAPS = $($pref.MAPSReporting)"
        } catch {
            Set-TileState -DotName dotMAPS -ValName valMAPS -SubName subMAPS -Value $null -SubText 'Unknown'
        }

        # Firewall
        try {
            $fwp = Get-NetFirewallProfile -ErrorAction Stop
            $allOn = $fwp | ForEach-Object { $_.Enabled } | Where-Object { -not $_ } | Measure-Object | Select-Object -ExpandProperty Count
            $fwOn  = $allOn -eq 0
            $ui.dotFW.Fill = if ($fwOn) { $window.Resources['Green'] } else { $window.Resources['Red'] }
            $ui.valFW.Text = if ($fwOn) { 'ON' } else { 'PARTIAL' }
            $prof = ($fwp | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ', '
            $ui.subFW.Text = $prof
        } catch {
            $ui.dotFW.Fill = $window.Resources['Overlay0']; $ui.valFW.Text = 'N/A'
        }

        # Services disabled count
        $allSvcs = $script:DefenderServices + $script:MDEServices
        $total = $allSvcs.Count
        $disabled = 0
        $present = 0
        foreach ($s in $allSvcs) {
            $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
            if ($sv) {
                $present++
                if ($sv.StartType -eq 'Disabled') { $disabled++ }
            }
        }
        $ui.valSvc.Text = "$disabled / $present"
        $ui.subSvc.Text = "$total known; $present present"
        if ($present -gt 0 -and $disabled -eq $present) { $ui.dotSvc.Fill = $window.Resources['Green'] }
        elseif ($disabled -gt 0) { $ui.dotSvc.Fill = $window.Resources['Yellow'] }
        else { $ui.dotSvc.Fill = $window.Resources['Red'] }

        # Overall
        if ($mp -and $mp.IsTamperProtected) {
            $ui.overallDot.Fill = $window.Resources['Yellow']
            $ui.overallLabel.Text = 'BLOCKED'
            $ui.overallSubLabel.Text = 'Disable Tamper Protection to continue'
            $ui.tamperBanner.Visibility = 'Visible'
        } elseif ($mp -and $mp.RealTimeProtectionEnabled) {
            $ui.overallDot.Fill = $window.Resources['Green']
            $ui.overallLabel.Text = 'PROTECTED'
            $ui.overallSubLabel.Text = 'Defender is active'
            $ui.tamperBanner.Visibility = 'Collapsed'
        } elseif ($mp -and -not $mp.RealTimeProtectionEnabled) {
            $ui.overallDot.Fill = $window.Resources['Red']
            $ui.overallLabel.Text = 'DISABLED'
            $ui.overallSubLabel.Text = 'Real-time protection is off'
            $ui.tamperBanner.Visibility = 'Collapsed'
        } else {
            $ui.overallDot.Fill = $window.Resources['Overlay0']
            $ui.overallLabel.Text = 'UNKNOWN'
            $ui.overallSubLabel.Text = 'Defender may be removed'
            $ui.tamperBanner.Visibility = 'Collapsed'
        }

        # System info
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $ui.sysOsText.Text = "$($os.Version) $($os.BuildNumber)"
        } catch { $ui.sysOsText.Text = '-' }
        try {
            $bs = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).BootupState
            if ($bs -like '*Fail-safe*') { $ui.sysSafeText.Text = 'YES'; $ui.sysSafeText.Foreground = $window.Resources['Peach'] }
            else { $ui.sysSafeText.Text = 'No'; $ui.sysSafeText.Foreground = $window.Resources['Subtext1'] }
        } catch {}
        if ($mp) {
            $ui.sysTamperText.Text = if ($mp.IsTamperProtected) { 'ON' } else { 'Off' }
            $ui.sysTamperText.Foreground = if ($mp.IsTamperProtected) { $window.Resources['Red'] } else { $window.Resources['Green'] }
        }
    } catch {
        Write-Log "Status refresh error: $_" WARN
    }
}

# ---------------------------------------------------------------------------
# Async worker - runspace with access to DisableDefender module
# ---------------------------------------------------------------------------
$script:Runspace = $null
$script:AsyncResult = $null
$script:AsyncPS = $null

function Start-ModeAsync {
    param([ValidateSet('Disable','Remove','Restore')][string]$ActionMode)
    if ($script:UIState.Busy) { return }
    Set-Busy -IsBusy $true -Label "Running $ActionMode..."
    Show-Toast "Starting $ActionMode..." info

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('UIState', $script:UIState)
    $rs.SessionStateProxy.SetVariable('ModulePath', $modulePath)
    $rs.SessionStateProxy.SetVariable('ActionMode', $ActionMode)
    $rs.SessionStateProxy.SetVariable('LogPath', $script:LogPath)

    $worker = {
        Import-Module -Name $ModulePath -Force -ErrorAction Stop
        $logCallback = {
            param(
                [Parameter(Mandatory)][string]$Message,
                [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO'
            )
            $stamp = (Get-Date).ToString('HH:mm:ss')
            $entry = [PSCustomObject]@{ Time = $stamp; Level = $Level; Message = $Message }
            $UIState.LogQueue.Enqueue($entry)
        }

        try {
            switch ($ActionMode) {
                'Disable' { Invoke-DisableDefender -Force -LogPath $LogPath -LogCallback $logCallback -Confirm:$false }
                'Remove'  { Invoke-RemoveDefender -Force -LogPath $LogPath -LogCallback $logCallback -Confirm:$false }
                'Restore' { Invoke-RestoreDefender -LogPath $LogPath -LogCallback $logCallback -Confirm:$false }
            }
            $UIState.LastResult = 'ok'
        } catch {
            & $logCallback -Message "FATAL: $_" -Level ERROR
            $UIState.LastResult = "error: $($_.Exception.Message)"
        }
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($worker)
    $script:AsyncPS = $ps
    $script:Runspace = $rs
    $script:AsyncResult = $ps.BeginInvoke()
    $script:UIState.LastAction = $ActionMode
    $script:UIState.LastResult = ''
}

# ---------------------------------------------------------------------------
# Dispatcher timer - drains log queue, checks for async completion
# ---------------------------------------------------------------------------
$drainTimer = New-Object System.Windows.Threading.DispatcherTimer
$drainTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$drainTimer.Add_Tick({
    # Drain log queue
    while ($script:UIState.LogQueue.Count -gt 0) {
        $entry = $script:UIState.LogQueue.Dequeue()
        Add-LogEntry $entry
    }
    # Check async completion
    if ($script:AsyncResult -and $script:AsyncResult.IsCompleted) {
        try { $script:AsyncPS.EndInvoke($script:AsyncResult) } catch { Write-Log "Worker error: $_" ERROR }
        $script:AsyncPS.Dispose()
        $script:Runspace.Close()
        $script:Runspace.Dispose()
        $script:AsyncResult = $null
        $script:AsyncPS = $null
        $script:Runspace = $null

        $result = $script:UIState.LastResult
        $action = $script:UIState.LastAction
        Set-Busy -IsBusy $false -Label 'Idle'
        if ($result -eq 'ok') {
            Show-Toast "$action complete." ok
        } else {
            Show-Toast "$action failed. $result" error
        }
        Update-StatusTiles
    }
})
$drainTimer.Start()

# ---------------------------------------------------------------------------
# Status refresh timer (every 5s when idle)
# ---------------------------------------------------------------------------
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(5)
$statusTimer.Add_Tick({
    if (-not $script:UIState.Busy) { Update-StatusTiles }
})
$statusTimer.Start()

# ---------------------------------------------------------------------------
# Event wiring
# ---------------------------------------------------------------------------
$ui.titleBar.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ClickCount -eq 1) { $window.DragMove() } })
$ui.btnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.btnClose.Add_Click({ $window.Close() })

# Confirmation modal buttons - registered once
$ui.btnConfirmCancel.Add_Click({ $ui.confirmOverlay.Visibility = 'Collapsed'; $script:ConfirmAction = $null })
$window.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape' -and $ui.confirmOverlay.Visibility -eq 'Visible') {
        $ui.confirmOverlay.Visibility = 'Collapsed'
        $script:ConfirmAction = $null
        $e.Handled = $true
    }
})
$ui.btnConfirmOk.Add_Click({
    $ui.confirmOverlay.Visibility = 'Collapsed'
    if ($script:ConfirmAction) {
        $action = $script:ConfirmAction
        $script:ConfirmAction = $null
        & $action
    }
})

$ui.btnOpenSecurity.Add_Click({
    Start-Process 'windowsdefender:' -ErrorAction SilentlyContinue
})

$ui.btnRefresh.Add_Click({
    Update-StatusTiles
    Show-Toast 'Status refreshed.' info
})

$ui.btnDisable.Add_Click({
    Show-Confirm -Title 'Disable Microsoft Defender?' -Body "This will apply policy keys, disable services, and turn off real-time protection. Reversible via Restore.`n`nYour firewall will not be touched." -OnProceed {
        Start-ModeAsync -ActionMode 'Disable'
    }
})

$ui.btnRemove.Add_Click({
    Show-Confirm -Title 'FULL REMOVE Microsoft Defender?' -Body "This is aggressive. It will:`n  - Apply all Disable operations`n  - Deprovision the Windows Security UI app`n  - Remove SafeBoot\WinDefend so it cannot load even in Safe Mode`n  - DISM-remove platform packages`n`nBest run from Safe Mode. Restore mode may require sfc/DISM to fully repair. Firewall preserved." -OnProceed {
        Start-ModeAsync -ActionMode 'Remove'
    }
})

$ui.btnRestore.Add_Click({
    Show-Confirm -Title 'Restore Microsoft Defender?' -Body "This will clear all policy overrides, re-enable services, and reprovision the Windows Security app." -OnProceed {
        Start-ModeAsync -ActionMode 'Restore'
    }
})

$ui.btnCopyLog.Add_Click({
    $range = New-Object System.Windows.Documents.TextRange $ui.logBox.Document.ContentStart, $ui.logBox.Document.ContentEnd
    [System.Windows.Clipboard]::SetText($range.Text)
    Show-Toast 'Log copied to clipboard.' ok
})

$ui.btnExportLog.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Log files|*.log|Text files|*.txt|All files|*.*'
    $dlg.FileName = "DisableDefender-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    if ($dlg.ShowDialog($window)) {
        $range = New-Object System.Windows.Documents.TextRange $ui.logBox.Document.ContentStart, $ui.logBox.Document.ContentEnd
        Set-Content -LiteralPath $dlg.FileName -Value $range.Text -Encoding UTF8
        Show-Toast "Log exported to $($dlg.FileName)" ok
    }
})

$ui.btnClearLog.Add_Click({
    $ui.logPara.Inlines.Clear()
    Show-Toast 'Log cleared.' info
})

# ---------------------------------------------------------------------------
# Initial render
# ---------------------------------------------------------------------------
$ui.versionText.Text = "v$script:Version"
Write-Log "=== $script:AppName GUI v$script:Version ready ==="
Update-StatusTiles

# Drain any pre-window log messages
while ($script:UIState.LogQueue.Count -gt 0) {
    Add-LogEntry ($script:UIState.LogQueue.Dequeue())
}

# ---------------------------------------------------------------------------
# Show window
# ---------------------------------------------------------------------------
$window.Add_Closed({
    $drainTimer.Stop()
    $statusTimer.Stop()
    if ($script:AsyncPS) { try { $script:AsyncPS.Stop() } catch {} }
})

$null = $window.ShowDialog()
