#Requires -Version 5.1
<#
    DisableDefender GUI v0.0.40
    Safety-first WPF control center for the DisableDefender module

    Features:
      - Graphite/navy operations palette with accessible state hierarchy
      - Live status tiles plus per-component lockdown/PPL dashboard
      - Live policy edit stream with direct, ACL, and SYSTEM method icons
      - Always-on firewall integrity banner with guard-trip flash
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
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace DisableDefenderGui -Name IconCtl -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr hIcon);
'@ -ErrorAction SilentlyContinue

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
$requestedPresentationCulture = if ([string]::IsNullOrWhiteSpace($env:DISABLEDEFENDER_CULTURE)) {
    'en-US'
} else {
    $env:DISABLEDEFENDER_CULTURE
}
$script:Presentation = Set-DefenderPresentationCulture -Culture $requestedPresentationCulture
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
    LastResult = $null
    StatusSnapshot = $null
    CancellationRequested = $false
    CancellationState = 'Idle'
    WorkerState = 'Idle'
    RunId = $null
    RecoveryBusy = $false
    RecoveryCancellationRequested = $false
    RecoveryWorkerState = 'Idle'
    RecoveryResult = $null
    RecoveryRunId = $null
    RecoveryCanResume = $false
    RecoveryCanRollback = $false
})
$script:ToastTimers = New-Object System.Collections.ArrayList
$script:TrayIcon = $null
$script:TrayContextMenu = $null
$script:TrayStatusIcons = New-Object System.Collections.ArrayList

# Override Write-Log in the main scope so Get-DefenderStatus calls from UI thread queue too.
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO',
        [string]$MessageId = 'legacy'
    )
    $now = Get-Date
    $stamp = $now.ToString('HH:mm:ss')
    $entry = [PSCustomObject]@{
        Time      = $stamp
        Level     = $Level
        MessageId = $MessageId
        Message   = $Message
    }
    $script:UIState.LogQueue.Enqueue($entry)
    $fileLine = "[$($now.ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    try { Add-Content -LiteralPath $script:LogPath -Value $fileLine -ErrorAction Stop } catch {}
    $jsonlTarget = Join-Path (Split-Path -Parent $script:LogPath) "$script:AppName.jsonl"
    try {
        $jsonEntry = [ordered]@{
            SchemaVersion = 1
            ts            = $now.ToString('o')
            level         = $Level
            message_id    = $MessageId
            msg           = $Message
        } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $jsonlTarget -Value $jsonEntry -ErrorAction Stop
    } catch {}
}

# ---------------------------------------------------------------------------
# XAML - safety-first graphite control center
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DisableDefender"
        Width="1280" Height="820"
        MinWidth="1100" MinHeight="700"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        ResizeMode="CanResize"
        Background="#0B1220"
        FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType"
        KeyboardNavigation.TabNavigation="Cycle"
        AutomationProperties.Name="DisableDefender security control center">

    <Window.Resources>
        <!-- Graphite/navy palette -->
        <SolidColorBrush x:Key="Base"     Color="#0B1220"/>
        <SolidColorBrush x:Key="Mantle"   Color="#101A2A"/>
        <SolidColorBrush x:Key="Crust"    Color="#070D17"/>
        <SolidColorBrush x:Key="Surface0" Color="#26354A"/>
        <SolidColorBrush x:Key="Surface1" Color="#3A4B65"/>
        <SolidColorBrush x:Key="Surface2" Color="#50627F"/>
        <SolidColorBrush x:Key="Overlay0" Color="#8492AA"/>
        <SolidColorBrush x:Key="Text"     Color="#F3F6FB"/>
        <SolidColorBrush x:Key="Subtext0" Color="#B5C0D2"/>
        <SolidColorBrush x:Key="Subtext1" Color="#D2D9E5"/>
        <SolidColorBrush x:Key="FirewallOkBg"  Color="#10271F"/>
        <SolidColorBrush x:Key="FirewallBadBg" Color="#321923"/>
        <SolidColorBrush x:Key="Red"      Color="#FF7088"/>
        <SolidColorBrush x:Key="Maroon"   Color="#F48C9D"/>
        <SolidColorBrush x:Key="Peach"    Color="#FFB86B"/>
        <SolidColorBrush x:Key="Yellow"   Color="#FFC857"/>
        <SolidColorBrush x:Key="Green"    Color="#56D97B"/>
        <SolidColorBrush x:Key="Teal"     Color="#5AD5C7"/>
        <SolidColorBrush x:Key="Sky"      Color="#67C8FF"/>
        <SolidColorBrush x:Key="Blue"     Color="#6EA8FE"/>
        <SolidColorBrush x:Key="Lavender" Color="#AEBEFF"/>
        <SolidColorBrush x:Key="Mauve"    Color="#A493FF"/>
        <SolidColorBrush x:Key="Pink"     Color="#F1A3DB"/>

        <!-- Scrollbar dark -->
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="#0B1220"/>
            <Setter Property="Width" Value="8"/>
        </Style>

        <!-- Base button -->
        <Style x:Key="BaseButton" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Background" Value="{StaticResource Surface0}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Surface1}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,9"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="7"
                                SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                              Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#31415A"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="#6EA8FE"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#42536F"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="#AEBEFF"/>
                                <Setter TargetName="bd" Property="BorderThickness" Value="2"/>
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
            <Setter Property="Padding" Value="14,11"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="MinHeight" Value="50"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>

        <!-- Danger action -->
        <Style x:Key="DangerAction" TargetType="Button" BasedOn="{StaticResource PrimaryAction}">
            <Setter Property="Background" Value="#2D1821"/>
            <Setter Property="BorderBrush" Value="#FF7088"/>
            <Setter Property="Foreground" Value="#FF8DA1"/>
        </Style>

        <!-- Success action -->
        <Style x:Key="SuccessAction" TargetType="Button" BasedOn="{StaticResource PrimaryAction}">
            <Setter Property="Background" Value="#14281D"/>
            <Setter Property="BorderBrush" Value="#56D97B"/>
            <Setter Property="Foreground" Value="#71E18E"/>
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
                        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#45475a"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Lavender}"/>
                                <Setter TargetName="bd" Property="BorderThickness" Value="2"/>
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
                        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#f38ba8"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Red}"/>
                                <Setter TargetName="bd" Property="BorderThickness" Value="2"/>
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
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="15"/>
            <Setter Property="Margin" Value="5"/>
        </Style>

        <!-- Section header -->
        <Style x:Key="SectionHeader" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="{StaticResource Subtext1}"/>
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
            <Style.Triggers>
                <Trigger Property="IsKeyboardFocused" Value="True">
                    <Setter Property="BorderBrush" Value="{StaticResource Lavender}"/>
                    <Setter Property="BorderThickness" Value="2"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Target selector with an explicit keyboard-focus state. -->
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="{StaticResource Crust}"/>
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Surface0}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="DropDownToggle" Background="{TemplateBinding Background}"
                                          BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                                          IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press" Focusable="False">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                                            <Path Data="M 0 0 L 8 0 L 4 5 Z" Fill="{StaticResource Subtext1}"
                                                  Width="8" Height="5" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,9,0"/>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Margin="8,0,28,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              TextElement.Foreground="{TemplateBinding Foreground}"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom" PlacementTarget="{Binding ElementName=DropDownToggle}"
                                   IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" StaysOpen="False" Focusable="False">
                                <Border Background="{StaticResource Crust}" BorderBrush="{StaticResource Surface1}" BorderThickness="1"
                                        Padding="2" MinWidth="150">
                                    <ScrollViewer CanContentScroll="True" SnapsToDevicePixels="True">
                                        <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsKeyboardFocusWithin" Value="True">
                    <Setter Property="BorderBrush" Value="{StaticResource Lavender}"/>
                    <Setter Property="BorderThickness" Value="2"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Background" Value="{StaticResource Crust}"/>
            <Setter Property="Padding" Value="8,5"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="{StaticResource Surface1}"/>
                    <Setter Property="Foreground" Value="{StaticResource Text}"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{StaticResource Surface0}"/>
                    <Setter Property="Foreground" Value="{StaticResource Text}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Accessible dark checkbox -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource Subtext1}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border x:Name="checkBox" Width="18" Height="18" CornerRadius="3" Background="{StaticResource Crust}"
                                    BorderBrush="{StaticResource Surface2}" BorderThickness="1" VerticalAlignment="Center">
                                <Path x:Name="checkMark" Data="M3,8 L7,12 L15,4" Stroke="{StaticResource Base}" StrokeThickness="2"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter Grid.Column="1" Margin="9,0,0,0" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="checkBox" Property="Background" Value="{StaticResource Red}"/>
                                <Setter TargetName="checkBox" Property="BorderBrush" Value="{StaticResource Red}"/>
                                <Setter TargetName="checkMark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="checkBox" Property="BorderBrush" Value="{StaticResource Lavender}"/>
                                <Setter TargetName="checkBox" Property="BorderThickness" Value="2"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
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
            <Setter Property="Foreground" Value="{StaticResource Blue}"/>
            <Setter Property="Height" Value="4"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
    </Window.Resources>

    <Border x:Name="appRoot" CornerRadius="0" Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="52"/>    <!-- title bar -->
                <RowDefinition Height="Auto"/>  <!-- tamper banner -->
                <RowDefinition Height="Auto"/>  <!-- firewall banner -->
                <RowDefinition Height="*"/>     <!-- body -->
                <RowDefinition Height="40"/>    <!-- status bar -->
            </Grid.RowDefinitions>

            <!-- ============ TITLE BAR ============ -->
            <Border x:Name="titleBar" Grid.Row="0" Background="#0C1524" BorderBrush="{StaticResource Surface0}" BorderThickness="0,0,0,1">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
                        <Viewbox Width="26" Height="26" Margin="0,0,10,0" AutomationProperties.Name="DisableDefender shield">
                            <Grid Width="24" Height="24">
                                <Path Data="M12,1.5 L21,5.1 L21,11.1 C21,16.7 17.4,20.7 12,22.7 C6.6,20.7 3,16.7 3,11.1 L3,5.1 Z"
                                      Fill="{StaticResource Text}"/>
                                <TextBlock Text="D" Foreground="{StaticResource Base}" FontWeight="Bold" FontSize="10.5"
                                           HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,1"/>
                            </Grid>
                        </Viewbox>
                        <TextBlock Text="DisableDefender" Foreground="{StaticResource Text}" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        <TextBlock x:Name="versionText" Text="v0.0.40" Foreground="{StaticResource Overlay0}" FontSize="11" Margin="10,2,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" Orientation="Horizontal">
                        <Button x:Name="btnMin" Style="{StaticResource ChromeButton}" Content="&#xE921;" FontFamily="Segoe MDL2 Assets"
                                Foreground="{StaticResource Subtext1}" ToolTip="Minimize" AutomationProperties.Name="Minimize window"/>
                        <Button x:Name="btnMax" Style="{StaticResource ChromeButton}" Content="&#xE922;" FontFamily="Segoe MDL2 Assets"
                                Foreground="{StaticResource Subtext1}" ToolTip="Maximize" AutomationProperties.Name="Maximize window"/>
                        <Button x:Name="btnClose" Style="{StaticResource CloseButton}" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets"
                                Foreground="{StaticResource Subtext1}" ToolTip="Close" AutomationProperties.Name="Close window"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- ============ TAMPER PROTECTION BANNER ============ -->
            <Border x:Name="tamperBanner" Grid.Row="1" Background="{StaticResource FirewallBadBg}" BorderBrush="{StaticResource Red}"
                    BorderThickness="0,0,0,1" Padding="20,11" Visibility="Collapsed"
                    AutomationProperties.Name="Tamper Protection warning">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Vertical">
                        <TextBlock Text="Tamper Protection is blocking changes" FontWeight="SemiBold" Foreground="{StaticResource Red}" FontSize="13"/>
                        <TextBlock Text="Turn it off in Windows Security before continuing. DisableDefender will not attempt an unsupported bypass." Foreground="{StaticResource Subtext1}" FontSize="11" Margin="0,2,0,0"/>
                    </StackPanel>
                    <Button x:Name="btnOpenSecurity" Grid.Column="1" Style="{StaticResource BaseButton}" Content="Open Windows Security" Padding="12,6" FontSize="12"
                            AutomationProperties.Name="Open Windows Security"/>
                </Grid>
            </Border>

            <!-- ============ FIREWALL INTEGRITY BANNER ============ -->
            <Border x:Name="firewallBanner" Grid.Row="2" Margin="0" Background="{StaticResource FirewallOkBg}" BorderBrush="{StaticResource Green}"
                    BorderThickness="0,0,0,1" Padding="20,10" AutomationProperties.Name="Firewall integrity status">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Ellipse x:Name="firewallBannerDot" Grid.Column="0" Width="10" Height="10" Fill="{StaticResource Green}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="firewallBannerTitle" Text="Firewall integrity protected" FontWeight="SemiBold" Foreground="{StaticResource Green}" FontSize="12.5" VerticalAlignment="Center"/>
                        <TextBlock x:Name="firewallBannerText" Text="mpssvc and BFE guarded; firewall profiles enabled" Foreground="{StaticResource Subtext1}" FontSize="11.5" Margin="14,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- ============ BODY ============ -->
            <Grid Grid.Row="3">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="252"/>
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
                        <StackPanel Grid.Row="0" Margin="18,22,18,10">
                            <TextBlock Text="SECURITY STATE" Style="{StaticResource SectionHeader}"/>
                            <Border Padding="15" CornerRadius="8" Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}"
                                    BorderThickness="1" AutomationProperties.Name="Overall Defender state">
                                <StackPanel>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="42"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Border Grid.Column="0" Width="34" Height="38" CornerRadius="7" Background="#172338"
                                                BorderBrush="{StaticResource Surface1}" BorderThickness="1">
                                            <TextBlock Text="&#xE83D;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}"
                                                       FontSize="19" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                        <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                            <StackPanel Orientation="Horizontal">
                                                <Ellipse x:Name="overallDot" Width="11" Height="11" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="overallLabel" Text="CHECKING" Margin="9,0,0,0" Foreground="{StaticResource Text}"
                                                           FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                            </StackPanel>
                                            <TextBlock x:Name="overallSubLabel" Text="Reading Defender state" Foreground="{StaticResource Subtext0}"
                                                       FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Grid>
                                    <Border Margin="0,14,0,0" Padding="0,11,0,0" BorderBrush="{StaticResource Surface0}" BorderThickness="0,1,0,0">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock x:Name="railFirewallIcon" Text="&#xE83D;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="15" VerticalAlignment="Center"/>
                                            <TextBlock x:Name="railFirewallText" Text="Checking Firewall boundary" Foreground="{StaticResource Subtext1}" FontSize="11.5" Margin="9,0,0,0" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </Border>
                        </StackPanel>

                        <!-- Actions -->
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <StackPanel Margin="18,12,18,0">
                                <TextBlock Text="ACTIONS" Style="{StaticResource SectionHeader}"/>
                                <Button x:Name="btnDisable" Style="{StaticResource PrimaryAction}" AutomationProperties.Name="Disable Defender">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="28"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE83D;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Blue}" FontSize="17" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="labelDisable" Grid.Column="1" Text="Disable Defender" VerticalAlignment="Center"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="11" VerticalAlignment="Center"/>
                                </Grid>
                            </Button>
                            <Button x:Name="btnRemove" Style="{StaticResource DangerAction}" AutomationProperties.Name="Full Remove">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="28"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Red}" FontSize="17" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="labelRemove" Grid.Column="1" Text="Full Remove" VerticalAlignment="Center"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Red}" FontSize="11" VerticalAlignment="Center"/>
                                </Grid>
                            </Button>
                            <Button x:Name="btnRestore" Style="{StaticResource SuccessAction}" AutomationProperties.Name="Restore Defender">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="28"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE777;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Green}" FontSize="17" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="labelRestore" Grid.Column="1" Text="Restore Defender" VerticalAlignment="Center"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Green}" FontSize="11" VerticalAlignment="Center"/>
                                </Grid>
                            </Button>
                            <Button x:Name="btnRepair" Style="{StaticResource PrimaryAction}" AutomationProperties.Name="Repair Defender defaults">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="28"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE90F;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="17" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="labelRepair" Grid.Column="1" Text="Repair defaults" VerticalAlignment="Center"/>
                                    <TextBlock Grid.Column="2" Text="NO UNDO" Foreground="{StaticResource Overlay0}" FontSize="9" VerticalAlignment="Center"/>
                                </Grid>
                            </Button>
                            <Button x:Name="btnRefresh" Style="{StaticResource PrimaryAction}" AutomationProperties.Name="Refresh security status">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="28"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="17" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="labelRefresh" Grid.Column="1" Text="Refresh status" VerticalAlignment="Center"/>
                                    <TextBlock Grid.Column="2" Text="F5" Foreground="{StaticResource Overlay0}" FontSize="10" VerticalAlignment="Center"/>
                                </Grid>
                                </Button>
                            </StackPanel>
                        </ScrollViewer>

                        <!-- System info -->
                        <Border Grid.Row="2" Margin="18,0,18,18" Padding="14" CornerRadius="8" Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}"
                                BorderThickness="1" AutomationProperties.Name="System context">
                            <StackPanel>
                                <TextBlock Text="SYSTEM CONTEXT" Style="{StaticResource SectionHeader}"/>
                                <Grid Margin="0,0,0,6">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="OS build" Foreground="{StaticResource Subtext0}" FontSize="11"/>
                                    <TextBlock Grid.Column="1" x:Name="sysOsText" Text="-" Foreground="{StaticResource Subtext1}" FontSize="11"/>
                                </Grid>
                                <Grid Margin="0,0,0,6">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Safe mode" Foreground="{StaticResource Subtext0}" FontSize="11"/>
                                    <TextBlock Grid.Column="1" x:Name="sysSafeText" Text="-" Foreground="{StaticResource Subtext1}" FontSize="11"/>
                                </Grid>
                                <Grid Margin="0,0,0,6">
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
                                    <TextBlock Grid.Column="0" Text="Tamper protection" Foreground="{StaticResource Subtext0}" FontSize="11"/>
                                    <TextBlock Grid.Column="1" x:Name="sysTamperText" Text="-" Foreground="{StaticResource Subtext1}" FontSize="11"/>
                                </Grid>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <!-- RIGHT PANE -->
                <Grid Grid.Column="1">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>   <!-- workspace heading -->
                        <RowDefinition Height="Auto"/>   <!-- tiles -->
                        <RowDefinition Height="*"/>      <!-- component dashboard -->
                        <RowDefinition Height="112"/>    <!-- log -->
                    </Grid.RowDefinitions>

                    <!-- Workspace heading -->
                    <Grid Grid.Row="0" Margin="20,18,20,5">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Width="42" Height="42" CornerRadius="8" Background="#172338"
                                BorderBrush="{StaticResource Surface0}" BorderThickness="1" Margin="0,0,13,0">
                            <TextBlock Text="&#xE83D;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="22"
                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel Grid.Column="1" VerticalAlignment="Center">
                            <TextBlock Text="Security Control Center" Foreground="{StaticResource Text}" FontSize="20" FontWeight="SemiBold"/>
                            <TextBlock Text="Monitor Defender state, verify safety boundaries, and recover with confidence."
                                       Foreground="{StaticResource Subtext0}" FontSize="11.5" Margin="0,3,0,0"/>
                        </StackPanel>
                        <Button x:Name="btnRecoveryHub" Grid.Column="2" Style="{StaticResource BaseButton}" Content="Recovery hub"
                                Padding="12,7" Margin="12,0,0,0" AutomationProperties.Name="Open recovery and diagnostics hub"
                                ToolTip="Inspect target-aware health, phase recovery, snapshots, and local exports"/>
                    </Grid>

                    <!-- Status tiles grid -->
                    <Grid Grid.Row="1" Margin="15,4,15,7">
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
                        <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource Tile}" AutomationProperties.Name="Antivirus status">
                            <StackPanel>
                                <Grid Margin="0,0,0,9">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="26"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE83D;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="17"/>
                                    <TextBlock Grid.Column="1" Text="Antivirus" Foreground="{StaticResource Text}" FontWeight="SemiBold" FontSize="12.5"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="10"/>
                                </Grid>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotAV" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valAV" Text="-" Margin="9,0,0,0" Foreground="{StaticResource Text}" FontSize="21" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subAV" Text="WinDefend service" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Real-time -->
                        <Border Grid.Row="0" Grid.Column="1" Style="{StaticResource Tile}" AutomationProperties.Name="Real-time protection status">
                            <StackPanel>
                                <Grid Margin="0,0,0,9">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="26"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE823;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="17"/>
                                    <TextBlock Grid.Column="1" Text="Real-time" Foreground="{StaticResource Text}" FontWeight="SemiBold" FontSize="12.5"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="10"/>
                                </Grid>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotRT" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valRT" Text="-" Margin="9,0,0,0" Foreground="{StaticResource Text}" FontSize="21" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subRT" Text="Behavior + IOAV + script scan" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Tamper Protection -->
                        <Border Grid.Row="0" Grid.Column="2" Style="{StaticResource Tile}" AutomationProperties.Name="Tamper Protection status">
                            <StackPanel>
                                <Grid Margin="0,0,0,9">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="26"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="17"/>
                                    <TextBlock Grid.Column="1" Text="Tamper Protection" Foreground="{StaticResource Text}" FontWeight="SemiBold" FontSize="12.5"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="10"/>
                                </Grid>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotTP" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valTP" Text="-" Margin="9,0,0,0" Foreground="{StaticResource Text}" FontSize="21" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subTP" Text="Must be OFF to proceed" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Firewall -->
                        <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource Tile}" AutomationProperties.Name="Firewall status">
                            <StackPanel>
                                <Grid Margin="0,0,0,9">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="26"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE83D;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="17"/>
                                    <TextBlock Grid.Column="1" Text="Firewall" Foreground="{StaticResource Text}" FontWeight="SemiBold" FontSize="12.5"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="10"/>
                                </Grid>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotFW" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valFW" Text="-" Margin="9,0,0,0" Foreground="{StaticResource Text}" FontSize="21" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subFW" Text="mpssvc + BFE preserved" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Services -->
                        <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource Tile}" AutomationProperties.Name="Defender services status">
                            <StackPanel>
                                <Grid Margin="0,0,0,9">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="26"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE713;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="17"/>
                                    <TextBlock Grid.Column="1" Text="Defender Services" Foreground="{StaticResource Text}" FontWeight="SemiBold" FontSize="12.5"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="10"/>
                                </Grid>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotSvc" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valSvc" Text="-" Margin="9,0,0,0" Foreground="{StaticResource Text}" FontSize="21" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subSvc" Text="Disabled / Total" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                        </Border>

                        <!-- Tile: Passive Mode -->
                        <Border Grid.Row="1" Grid.Column="2" Style="{StaticResource Tile}" AutomationProperties.Name="MAPS telemetry status">
                            <StackPanel>
                                <Grid Margin="0,0,0,9">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="26"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#xE8F1;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Lavender}" FontSize="17"/>
                                    <TextBlock Grid.Column="1" Text="MAPS" Foreground="{StaticResource Text}" FontWeight="SemiBold" FontSize="12.5"/>
                                    <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="10"/>
                                </Grid>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="dotMAPS" Width="10" Height="10" Fill="{StaticResource Overlay0}" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="valMAPS" Text="-" Margin="9,0,0,0" Foreground="{StaticResource Text}" FontSize="21" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock x:Name="subMAPS" Text="Cloud-based protection" Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <!-- Component dashboard -->
                    <Grid Grid.Row="2" Margin="20,4,20,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="3*"/>
                            <ColumnDefinition Width="10"/>
                            <ColumnDefinition Width="2*"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface0}" BorderThickness="1"
                                CornerRadius="8" Padding="13" AutomationProperties.Name="Component health">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                </Grid.RowDefinitions>
                                <StackPanel Grid.Row="0" Margin="0,0,0,10">
                                    <TextBlock Text="Component health" Foreground="{StaticResource Text}" FontSize="12.5" FontWeight="SemiBold"/>
                                    <TextBlock x:Name="componentSubtitle" Text="Service, driver, and protection posture" Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,2,0,0"/>
                                </StackPanel>
                                <ScrollViewer Grid.Row="1" MaxHeight="172" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                    <WrapPanel x:Name="componentTilePanel"/>
                                </ScrollViewer>
                            </Grid>
                        </Border>
                        <Border Grid.Column="2" Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface0}" BorderThickness="1"
                                CornerRadius="8" Padding="13" AutomationProperties.Name="Policy changes">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                </Grid.RowDefinitions>
                                <StackPanel Grid.Row="0" Margin="0,0,0,10">
                                    <TextBlock Text="Policy changes" Foreground="{StaticResource Text}" FontSize="12.5" FontWeight="SemiBold"/>
                                    <TextBlock Text="Latest privileged configuration events" Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,2,0,0"/>
                                </StackPanel>
                                <ScrollViewer Grid.Row="1" MaxHeight="172" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                    <StackPanel x:Name="policyStreamPanel">
                                        <StackPanel x:Name="policyEmptyState" Margin="4,20,4,16" HorizontalAlignment="Center">
                                            <TextBlock Text="&#xE823;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Overlay0}" FontSize="22"
                                                       HorizontalAlignment="Center"/>
                                            <TextBlock Text="No policy changes in this session" Foreground="{StaticResource Subtext1}" FontSize="11.5"
                                                       FontWeight="SemiBold" Margin="0,8,0,0" HorizontalAlignment="Center"/>
                                            <TextBlock Text="Verified changes will appear here as they occur." Foreground="{StaticResource Subtext0}" FontSize="10.5"
                                                       Margin="0,3,0,0" HorizontalAlignment="Center"/>
                                        </StackPanel>
                                    </StackPanel>
                                </ScrollViewer>
                            </Grid>
                        </Border>
                    </Grid>

                    <!-- Log panel -->
                    <Border Grid.Row="3" Margin="20,0,20,10" CornerRadius="8" Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface0}"
                            BorderThickness="1" AutomationProperties.Name="Live activity">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Grid Grid.Row="0" Margin="14,10,12,9">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="Live activity" Foreground="{StaticResource Text}" FontSize="12.5" FontWeight="SemiBold"/>
                                    <TextBlock Text="Structured local operation output" Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,2,0,0"/>
                                </StackPanel>
                                <StackPanel Grid.Column="1" Orientation="Horizontal">
                                    <Button x:Name="btnCopyLog" Style="{StaticResource BaseButton}" Content="Copy" Padding="10,5" FontSize="11" Margin="0,0,6,0"
                                            AutomationProperties.Name="Copy live activity"/>
                                    <Button x:Name="btnExportLog" Style="{StaticResource BaseButton}" Content="Export" Padding="10,5" FontSize="11" Margin="0,0,6,0"
                                            AutomationProperties.Name="Export live activity"/>
                                    <Button x:Name="btnClearLog" Style="{StaticResource BaseButton}" Content="Clear" Padding="10,5" FontSize="11"
                                            AutomationProperties.Name="Clear live activity"/>
                                </StackPanel>
                            </Grid>
                            <RichTextBox x:Name="logBox" Grid.Row="1" Margin="14,0,14,14" VerticalScrollBarVisibility="Auto"
                                         HorizontalScrollBarVisibility="Disabled" AutomationProperties.Name="Live activity log">
                                <FlowDocument>
                                    <Paragraph x:Name="logPara" Margin="0"/>
                                </FlowDocument>
                            </RichTextBox>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>

            <!-- ============ STATUS BAR ============ -->
            <Border Grid.Row="4" Background="#0C1524" BorderBrush="{StaticResource Surface0}" BorderThickness="0,1,0,0">
                <Grid Margin="18,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="170"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <ProgressBar Grid.Column="0" x:Name="progressBar" IsIndeterminate="False" VerticalAlignment="Center" Width="154"
                                 AutomationProperties.Name="Operation progress"/>
                    <TextBlock Grid.Column="1" x:Name="statusText" Text="Idle" Foreground="{StaticResource Subtext0}" FontSize="11.5"
                               VerticalAlignment="Center" Margin="12,0,0,0" AutomationProperties.LiveSetting="Polite"/>
                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <Button x:Name="btnCancelOperation" Style="{StaticResource BaseButton}" Content="Cancel operation"
                                Padding="10,5" Margin="0,0,12,0" Visibility="Collapsed"
                                AutomationProperties.Name="Cancel current operation"/>
                        <TextBlock x:Name="footerText" Text="LOCAL ONLY  &#x2022;  FIREWALL BOUNDARY ENFORCED"
                                   Foreground="{StaticResource Subtext0}" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- ============ TOAST OVERLAY ============ -->
            <Border x:Name="toast" Grid.Row="3" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,24,24"
                    Background="{StaticResource Mantle}" BorderBrush="{StaticResource Mauve}" BorderThickness="1" CornerRadius="8"
                    Padding="16,12" MaxWidth="390" Visibility="Collapsed" AutomationProperties.LiveSetting="Polite">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="toastDot" Width="8" Height="8" Fill="{StaticResource Mauve}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="toastText" Text="" Foreground="{StaticResource Text}" FontSize="13" Margin="12,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <!-- ============ RECOVERY AND DIAGNOSTICS HUB ============ -->
            <Grid x:Name="recoveryOverlay" Grid.Row="0" Grid.RowSpan="5" Background="#E0070D17" Visibility="Collapsed"
                  KeyboardNavigation.TabNavigation="Cycle">
                <Border Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface1}" BorderThickness="1" CornerRadius="10"
                        Padding="24" MaxWidth="1120" MaxHeight="690" HorizontalAlignment="Center" VerticalAlignment="Center"
                        AutomationProperties.Name="Recovery and diagnostics hub">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0">
                                <TextBlock Text="RECOVERY &amp; DIAGNOSTICS" Foreground="{StaticResource Blue}" FontSize="10.5" FontWeight="SemiBold"/>
                                <TextBlock x:Name="recoveryTitleText" Text="Verify the selected target before resuming, rolling back, or exporting evidence."
                                           Foreground="{StaticResource Text}" FontSize="18" FontWeight="SemiBold" Margin="0,5,0,0"/>
                                <TextBlock x:Name="recoverySubtitleText" Text="All queries and exports stay local. A cancellation request stops at a safe query boundary."
                                           Foreground="{StaticResource Subtext0}" FontSize="11" Margin="0,3,0,0"/>
                            </StackPanel>
                            <Button x:Name="btnRecoveryClose" Grid.Column="1" Style="{StaticResource ChromeButton}" Content="&#xE8BB;"
                                    FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Subtext1}" ToolTip="Close recovery hub"
                                    AutomationProperties.Name="Close recovery and diagnostics hub"/>
                        </Grid>

                        <Grid Grid.Row="1" Margin="0,18,0,14">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="150"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock x:Name="recoveryTargetLabel" Grid.Column="0" Text="Health target" Foreground="{StaticResource Subtext0}" FontSize="11.5"
                                       VerticalAlignment="Center" Margin="0,0,10,0"/>
                            <ComboBox x:Name="cmbRecoveryTarget" Grid.Column="1" SelectedValuePath="Tag" SelectedValue="Disable"
                                      AutomationProperties.Name="Recovery health target" ToolTip="Compare live state against this target">
                                <ComboBoxItem Tag="Disable" Content="Disable"/>
                                <ComboBoxItem Tag="Remove" Content="Remove"/>
                                <ComboBoxItem Tag="Restore" Content="Restore"/>
                            </ComboBox>
                            <Button x:Name="btnRecoveryRefresh" Grid.Column="2" Style="{StaticResource BaseButton}" Content="Refresh evidence"
                                    Padding="12,6" Margin="10,0,6,0" AutomationProperties.Name="Refresh recovery evidence"/>
                            <Button x:Name="btnRecoveryCancel" Grid.Column="3" Style="{StaticResource BaseButton}" Content="Cancel query"
                                    Padding="12,6" IsEnabled="False" AutomationProperties.Name="Cancel recovery query"/>
                            <TextBlock x:Name="recoveryStatusText" Grid.Column="4" Text="Ready" Foreground="{StaticResource Subtext0}"
                                       FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"
                                       AutomationProperties.LiveSetting="Polite"/>
                        </Grid>

                        <Grid Grid.Row="2">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="3*"/>
                                <ColumnDefinition Width="12"/>
                                <ColumnDefinition Width="2*"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0">
                                <Border Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}" BorderThickness="1"
                                        CornerRadius="8" Padding="14" AutomationProperties.Name="Live recovery evidence">
                                    <StackPanel>
                                        <TextBlock x:Name="recoveryLiveHeading" Text="LIVE TARGET EVIDENCE" Foreground="{StaticResource Text}" FontSize="12.5" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="recoveryTargetText" Text="Target: Disable" Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,3,0,0"/>
                                        <TextBlock x:Name="recoveryHealthText" Text="Health evidence has not been queried." Foreground="{StaticResource Yellow}" FontSize="14" FontWeight="SemiBold" Margin="0,12,0,0" TextWrapping="Wrap"/>
                                        <TextBlock x:Name="recoveryDriftLabel" Text="Exact drift (first 12)" Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,12,0,4"/>
                                        <ScrollViewer MaxHeight="174" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                            <TextBlock x:Name="recoveryDriftText" Text="Refresh evidence to inspect expected versus actual values."
                                                       Foreground="{StaticResource Text}" FontSize="10.5" FontFamily="Consolas" TextWrapping="Wrap"/>
                                        </ScrollViewer>
                                        <TextBlock x:Name="recoveryLastResultText" Text="Last verified result: none in this session."
                                                   Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,12,0,0" TextWrapping="Wrap"/>
                                    </StackPanel>
                                </Border>
                                <Border Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}" BorderThickness="1"
                                        CornerRadius="8" Padding="14" Margin="0,12,0,0" AutomationProperties.Name="Phase recovery state">
                                    <StackPanel>
                                        <TextBlock x:Name="recoveryPhaseHeading" Text="PHASE RECOVERY" Foreground="{StaticResource Text}" FontSize="12.5" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="recoveryPhaseText" Text="No persisted phase state found." Foreground="{StaticResource Subtext1}" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap"/>
                                        <TextBlock x:Name="recoverySafeModeText" Text="Safe Mode transaction: not queried." Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,7,0,0" TextWrapping="Wrap"/>
                                        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                            <Button x:Name="btnRecoveryResume" Style="{StaticResource BaseButton}" Content="Resume phase"
                                                    Padding="12,6" Margin="0,0,7,0" IsEnabled="False" AutomationProperties.Name="Resume interrupted phase"/>
                                            <Button x:Name="btnRecoveryRollback" Style="{StaticResource DangerAction}" Content="Rollback with Restore"
                                                    Padding="12,6" IsEnabled="False" AutomationProperties.Name="Rollback interrupted phase with Restore"/>
                                        </StackPanel>
                                    </StackPanel>
                                </Border>
                            </StackPanel>

                            <StackPanel Grid.Column="2">
                                <Border Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}" BorderThickness="1"
                                        CornerRadius="8" Padding="14" AutomationProperties.Name="Recovery snapshots and diff">
                                    <StackPanel>
                                        <TextBlock x:Name="recoverySnapshotsHeading" Text="SNAPSHOTS &amp; DIFF" Foreground="{StaticResource Text}" FontSize="12.5" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="recoverySnapshotsDescription" Text="Choose a baseline, save a target-aware snapshot, or compare against live state."
                                                   Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,3,0,9" TextWrapping="Wrap"/>
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBox x:Name="txtRecoveryBaselinePath" Grid.Column="0" Height="27" VerticalContentAlignment="Center"
                                                     ToolTip="Path to a DefenderSnapshot JSON baseline" AutomationProperties.Name="Snapshot baseline path"/>
                                            <Button x:Name="btnRecoveryChooseBaseline" Grid.Column="1" Style="{StaticResource BaseButton}" Content="Browse"
                                                    Padding="10,5" Margin="7,0,0,0" AutomationProperties.Name="Browse for snapshot baseline"/>
                                        </Grid>
                                        <StackPanel Orientation="Horizontal" Margin="0,9,0,0">
                                            <Button x:Name="btnRecoverySnapshot" Style="{StaticResource BaseButton}" Content="Save snapshot"
                                                    Padding="10,5" Margin="0,0,7,0" AutomationProperties.Name="Save target-aware Defender snapshot"/>
                                            <Button x:Name="btnRecoveryCompare" Style="{StaticResource BaseButton}" Content="Compare to live"
                                                    Padding="10,5" AutomationProperties.Name="Compare snapshot to live Defender state"/>
                                        </StackPanel>
                                        <TextBlock x:Name="recoverySnapshotText" Text="No snapshot saved in this session." Foreground="{StaticResource Subtext0}"
                                                   FontSize="10" Margin="0,9,0,0" TextWrapping="Wrap"/>
                                        <TextBlock x:Name="recoveryDiffSummaryText" Text="No comparison has been run." Foreground="{StaticResource Text}"
                                                   FontSize="10.5" FontWeight="SemiBold" Margin="0,10,0,4" TextWrapping="Wrap"/>
                                        <ScrollViewer MaxHeight="125" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                            <TextBlock x:Name="recoveryDiffText" Text="Choose a baseline and compare to inspect changes."
                                                       Foreground="{StaticResource Subtext1}" FontSize="10" FontFamily="Consolas" TextWrapping="Wrap"/>
                                        </ScrollViewer>
                                    </StackPanel>
                                </Border>
                                <Border Background="{StaticResource Base}" BorderBrush="{StaticResource Surface0}" BorderThickness="1"
                                        CornerRadius="8" Padding="14" Margin="0,12,0,0" AutomationProperties.Name="Local recovery exports">
                                    <StackPanel>
                                        <TextBlock x:Name="recoveryExportsHeading" Text="LOCAL EXPORTS" Foreground="{StaticResource Text}" FontSize="12.5" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="recoveryExportsDescription" Text="Exports use the selected target and never upload data."
                                                   Foreground="{StaticResource Subtext0}" FontSize="10.5" Margin="0,3,0,9"/>
                                        <StackPanel Orientation="Horizontal">
                                            <Button x:Name="btnRecoveryExportReport" Style="{StaticResource BaseButton}" Content="HTML report"
                                                    Padding="10,5" Margin="0,0,7,0" AutomationProperties.Name="Export local HTML recovery report"/>
                                            <Button x:Name="btnRecoveryExportSupport" Style="{StaticResource BaseButton}" Content="Support bundle"
                                                    Padding="10,5" AutomationProperties.Name="Export local redacted support bundle"/>
                                        </StackPanel>
                                    </StackPanel>
                                </Border>
                            </StackPanel>
                        </Grid>

                        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                            <TextBlock x:Name="recoverySenseNote" Text="Sense is not included unless the selected command explicitly opts in."
                                       Foreground="{StaticResource Subtext0}" FontSize="10.5" VerticalAlignment="Center" Margin="0,0,18,0"/>
                            <Button x:Name="btnRecoveryDone" Style="{StaticResource BaseButton}" Content="Done" Padding="18,8"
                                    AutomationProperties.Name="Close recovery hub"/>
                        </StackPanel>
                    </Grid>
                </Border>
            </Grid>

            <!-- ============ CONFIRMATION OVERLAY ============ -->
            <Grid x:Name="confirmOverlay" Grid.Row="0" Grid.RowSpan="5" Background="#E0070D17" Visibility="Collapsed"
                  KeyboardNavigation.TabNavigation="Cycle">
                <Border Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface1}" BorderThickness="1" CornerRadius="10"
                        Padding="30" MaxWidth="700" HorizontalAlignment="Center" VerticalAlignment="Center"
                        AutomationProperties.Name="Action confirmation">
                    <StackPanel>
                        <TextBlock Text="REVIEW OPERATION" Foreground="{StaticResource Yellow}" FontSize="10.5" FontWeight="SemiBold"/>
                        <TextBlock x:Name="confirmTitle" Text="Confirm action" Foreground="{StaticResource Text}" FontSize="20" FontWeight="SemiBold" Margin="0,6,0,0"/>
                        <TextBlock x:Name="confirmBody" Text="" Foreground="{StaticResource Subtext1}" FontSize="13" LineHeight="19"
                                   Margin="0,10,0,0" TextWrapping="Wrap"/>
                        <Border x:Name="confirmDiffPanel" Visibility="Collapsed" Margin="0,14,0,0" Padding="12"
                                Background="{StaticResource Mantle}" BorderBrush="{StaticResource Surface1}" BorderThickness="1" CornerRadius="8">
                            <StackPanel>
                                <TextBlock Text="CURRENT &#x2192; TARGET" Foreground="{StaticResource Subtext1}" FontSize="10.5" FontWeight="SemiBold" Margin="0,0,0,8"/>
                                <ScrollViewer MaxHeight="220" VerticalScrollBarVisibility="Auto">
                                    <TextBlock x:Name="confirmDiffText" Text="" Foreground="{StaticResource Text}" FontSize="11" FontFamily="Consolas" TextWrapping="NoWrap"/>
                                </ScrollViewer>
                            </StackPanel>
                        </Border>
                        <Border x:Name="confirmForcePanel" Visibility="Collapsed" Margin="0,14,0,0" Padding="12"
                                Background="{StaticResource Mantle}" BorderBrush="{StaticResource Red}" BorderThickness="1" CornerRadius="8">
                            <CheckBox x:Name="confirmForceOverride"
                                      Content="Override safety gates (-Force)"
                                      Foreground="{StaticResource Red}"
                                      FontSize="12"
                                      AutomationProperties.Name="Override safety gates for this run"
                                      ToolTip="Bypasses Tamper Protection, managed-device, and Safe Mode refusal gates for this run only."/>
                        </Border>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
                            <Button x:Name="btnConfirmCancel" Style="{StaticResource BaseButton}" Content="Cancel" Padding="18,9"
                                    Margin="0,0,10,0" IsCancel="True" AutomationProperties.Name="Cancel operation"/>
                            <Button x:Name="btnConfirmOk" Style="{StaticResource DangerAction}" Content="Proceed" Padding="18,9"
                                    Margin="0" IsDefault="True" AutomationProperties.Name="Proceed with operation"/>
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

function Get-GuiText {
    param(
        [Parameter(Mandatory)][string]$Id,
        [object[]]$ArgumentList
    )
    if ($null -eq $ArgumentList -or $ArgumentList.Count -eq 0) {
        return Get-DefenderPresentationString -Id $Id
    }
    return Get-DefenderPresentationString -Id $Id -ArgumentList $ArgumentList
}

function Set-GuiPresentationResources {
    $window.Title = Get-GuiText -Id 'app.name'
    $window.FlowDirection = if ((Get-DefenderPresentationDirection) -eq 'RightToLeft') {
        [System.Windows.FlowDirection]::RightToLeft
    } else {
        [System.Windows.FlowDirection]::LeftToRight
    }
    try {
        $window.Language = [System.Windows.Markup.XmlLanguage]::GetLanguage(
            ([string]$script:Presentation.Culture))
    } catch {}

    $ui.labelDisable.Text = Get-GuiText -Id 'gui.action.disable'
    $ui.labelRemove.Text = Get-GuiText -Id 'gui.action.remove'
    $ui.labelRestore.Text = Get-GuiText -Id 'gui.action.restore'
    $ui.labelRepair.Text = Get-GuiText -Id 'gui.action.repair'
    $ui.labelRefresh.Text = Get-GuiText -Id 'gui.action.refresh'
    $ui.btnOpenSecurity.Content = Get-GuiText -Id 'gui.security.open'
    $ui.btnRecoveryHub.Content = Get-GuiText -Id 'gui.recovery.hub'
    $ui.btnRecoveryClose.ToolTip = Get-GuiText -Id 'gui.recovery.close'
    $ui.btnRecoveryRefresh.Content = Get-GuiText -Id 'gui.recovery.refresh'
    $ui.btnRecoveryCancel.Content = Get-GuiText -Id 'gui.recovery.cancel'
    $ui.btnRecoveryDone.Content = Get-GuiText -Id 'gui.recovery.done'
    $ui.btnRecoverySnapshot.Content = Get-GuiText -Id 'gui.recovery.snapshot'
    $ui.btnRecoveryCompare.Content = Get-GuiText -Id 'gui.recovery.compare'
    $ui.btnRecoveryExportReport.Content = Get-GuiText -Id 'gui.recovery.report'
    $ui.btnRecoveryExportSupport.Content = Get-GuiText -Id 'gui.recovery.support'
    $ui.btnCopyLog.Content = Get-GuiText -Id 'gui.log.copy'
    $ui.btnExportLog.Content = Get-GuiText -Id 'gui.log.export'
    $ui.btnClearLog.Content = Get-GuiText -Id 'gui.log.clear'
    $ui.btnCancelOperation.Content = Get-GuiText -Id 'gui.operation.cancel'
    $ui.recoveryTitleText.Text = Get-GuiText -Id 'gui.recovery.title'
    $ui.recoverySubtitleText.Text = Get-GuiText -Id 'gui.recovery.subtitle'
    $ui.recoveryTargetLabel.Text = Get-GuiText -Id 'gui.recovery.target'
    $ui.recoveryLiveHeading.Text = Get-GuiText -Id 'gui.recovery.live'
    $ui.recoveryDriftLabel.Text = Get-GuiText -Id 'gui.recovery.drift'
    $ui.recoveryPhaseHeading.Text = Get-GuiText -Id 'gui.recovery.phase'
    $ui.recoverySnapshotsHeading.Text = Get-GuiText -Id 'gui.recovery.snapshots'
    $ui.recoverySnapshotsDescription.Text = Get-GuiText -Id 'gui.recovery.snapshots.description'
    $ui.recoveryExportsHeading.Text = Get-GuiText -Id 'gui.recovery.exports'
    $ui.recoveryExportsDescription.Text = Get-GuiText -Id 'gui.recovery.exports.description'
    $ui.recoverySenseNote.Text = Get-GuiText -Id 'gui.recovery.sense'
    $ui.recoveryStatusText.Text = Get-GuiText -Id 'gui.recovery.ready'
}

function New-GuiTrayStatusIcon {
    param(
        [ValidateSet('Info','Success','Cancelled','Failed')][string]$Status = 'Info'
    )

    $color = switch ($Status) {
        'Success'   { [System.Drawing.Color]::FromArgb(255, 86, 217, 123) }
        'Cancelled' { [System.Drawing.Color]::FromArgb(255, 255, 200, 87) }
        'Failed'    { [System.Drawing.Color]::FromArgb(255, 255, 112, 136) }
        default     { [System.Drawing.Color]::FromArgb(255, 110, 168, 254) }
    }
    $bitmap = New-Object System.Drawing.Bitmap 16, 16
    $graphics = $null
    $brush = $null
    $pen = $null
    $nativeIcon = $null
    $hIcon = [IntPtr]::Zero
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $brush = [System.Drawing.SolidBrush]::new($color)
        $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 1)
        $graphics.FillEllipse($brush, 1, 1, 14, 14)
        $graphics.DrawEllipse($pen, 1, 1, 14, 14)
        $hIcon = $bitmap.GetHicon()
        $nativeIcon = [System.Drawing.Icon]::FromHandle($hIcon)
        return [System.Drawing.Icon]$nativeIcon.Clone()
    } catch {
        return $null
    } finally {
        if ($nativeIcon) { $nativeIcon.Dispose() }
        if ($hIcon -ne [IntPtr]::Zero) {
            try { [DisableDefenderGui.IconCtl]::DestroyIcon($hIcon) | Out-Null } catch {}
        }
        if ($pen) { $pen.Dispose() }
        if ($brush) { $brush.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        $bitmap.Dispose()
    }
}

function Set-GuiTrayStatus {
    param(
        [ValidateSet('Info','Success','Cancelled','Failed')][string]$Status = 'Info'
    )
    if ($null -eq $script:TrayIcon) { return }
    $icon = New-GuiTrayStatusIcon -Status $Status
    if ($icon) {
        [void]$script:TrayStatusIcons.Add($icon)
        $script:TrayIcon.Icon = $icon
    }
    $script:TrayIcon.BalloonTipIcon = switch ($Status) {
        'Success'   { [System.Windows.Forms.ToolTipIcon]::Info }
        'Cancelled' { [System.Windows.Forms.ToolTipIcon]::Warning }
        'Failed'    { [System.Windows.Forms.ToolTipIcon]::Error }
        default     { [System.Windows.Forms.ToolTipIcon]::Info }
    }
}

function Show-GuiCompletionNotification {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Success','Cancelled','Failed')][string]$Status
    )
    if ($null -eq $script:TrayIcon) { return }
    Set-GuiTrayStatus -Status $Status
    $script:TrayIcon.BalloonTipTitle = Get-GuiText -Id 'app.name'
    $script:TrayIcon.BalloonTipText = $Message
    try { $script:TrayIcon.ShowBalloonTip(5000) } catch {}
}

function Initialize-GuiTrayIcon {
    try {
        $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:TrayIcon.Text = 'DisableDefender'
        $script:TrayIcon.Visible = $true

        $script:TrayContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $openItem = $script:TrayContextMenu.Items.Add((Get-GuiText -Id 'gui.tray.open'))
        $exitItem = $script:TrayContextMenu.Items.Add((Get-GuiText -Id 'gui.tray.exit'))
        $openAction = {
            if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
            $window.Activate() | Out-Null
        }.GetNewClosure()
        $openItem.Add_Click($openAction)
        $script:TrayIcon.Add_DoubleClick($openAction)
        $exitItem.Add_Click({ $window.Close() }.GetNewClosure())
        $script:TrayIcon.ContextMenuStrip = $script:TrayContextMenu
        Set-GuiTrayStatus -Status Info
    } catch {
        $script:TrayIcon = $null
        $script:TrayContextMenu = $null
    }
}

function Set-GuiHighContrastTheme {
    if (-not [System.Windows.SystemParameters]::HighContrast) { return $false }

    $windowBrush = [System.Windows.SystemColors]::WindowBrush
    $windowTextBrush = [System.Windows.SystemColors]::WindowTextBrush
    $controlBrush = [System.Windows.SystemColors]::ControlBrush
    $controlTextBrush = [System.Windows.SystemColors]::ControlTextBrush
    $resourceRoles = @{
        Base          = $windowBrush
        Mantle        = $windowBrush
        Crust         = $windowBrush
        Surface0      = $windowTextBrush
        Surface1      = $windowTextBrush
        Surface2      = $windowTextBrush
        Overlay0      = $windowTextBrush
        Text          = $windowTextBrush
        Subtext0      = $windowTextBrush
        Subtext1      = $windowTextBrush
        FirewallOkBg  = $windowBrush
        FirewallBadBg = $windowBrush
        Red           = $windowTextBrush
        Maroon        = $windowTextBrush
        Peach         = $windowTextBrush
        Yellow        = $windowTextBrush
        Green         = $windowTextBrush
        Teal          = $windowTextBrush
        Sky           = $windowTextBrush
        Blue          = $windowTextBrush
        Lavender      = $windowTextBrush
        Mauve         = $windowTextBrush
        Pink          = $windowTextBrush
    }
    foreach ($key in $resourceRoles.Keys) {
        $source = $resourceRoles[$key]
        $brush = $window.Resources[$key]
        if ($brush -is [System.Windows.Media.SolidColorBrush]) {
            try {
                if (-not $brush.IsFrozen) {
                    $brush.Color = $source.Color
                } else {
                    $window.Resources[$key] = [System.Windows.Media.SolidColorBrush]::new($source.Color)
                }
            } catch {
                $window.Resources[$key] = [System.Windows.Media.SolidColorBrush]::new($source.Color)
            }
        }
    }

    $window.Background = $windowBrush
    foreach ($element in @($ui.Values | Where-Object { $null -ne $_ })) {
        if ($element -is [System.Windows.Controls.TextBlock]) {
            $element.Foreground = $windowTextBrush
        } elseif ($element -is [System.Windows.Controls.Primitives.ButtonBase]) {
            $element.Background = $controlBrush
            $element.Foreground = $controlTextBrush
            $element.BorderBrush = $windowTextBrush
        } elseif ($element -is [System.Windows.Controls.TextBox] -or
            $element -is [System.Windows.Controls.ComboBox] -or
            $element -is [System.Windows.Controls.RichTextBox]) {
            $element.Background = $windowBrush
            $element.Foreground = $windowTextBrush
            $element.BorderBrush = $windowTextBrush
        } elseif ($element -is [System.Windows.Controls.Border]) {
            $element.Background = $windowBrush
            $element.BorderBrush = $windowTextBrush
        } elseif ($element -is [System.Windows.Shapes.Shape]) {
            $element.Fill = $windowTextBrush
        } elseif ($element -is [System.Windows.Controls.ProgressBar]) {
            $element.Background = $controlBrush
            $element.Foreground = $windowTextBrush
        }
    }
    $ui.footerText.Text = 'HIGH CONTRAST  |  LOCAL ONLY  |  FIREWALL BOUNDARY ENFORCED'
    return $true
}

function Test-GuiAccessibilityContract {
    $interactive = @($xaml.SelectNodes('//*[local-name()="Button" or local-name()="ComboBox" or local-name()="CheckBox" or local-name()="TextBox"]'))
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($node in $interactive) {
        $nameAttribute = $node.Attributes['x:Name']
        if ($null -eq $nameAttribute) { continue }
        $automationAttribute = $node.Attributes['AutomationProperties.Name']
        if ($null -eq $automationAttribute -or [string]::IsNullOrWhiteSpace($automationAttribute.Value)) {
            [void]$missing.Add($nameAttribute.Value)
        }
    }
    if ($missing.Count -gt 0) {
        throw "GUI accessibility contract missing AutomationProperties.Name: $($missing -join ', ')"
    }
    if ($window.MinWidth -lt 1100 -or $window.MinHeight -lt 700) {
        throw "GUI minimum layout is below the supported 1100x700 contract."
    }
    if ($null -eq $xaml.Window.Attributes['KeyboardNavigation.TabNavigation']) {
        throw 'GUI accessibility contract is missing a keyboard focus traversal policy.'
    }
    return [PSCustomObject]@{
        NamedInteractiveControls = $interactive.Count
        MinimumWidth = $window.MinWidth
        MinimumHeight = $window.MinHeight
        HighContrast = [bool][System.Windows.SystemParameters]::HighContrast
    }
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
        $val.Foreground = $window.Resources['Yellow']
        $dot.Fill = $window.Resources['Yellow']
        if ($SubText) { $sub.Text = $SubText }
        return
    }
    $val.Foreground = $window.Resources['Text']
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

function New-ComponentText {
    param(
        [string]$Text,
        [int]$FontSize = 11,
        [string]$Resource = 'Text',
        [switch]$Bold
    )

    $block = [System.Windows.Controls.TextBlock]::new()
    $block.Text = $Text
    $block.FontSize = $FontSize
    $block.Foreground = $window.Resources[$Resource]
    $block.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    if ($Bold) { $block.FontWeight = 'SemiBold' }
    return $block
}

function Add-ComponentTile {
    param([Parameter(Mandatory)]$Component)

    $border = [System.Windows.Controls.Border]::new()
    $border.Width = 168
    $border.Height = 82
    $border.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
    $border.Padding = [System.Windows.Thickness]::new(10)
    $border.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $border.Background = $window.Resources['Crust']
    $border.BorderThickness = [System.Windows.Thickness]::new(1)

    switch ($Component.DisableTargetDrift) {
        'OK' {
            $dotBrush = $window.Resources['Green']
            $border.BorderBrush = $window.Resources['Surface1']
            $stateText = 'LOCKED'
        }
        'Drift' {
            $dotBrush = $window.Resources['Yellow']
            $border.BorderBrush = $window.Resources['Surface1']
            $stateText = $Component.CurrentStart
        }
        default {
            $dotBrush = $window.Resources['Overlay0']
            $border.BorderBrush = $window.Resources['Surface0']
            $stateText = 'UNKNOWN'
        }
    }

    $panel = [System.Windows.Controls.StackPanel]::new()

    $header = [System.Windows.Controls.DockPanel]::new()
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8
    $dot.Height = 8
    $dot.Fill = $dotBrush
    $dot.Margin = [System.Windows.Thickness]::new(0, 3, 7, 0)
    [System.Windows.Controls.DockPanel]::SetDock($dot, [System.Windows.Controls.Dock]::Left)
    $header.Children.Add($dot) | Out-Null
    $header.Children.Add((New-ComponentText -Text $Component.Name -FontSize 12 -Bold)) | Out-Null

    $runtime = $Component.RuntimeStatus
    if ($Component.DriverRuntime) { $runtime = $Component.DriverRuntime }
    $protection = if ($Component.PPLStatus -and $Component.PPLStatus -ne 'N/A') { "PPL $($Component.PPLStatus)" } else { $Component.Kind }

    $panel.Children.Add($header) | Out-Null
    $panel.Children.Add((New-ComponentText -Text $stateText -FontSize 11 -Resource 'Subtext1')) | Out-Null
    $panel.Children.Add((New-ComponentText -Text $protection -FontSize 10 -Resource 'Subtext0')) | Out-Null
    $panel.Children.Add((New-ComponentText -Text $runtime -FontSize 10 -Resource 'Overlay0')) | Out-Null

    $border.ToolTip = ("{0}`nService: {1}`nExpected Disable start: {2}`nCurrent start: {3}`nRuntime: {4}`nProtection: {5}`n{6}" -f $Component.Name, $Component.Service, $Component.ExpectedStart, $Component.CurrentStart, $runtime, $Component.PPLStatus, $Component.Detail)
    [System.Windows.Automation.AutomationProperties]::SetName(
        $border,
        ("{0}: {1}; {2}; {3}" -f $Component.Name, $stateText, $protection, $runtime)
    )
    $border.Child = $panel
    $ui.componentTilePanel.Children.Add($border) | Out-Null
}

function Update-ComponentTiles {
    if (-not $ui.componentTilePanel) { return }
    $ui.componentTilePanel.Children.Clear()
    if ($ui.componentSubtitle) {
        try {
            $safeModeStatus = Get-DefenderSafeModeStatus
            switch ($safeModeStatus.Stage) {
                'Idle' {
                    $ui.componentSubtitle.Text = 'Service, driver, and protection posture'
                    $ui.componentSubtitle.Foreground = $window.Resources['Subtext0']
                }
                'Completed' {
                    $ui.componentSubtitle.Text = (
                        "Safe Mode transaction completed - {0}/{1} required effects verified" -f
                        $safeModeStatus.VerifiedEffects, $safeModeStatus.RequiredEffects)
                    $ui.componentSubtitle.Foreground = $window.Resources['Green']
                }
                'RolledBack' {
                    $ui.componentSubtitle.Text = 'Safe Mode transaction rolled back - no boot override remains'
                    $ui.componentSubtitle.Foreground = $window.Resources['Yellow']
                }
                default {
                    $ui.componentSubtitle.Text = (
                        "Safe Mode transaction: {0} - recovery: {1}" -f
                        $safeModeStatus.Stage, $safeModeStatus.RecoveryRecommendation)
                    $ui.componentSubtitle.Foreground = if ($safeModeStatus.LastError) {
                        $window.Resources['Red']
                    } else {
                        $window.Resources['Yellow']
                    }
                }
            }
            $ui.componentSubtitle.ToolTip = (
                "Transaction: {0}`nStage: {1}`nChild exit: {2}`nTask result: {3}`nLast error: {4}" -f
                $safeModeStatus.TransactionId,
                $safeModeStatus.Stage,
                $safeModeStatus.ChildExitCode,
                $safeModeStatus.SafeModeTaskResult,
                $safeModeStatus.LastError)
            [System.Windows.Automation.AutomationProperties]::SetName(
                $ui.componentSubtitle,
                $ui.componentSubtitle.Text)
        } catch {
            $ui.componentSubtitle.Text = "Safe Mode transaction status unavailable: $($_.Exception.Message)"
            $ui.componentSubtitle.Foreground = $window.Resources['Red']
        }
    }
    try {
        foreach ($component in @(Get-DefenderComponentStatus)) {
            Add-ComponentTile -Component $component
        }
    } catch {
        $block = New-ComponentText -Text "Component dashboard unavailable: $($_.Exception.Message)" -FontSize 11 -Resource 'Yellow'
        $ui.componentTilePanel.Children.Add($block) | Out-Null
    }
}

function Test-FirewallGuardTripMessage {
    param([string]$Message)
    return ($Message -match '^Firewall issues at .+ stage:' -or
            $Message -match '^Firewall integrity broken at .+ stage')
}

function Start-FirewallBannerFlash {
    if (-not $ui.firewallBanner) { return }
    $flash = New-Object System.Windows.Media.Animation.DoubleAnimation 0.35, 1, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(180))
    $flash.AutoReverse = $true
    $flash.RepeatBehavior = New-Object System.Windows.Media.Animation.RepeatBehavior 4
    $ui.firewallBanner.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $flash)
}

function Set-FirewallBannerState {
    param(
        [string[]]$Issues,
        [string]$Source = 'live poll',
        [switch]$Flash
    )

    if (-not $ui.firewallBanner) { return }
    if (@($Issues).Count -gt 0) {
        $ui.firewallBanner.Background = $window.Resources['FirewallBadBg']
        $ui.firewallBanner.BorderBrush = $window.Resources['Red']
        $ui.firewallBannerDot.Fill = $window.Resources['Red']
        $ui.firewallBannerTitle.Text = 'Firewall integrity guard tripped'
        $ui.firewallBannerTitle.Foreground = $window.Resources['Red']
        $ui.firewallBannerText.Text = "$Source - $((@($Issues) | Select-Object -First 3) -join '; ')"
        $ui.footerText.Text = 'FIREWALL ATTENTION REQUIRED'
        $ui.footerText.Foreground = $window.Resources['Red']
        if ($ui.railFirewallIcon) { $ui.railFirewallIcon.Foreground = $window.Resources['Red'] }
        if ($ui.railFirewallText) {
            $ui.railFirewallText.Text = 'Firewall attention required'
            $ui.railFirewallText.Foreground = $window.Resources['Red']
        }
        if ($Flash) { Start-FirewallBannerFlash }
    } else {
        $ui.firewallBanner.Opacity = 1
        $ui.firewallBanner.Background = $window.Resources['FirewallOkBg']
        $ui.firewallBanner.BorderBrush = $window.Resources['Green']
        $ui.firewallBannerDot.Fill = $window.Resources['Green']
        $ui.firewallBannerTitle.Text = 'Firewall integrity protected'
        $ui.firewallBannerTitle.Foreground = $window.Resources['Green']
        $ui.firewallBannerText.Text = 'mpssvc and BFE guarded; firewall profiles enabled'
        $ui.footerText.Text = 'LOCAL ONLY  |  FIREWALL BOUNDARY ENFORCED'
        $ui.footerText.Foreground = $window.Resources['Subtext0']
        if ($ui.railFirewallIcon) { $ui.railFirewallIcon.Foreground = $window.Resources['Green'] }
        if ($ui.railFirewallText) {
            $ui.railFirewallText.Text = 'Firewall boundary verified'
            $ui.railFirewallText.Foreground = $window.Resources['Subtext1']
        }
    }
}

function Get-PolicyStreamEvent {
    param([Parameter(Mandatory)]$Entry)

    $message = [string]$Entry.Message
    $streamEvent = [ordered]@{
        Method = $null
        Icon   = $null
        Title  = $null
        Detail = $message
        Color  = 'Subtext1'
    }

    if ($message -match '^Set (?<Path>HKLM:\\.+)\\(?<Name>[^\\]+) = (?<Value>.+) \((?<Type>[^)]+)\)$') {
        $streamEvent.Method = 'Direct'
        $streamEvent.Icon = [char]0xE105
        $streamEvent.Title = "$($Matches.Name) = $($Matches.Value)"
        $streamEvent.Detail = $Matches.Path
        $streamEvent.Color = 'Green'
    } elseif ($message -match '^Removed (?<Path>HKLM:\\.+?)(?: \(ACL takeover\))?$') {
        $streamEvent.Method = if ($message -like '*(ACL takeover)*') { 'ACL' } else { 'Direct' }
        $streamEvent.Icon = if ($streamEvent.Method -eq 'ACL') { [char]0xE72E } else { [char]0xE107 }
        $streamEvent.Title = 'Removed registry key'
        $streamEvent.Detail = $Matches.Path
        $streamEvent.Color = if ($streamEvent.Method -eq 'ACL') { 'Yellow' } else { 'Green' }
    } elseif ($message -match '^Service (?<Name>\S+) Start=(?<State>\S+) \((?<Method>direct|ACL takeover|SYSTEM task)\)\.$') {
        $streamEvent.Method = switch ($Matches.Method) {
            'direct' { 'Direct' }
            'ACL takeover' { 'ACL' }
            default { 'SYSTEM' }
        }
        $streamEvent.Icon = switch ($streamEvent.Method) {
            'Direct' { [char]0xE105 }
            'ACL' { [char]0xE72E }
            default { [char]0xE713 }
        }
        $streamEvent.Title = "$($Matches.Name) Start=$($Matches.State)"
        $streamEvent.Detail = "$($streamEvent.Method) registry write"
        $streamEvent.Color = switch ($streamEvent.Method) {
            'Direct' { 'Green' }
            'ACL' { 'Yellow' }
            default { 'Peach' }
        }
    } elseif ($message -match
        '^WhatIf: would (?:journal, take ownership, and grant|take ownership \+ grant) FullControl on HKLM:\\(?<Path>.+)$') {
        $streamEvent.Method = 'ACL'
        $streamEvent.Icon = [char]0xE72E
        $streamEvent.Title = 'Would grant registry ACL'
        $streamEvent.Detail = "HKLM:\$($Matches.Path)"
        $streamEvent.Color = 'Yellow'
    } elseif ($message -match '^WhatIf: would run as SYSTEM: (?<Command>.+)$' -or $message -match '^Invoke-AsSystem failed: (?<Command>.+)$') {
        $streamEvent.Method = 'SYSTEM'
        $streamEvent.Icon = [char]0xE713
        $streamEvent.Title = 'SYSTEM task method'
        $streamEvent.Detail = $Matches.Command
        $streamEvent.Color = if ($Entry.Level -eq 'ERROR') { 'Red' } else { 'Peach' }
    } elseif ($message -match
        '^ACL journal verified|^Archived verified ACL journal|^Restored ACL for |^Registry ACL restore result|^ACL backup saved|^Registry ACLs restored') {
        $streamEvent.Method = 'ACL'
        $streamEvent.Icon = [char]0xE72E
        $streamEvent.Title = 'Registry ACL state'
        $streamEvent.Color = 'Yellow'
    } else {
        return $null
    }

    return [PSCustomObject]$streamEvent
}

function Add-PolicyStreamEntry {
    param([Parameter(Mandatory)]$Entry)

    if (-not $ui.policyStreamPanel) { return }
    $streamEvent = Get-PolicyStreamEvent -Entry $Entry
    if (-not $streamEvent) { return }
    if ($ui.policyEmptyState -and $ui.policyStreamPanel.Children.Contains($ui.policyEmptyState)) {
        $ui.policyStreamPanel.Children.Remove($ui.policyEmptyState)
    }

    $row = [System.Windows.Controls.Border]::new()
    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 7)
    $row.Padding = [System.Windows.Thickness]::new(9)
    $row.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $row.Background = $window.Resources['Crust']
    $row.BorderBrush = $window.Resources['Surface0']
    $row.BorderThickness = [System.Windows.Thickness]::new(1)
    $row.ToolTip = $streamEvent.Detail
    [System.Windows.Automation.AutomationProperties]::SetName(
        $row,
        ("{0}: {1} - {2}" -f $streamEvent.Title, $streamEvent.Method, $streamEvent.Detail)
    )

    $grid = [System.Windows.Controls.Grid]::new()
    $iconColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $iconColumn.Width = [System.Windows.GridLength]::new(26)
    $textColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $textColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $grid.ColumnDefinitions.Add($iconColumn) | Out-Null
    $grid.ColumnDefinitions.Add($textColumn) | Out-Null

    $icon = [System.Windows.Controls.TextBlock]::new()
    $icon.Text = $streamEvent.Icon
    $icon.FontFamily = 'Segoe MDL2 Assets'
    $icon.FontSize = 14
    $icon.Foreground = $window.Resources[$streamEvent.Color]
    $icon.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($icon, 0)

    $textPanel = [System.Windows.Controls.StackPanel]::new()
    $title = New-ComponentText -Text $streamEvent.Title -FontSize 11 -Resource 'Text' -Bold
    $detail = New-ComponentText -Text "$($streamEvent.Method) - $($streamEvent.Detail)" -FontSize 10 -Resource 'Subtext0'
    $textPanel.Children.Add($title) | Out-Null
    $textPanel.Children.Add($detail) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($textPanel, 1)

    $grid.Children.Add($icon) | Out-Null
    $grid.Children.Add($textPanel) | Out-Null
    $row.Child = $grid

    $ui.policyStreamPanel.Children.Insert(0, $row)
    while ($ui.policyStreamPanel.Children.Count -gt 24) {
        $ui.policyStreamPanel.Children.RemoveAt($ui.policyStreamPanel.Children.Count - 1)
    }
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
        $timer = $this
        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(300))
        $fadeOut.add_Completed({ $ui.toast.Visibility = 'Collapsed' }.GetNewClosure())
        $ui.toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
        $timer.Stop()
        try { $timer.Dispose() } catch {}
        [void]$script:ToastTimers.Remove($timer)
    })
    [void]$script:ToastTimers.Add($tmr)
    $tmr.Start()
}

function Get-DisableTargetDiffText {
    try {
        $health = Get-DefenderHealth -Target Disable
        $items = @($health.Items | Where-Object { $_.Status -ne 'OK' } | Select-Object -First 18)
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.AppendLine(("Target Disable: OK={0} Drift={1} Unknown={2} Total={3}" -f $health.Summary.OK, $health.Summary.Drift, $health.Summary.Unknown, $health.Summary.Total))
        if ($items.Count -eq 0) {
            [void]$builder.AppendLine('No drift from Disable target detected.')
            return $builder.ToString().TrimEnd()
        }
        [void]$builder.AppendLine('Status   Category      Name')
        [void]$builder.AppendLine('------   --------      ----')
        foreach ($item in $items) {
            $name = [string]$item.Name
            if ($name.Length -gt 54) { $name = $name.Substring(0, 51) + '...' }
            [void]$builder.AppendLine(("{0,-8} {1,-13} {2}" -f $item.Status, $item.Category, $name))
            [void]$builder.AppendLine(("         expected: {0}" -f $item.Expected))
            [void]$builder.AppendLine(("         current : {0}" -f $item.Actual))
        }
        if (($health.Summary.Drift + $health.Summary.Unknown) -gt $items.Count) {
            [void]$builder.AppendLine(("... {0} more drift/unknown item(s)" -f (($health.Summary.Drift + $health.Summary.Unknown) - $items.Count)))
        }
        return $builder.ToString().TrimEnd()
    } catch {
        return "Unable to build Disable target diff: $($_.Exception.Message)"
    }
}

function Show-Confirm {
    param(
        [string]$Title,
        [string]$Body,
        [scriptblock]$OnProceed,
        [string]$DiffText,
        [switch]$AllowForceOverride,
        [ValidateSet('Warning', 'Danger', 'Recovery')]
        [string]$Kind = 'Warning',
        [string]$ConfirmLabel = 'Proceed'
    )
    $ui.confirmTitle.Text = $Title
    $ui.confirmBody.Text  = $Body
    $ui.btnConfirmOk.Content = $ConfirmLabel
    switch ($Kind) {
        'Danger' {
            $ui.btnConfirmOk.Background = $window.Resources['FirewallBadBg']
            $ui.btnConfirmOk.BorderBrush = $window.Resources['Red']
            $ui.btnConfirmOk.Foreground = $window.Resources['Red']
        }
        'Recovery' {
            $ui.btnConfirmOk.Background = $window.Resources['FirewallOkBg']
            $ui.btnConfirmOk.BorderBrush = $window.Resources['Green']
            $ui.btnConfirmOk.Foreground = $window.Resources['Green']
        }
        default {
            $ui.btnConfirmOk.Background = $window.Resources['Surface0']
            $ui.btnConfirmOk.BorderBrush = $window.Resources['Blue']
            $ui.btnConfirmOk.Foreground = $window.Resources['Text']
        }
    }
    if ([string]::IsNullOrWhiteSpace($DiffText)) {
        $ui.confirmDiffText.Text = ''
        $ui.confirmDiffPanel.Visibility = 'Collapsed'
    } else {
        $ui.confirmDiffText.Text = $DiffText
        $ui.confirmDiffPanel.Visibility = 'Visible'
    }
    $script:ConfirmForceOverride = $false
    if ($ui.confirmForceOverride) { $ui.confirmForceOverride.IsChecked = $false }
    if ($ui.confirmForcePanel) {
        $ui.confirmForcePanel.Visibility = if ($AllowForceOverride) { 'Visible' } else { 'Collapsed' }
    }
    $script:ConfirmAction = $OnProceed
    $ui.confirmOverlay.Visibility = 'Visible'
    $ui.btnConfirmCancel.Focus() | Out-Null
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
    Add-PolicyStreamEntry -Entry $Entry
    if (Test-FirewallGuardTripMessage -Message $Entry.Message) {
        Set-FirewallBannerState -Issues @($Entry.Message) -Source 'operation guard' -Flash
    }
}

function Set-Busy {
    param([bool]$IsBusy, [string]$Label = 'Idle')
    $script:UIState.Busy = $IsBusy
    if (-not $IsBusy) {
        $script:UIState.CancellationRequested = $false
        $script:UIState.CancellationState = 'Idle'
        $script:UIState.WorkerState = 'Idle'
    }
    $ui.statusText.Text = $Label
    $ui.statusText.Foreground = if ($IsBusy) { $window.Resources['Blue'] } else { $window.Resources['Subtext0'] }
    $ui.progressBar.IsIndeterminate = $IsBusy
    $ui.btnDisable.IsEnabled = -not $IsBusy
    $ui.btnRemove.IsEnabled  = -not $IsBusy
    $ui.btnRestore.IsEnabled = -not $IsBusy
    $ui.btnRepair.IsEnabled = -not $IsBusy
    $ui.btnRefresh.IsEnabled = -not $IsBusy
    $ui.btnCancelOperation.Visibility = if ($IsBusy) { 'Visible' } else { 'Collapsed' }
    $ui.btnCancelOperation.IsEnabled = $IsBusy -and -not $script:UIState.CancellationRequested
}

# ---------------------------------------------------------------------------
# Recovery and diagnostics hub
# ---------------------------------------------------------------------------
$script:RecoveryRunspace = $null
$script:RecoveryAsyncResult = $null
$script:RecoveryAsyncPS = $null
$script:RecoveryAsyncStarted = $null
$script:RecoveryKind = $null
$script:RecoveryTarget = 'Disable'

function Get-RecoveryTargetSelection {
    $target = [string]$ui.cmbRecoveryTarget.SelectedValue
    if ($target -notin @('Disable', 'Remove', 'Restore')) {
        $target = 'Disable'
    }
    return $target
}

function Set-RecoveryBusy {
    param([bool]$IsBusy, [string]$Label = 'Ready')

    $script:UIState.RecoveryBusy = $IsBusy
    $ui.recoveryStatusText.Text = $Label
    $ui.recoveryStatusText.Foreground = if ($IsBusy) { $window.Resources['Blue'] } else { $window.Resources['Subtext0'] }
    $ui.cmbRecoveryTarget.IsEnabled = -not $IsBusy
    $ui.btnRecoveryRefresh.IsEnabled = -not $IsBusy
    $ui.btnRecoveryCancel.IsEnabled = $IsBusy -and -not $script:UIState.RecoveryCancellationRequested
    $ui.btnRecoverySnapshot.IsEnabled = -not $IsBusy
    $ui.btnRecoveryCompare.IsEnabled = -not $IsBusy
    $ui.btnRecoveryChooseBaseline.IsEnabled = -not $IsBusy
    $ui.btnRecoveryExportReport.IsEnabled = -not $IsBusy
    $ui.btnRecoveryExportSupport.IsEnabled = -not $IsBusy
    $ui.btnRecoveryClose.IsEnabled = -not $IsBusy
    $ui.btnRecoveryDone.IsEnabled = -not $IsBusy
    $ui.btnRecoveryResume.IsEnabled = (-not $IsBusy) -and [bool]$script:UIState.RecoveryCanResume
    $ui.btnRecoveryRollback.IsEnabled = (-not $IsBusy) -and [bool]$script:UIState.RecoveryCanRollback
}

function New-RecoveryFailureResult {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Message,
        [bool]$Cancelled = $false
    )

    return [PSCustomObject][ordered]@{
        Ok         = $false
        Succeeded  = $false
        Cancelled  = $Cancelled
        Kind       = $Kind
        Target     = $Target
        Error      = $Message
        Completed  = (Get-Date).ToString('o')
    }
}

function Request-RecoveryCancellation {
    if (-not $script:UIState.RecoveryBusy) { return }
    if ($script:UIState.RecoveryCancellationRequested) { return }

    $script:UIState.RecoveryCancellationRequested = $true
    $script:UIState.RecoveryWorkerState = 'FinishingCurrentQuery'
    $ui.btnRecoveryCancel.IsEnabled = $false
    $ui.recoveryStatusText.Text = 'Cancellation requested; finishing current query boundary...'
    Show-Toast 'Recovery query cancellation requested.' warn
}

function Complete-RecoveryWorker {
    if ($null -eq $script:RecoveryAsyncPS) { return $null }
    if ($null -ne $script:RecoveryAsyncResult -and -not $script:RecoveryAsyncResult.IsCompleted) {
        return $null
    }

    $asyncPowerShell = $script:RecoveryAsyncPS
    $asyncResult = $script:RecoveryAsyncResult
    $endError = $null
    $script:UIState.RecoveryWorkerState = 'Draining'
    try {
        if ($null -ne $asyncResult) {
            $asyncPowerShell.EndInvoke($asyncResult) | Out-Null
        }
    } catch {
        $endError = $_
    } finally {
        try { $asyncPowerShell.Dispose() } catch {}
        if ($null -ne $script:RecoveryRunspace) {
            try { $script:RecoveryRunspace.Close() } catch {}
            try { $script:RecoveryRunspace.Dispose() } catch {}
        }
        $script:RecoveryAsyncResult = $null
        $script:RecoveryAsyncPS = $null
        $script:RecoveryRunspace = $null
        $script:RecoveryAsyncStarted = $null
    }
    return $endError
}

function Start-RecoveryWorkerAsync {
    param(
        [ValidateSet('Refresh','Snapshot','Compare','Report','Support')]
        [string]$Kind = 'Refresh',
        [ValidateSet('Disable','Remove','Restore')]
        [string]$Target = 'Disable',
        [string]$BaselinePath,
        [string]$CurrentPath,
        [string]$OutputPath,
        [string]$OutputDirectory
    )

    if ($script:UIState.RecoveryBusy) { return }
    if ($script:UIState.Busy) {
        Show-Toast 'Wait for the current operation to finish before querying recovery evidence.' warn
        return
    }

    $script:UIState.RecoveryRunId = [guid]::NewGuid().ToString()
    $script:UIState.RecoveryCancellationRequested = $false
    $script:UIState.RecoveryWorkerState = 'Starting'
    $script:UIState.RecoveryResult = $null
    $script:RecoveryKind = $Kind
    $script:RecoveryTarget = $Target
    Set-RecoveryBusy -IsBusy $true -Label "Running $Kind..."

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('UIState', $script:UIState)
    $rs.SessionStateProxy.SetVariable('ModulePath', $modulePath)
    $rs.SessionStateProxy.SetVariable('Kind', $Kind)
    $rs.SessionStateProxy.SetVariable('Target', $Target)
    $rs.SessionStateProxy.SetVariable('BaselinePath', $BaselinePath)
    $rs.SessionStateProxy.SetVariable('CurrentPath', $CurrentPath)
    $rs.SessionStateProxy.SetVariable('OutputPath', $OutputPath)
    $rs.SessionStateProxy.SetVariable('OutputDirectory', $OutputDirectory)
    $rs.SessionStateProxy.SetVariable('PhaseStatePath', (Join-Path $script:AppDir 'phase-state.json'))

    $worker = {
        Import-Module -Name $ModulePath -Force -ErrorAction Stop

        function Assert-RecoveryBoundary {
            if ([bool]$UIState.RecoveryCancellationRequested) {
                throw [System.OperationCanceledException]::new('Recovery query cancelled at a safe boundary.')
            }
        }

        function Read-RecoveryPhaseState {
            if (-not (Test-Path -LiteralPath $PhaseStatePath)) { return $null }
            try {
                return (Get-Content -Raw -LiteralPath $PhaseStatePath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                throw "Persisted phase state could not be read: $($_.Exception.Message)"
            }
        }

        try {
            $UIState.RecoveryWorkerState = 'Running'
            Assert-RecoveryBoundary
            $result = $null
            switch ($Kind) {
                'Refresh' {
                    $health = Get-DefenderHealth -Target $Target
                    Assert-RecoveryBoundary
                    $safeMode = Get-DefenderSafeModeStatus
                    Assert-RecoveryBoundary
                    $phase = Read-RecoveryPhaseState
                    Assert-RecoveryBoundary
                    $lastResult = $UIState.LastResult
                    if ($null -eq $lastResult -and $phase -and $phase.Result) {
                        $lastResult = $phase.Result
                    }
                    $result = [ordered]@{
                        Ok = $true
                        Succeeded = $true
                        Cancelled = $false
                        Kind = $Kind
                        Target = $Target
                        Health = $health
                        SafeMode = $safeMode
                        Phase = $phase
                        LastResult = $lastResult
                        Completed = (Get-Date).ToString('o')
                    }
                }
                'Snapshot' {
                    $snapshot = Save-DefenderSnapshot -OutputPath $OutputPath -HealthTarget $Target
                    Assert-RecoveryBoundary
                    $result = [ordered]@{
                        Ok = $true
                        Succeeded = $true
                        Cancelled = $false
                        Kind = $Kind
                        Target = $Target
                        Snapshot = $snapshot
                        Completed = (Get-Date).ToString('o')
                    }
                }
                'Compare' {
                    Assert-RecoveryBoundary
                    if ([string]::IsNullOrWhiteSpace($CurrentPath)) {
                        $diff = Compare-DefenderSnapshots -BaselinePath $BaselinePath -HealthTarget $Target
                    } else {
                        $diff = Compare-DefenderSnapshots -BaselinePath $BaselinePath -CurrentPath $CurrentPath -HealthTarget $Target
                    }
                    Assert-RecoveryBoundary
                    $result = [ordered]@{
                        Ok = $true
                        Succeeded = $true
                        Cancelled = $false
                        Kind = $Kind
                        Target = $Target
                        Diff = $diff
                        Completed = (Get-Date).ToString('o')
                    }
                }
                'Report' {
                    $report = Export-DefenderHtmlReport -OutputPath $OutputPath -HealthTarget $Target
                    Assert-RecoveryBoundary
                    $result = [ordered]@{
                        Ok = $true
                        Succeeded = $true
                        Cancelled = $false
                        Kind = $Kind
                        Target = $Target
                        Report = $report
                        Completed = (Get-Date).ToString('o')
                    }
                }
                'Support' {
                    $bundle = Export-DefenderSupportBundle -OutputDirectory $OutputDirectory -HealthTarget $Target
                    Assert-RecoveryBoundary
                    $result = [ordered]@{
                        Ok = $true
                        Succeeded = $true
                        Cancelled = $false
                        Kind = $Kind
                        Target = $Target
                        SupportBundle = $bundle
                        Completed = (Get-Date).ToString('o')
                    }
                }
            }
            if ($null -eq $result) { throw "Recovery worker returned no result for $Kind." }
            $UIState.RecoveryResult = [PSCustomObject]$result
            $UIState.RecoveryWorkerState = 'Completed'
        } catch {
            $cancelled = [bool]$UIState.RecoveryCancellationRequested -or
                $_.Exception -is [System.OperationCanceledException]
            $message = if ($cancelled) {
                'Recovery query cancelled at a safe boundary; no success was reported.'
            } else {
                $_.Exception.Message
            }
            $UIState.RecoveryResult = [PSCustomObject][ordered]@{
                Ok = $false
                Succeeded = $false
                Cancelled = $cancelled
                Kind = $Kind
                Target = $Target
                Error = $message
                Completed = (Get-Date).ToString('o')
            }
            $UIState.RecoveryWorkerState = if ($cancelled) { 'Cancelled' } else { 'Failed' }
        }
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($worker)
    $script:RecoveryAsyncPS = $ps
    $script:RecoveryRunspace = $rs
    $script:RecoveryAsyncResult = $ps.BeginInvoke()
    $script:RecoveryAsyncStarted = Get-Date
}

function Set-RecoveryDiffView {
    param([Parameter(Mandatory)]$Diff)

    $ui.recoveryDiffSummaryText.Text = "Changed: $($Diff.ChangedCount) | Baseline: $($Diff.BaselineTimestamp) | Live: $($Diff.CurrentTimestamp)"
    $ui.recoveryDiffSummaryText.Foreground = if ([int]$Diff.ChangedCount -gt 0) {
        $window.Resources['Yellow']
    } else {
        $window.Resources['Green']
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Diff.Diffs | Select-Object -First 20)) {
        [void]$lines.Add(("[{0}] {1} / {2}" -f $item.Change, $item.Category, $item.Name))
        [void]$lines.Add(("  {0} -> {1}" -f $item.Before, $item.After))
    }
    if ($lines.Count -eq 0) {
        $ui.recoveryDiffText.Text = 'No changes detected between the selected baseline and current state.'
    } else {
        if ([int]$Diff.ChangedCount -gt 20) {
            [void]$lines.Add("... $([int]$Diff.ChangedCount - 20) more change(s)")
        }
        $ui.recoveryDiffText.Text = $lines -join "`r`n"
    }
}

function Update-RecoveryHubView {
    param($Data)

    if ($null -eq $Data) { return }
    if (-not [bool]$Data.Ok) {
        $ui.recoveryStatusText.Text = if ($Data.Cancelled) { 'Cancelled' } else { 'Failed' }
        $ui.recoveryStatusText.Foreground = if ($Data.Cancelled) { $window.Resources['Yellow'] } else { $window.Resources['Red'] }
        return
    }

    $kind = [string]$Data.Kind
    switch ($kind) {
        'Refresh' {
            $target = [string]$Data.Target
            $health = $Data.Health
            $summary = $health.Summary
            $ui.recoveryTargetText.Text = "Target: $target | Live evidence: $($health.Generated)"
            $ui.recoveryHealthText.Text = "OK $($summary.OK)  |  Drift $($summary.Drift)  |  Unknown $($summary.Unknown)  |  Total $($summary.Total)"
            $ui.recoveryHealthText.Foreground = if ([int]$summary.Drift -gt 0) {
                $window.Resources['Red']
            } elseif ([int]$summary.Unknown -gt 0) {
                $window.Resources['Yellow']
            } else {
                $window.Resources['Green']
            }

            $driftItems = @($health.Items | Where-Object { $_.Status -ne 'OK' } | Select-Object -First 12)
            $driftLines = New-Object System.Collections.Generic.List[string]
            foreach ($item in $driftItems) {
                [void]$driftLines.Add(("[{0}] {1}" -f $item.Status, $item.Name))
                [void]$driftLines.Add(("  expected: {0}`r`n  actual:   {1}" -f $item.Expected, $item.Actual))
            }
            if ($driftLines.Count -eq 0) {
                $ui.recoveryDriftText.Text = 'No drift or unknown values detected for this target.'
            } else {
                if (($summary.Drift + $summary.Unknown) -gt $driftItems.Count) {
                    [void]$driftLines.Add("... $([int]$summary.Drift + [int]$summary.Unknown - $driftItems.Count) more item(s)")
                }
                $ui.recoveryDriftText.Text = $driftLines -join "`r`n"
            }

            $phase = $Data.Phase
            $canRecover = $false
            if ($null -eq $phase) {
                $ui.recoveryPhaseText.Text = 'No persisted phase state found.'
            } elseif ($phase.ReadError) {
                $ui.recoveryPhaseText.Text = "Phase state unreadable: $($phase.ReadError)"
            } else {
                $runningPhase = @($phase.Phases | Where-Object { $_.Status -eq 'Running' } | Select-Object -Last 1)
                $phaseName = if ($runningPhase.Count -gt 0) { $runningPhase[0].Name } elseif ($phase.FailedPhase) { $phase.FailedPhase } else { 'none' }
                $ui.recoveryPhaseText.Text = "Mode $($phase.Mode) | Status $($phase.Status) | Phase $phaseName | Updated $($phase.Updated)"
                $canRecover = [string]$phase.Status -in @('Running', 'Failed', 'Cancelled') -and
                    [string]$phase.Mode -in @('Disable', 'Remove', 'Restore')
            }
            $script:UIState.RecoveryCanResume = $canRecover
            $script:UIState.RecoveryCanRollback = $canRecover
            $ui.btnRecoveryResume.IsEnabled = $canRecover
            $ui.btnRecoveryRollback.IsEnabled = $canRecover

            $safeMode = $Data.SafeMode
            if ($safeMode) {
                $ui.recoverySafeModeText.Text = "Safe Mode: $($safeMode.Stage) | Verified $($safeMode.VerifiedEffects)/$($safeMode.RequiredEffects) | Recommendation: $($safeMode.RecoveryRecommendation)"
            } else {
                $ui.recoverySafeModeText.Text = 'Safe Mode transaction status unavailable.'
            }

            $last = $Data.LastResult
            if ($last -and ($last.PSObject.Properties.Name -contains 'Succeeded')) {
                $lastStatus = if ($last.Succeeded) { 'verified' } elseif ($last.Cancelled) { 'cancelled' } else { 'failed' }
                $ui.recoveryLastResultText.Text = "Last verified result: $($last.Mode) $lastStatus | changed $($last.Changed) | verified $($last.Verified) | completed $($last.Completed)"
            } else {
                $ui.recoveryLastResultText.Text = 'Last verified result: none available.'
            }
            $ui.recoveryStatusText.Text = "Evidence refreshed $($Data.Completed)"
            $ui.recoveryStatusText.Foreground = $window.Resources['Green']
        }
        'Snapshot' {
            $path = [string]$Data.Snapshot.SnapshotPath
            $ui.txtRecoveryBaselinePath.Text = $path
            $ui.recoverySnapshotText.Text = "Saved $($Data.Target) snapshot: $path"
            $ui.recoveryStatusText.Text = 'Snapshot saved locally.'
            $ui.recoveryStatusText.Foreground = $window.Resources['Green']
        }
        'Compare' {
            Set-RecoveryDiffView -Diff $Data.Diff
            $ui.recoveryStatusText.Text = "Compared baseline to live $($Data.Target) evidence."
            $ui.recoveryStatusText.Foreground = $window.Resources['Green']
        }
        'Report' {
            $ui.recoveryStatusText.Text = "HTML report saved: $($Data.Report.ReportPath)"
            $ui.recoveryStatusText.Foreground = $window.Resources['Green']
        }
        'Support' {
            $ui.recoveryStatusText.Text = "Support bundle saved: $($Data.SupportBundle.BundlePath)"
            $ui.recoveryStatusText.Foreground = $window.Resources['Green']
        }
    }
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
        $firewallStatus = Get-DefenderFirewallStatus
        $firewallIssues = @($firewallStatus.Issues)
        Set-FirewallBannerState -Issues $firewallIssues -Source 'live poll'
        $fwOn = [bool]$firewallStatus.Healthy
        $ui.dotFW.Fill = if ($fwOn) { $window.Resources['Green'] } else { $window.Resources['Red'] }
        $ui.valFW.Text = if ($fwOn) { 'ON' } else { 'TRIPPED' }
        $ui.valFW.Foreground = if ($fwOn) { $window.Resources['Green'] } else { $window.Resources['Red'] }
        if ($fwOn) {
            $ui.subFW.Text = ($firewallStatus.Profiles | ForEach-Object {
                "$($_.Name)=On"
            }) -join ', '
        } else {
            $ui.subFW.Text = (@($firewallIssues) | Select-Object -First 2) -join '; '
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
        if ($total -eq 0) {
            $ui.valSvc.Text = 'N/A'
            $ui.valSvc.Foreground = $window.Resources['Yellow']
            $ui.subSvc.Text = 'Service catalog unavailable'
            $ui.dotSvc.Fill = $window.Resources['Yellow']
        } else {
            $ui.valSvc.Text = "$disabled / $present"
            $ui.valSvc.Foreground = $window.Resources['Text']
            $ui.subSvc.Text = "$total known; $present present"
            if ($present -gt 0 -and $disabled -eq $present) { $ui.dotSvc.Fill = $window.Resources['Green'] }
            elseif ($disabled -gt 0) { $ui.dotSvc.Fill = $window.Resources['Yellow'] }
            else { $ui.dotSvc.Fill = $window.Resources['Red'] }
        }

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
        Update-ComponentTiles
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
$script:AsyncStarted = $null

function New-GuiWorkerFailureResult {
    param(
        [Parameter(Mandatory)][string]$ActionMode,
        [Parameter(Mandatory)][string]$Message,
        [bool]$Cancelled = $false
    )

    return [PSCustomObject][ordered]@{
        Ok         = $false
        Succeeded  = $false
        Cancelled  = $Cancelled
        Mode       = $ActionMode
        RunId      = $script:UIState.RunId
        Attempted  = 0
        Changed    = 0
        Verified   = 0
        Errors     = @($Message)
        Evidence   = @()
        Phases     = @()
        Completed  = (Get-Date).ToString('o')
    }
}

function Request-OperationCancellation {
    if (-not $script:UIState.Busy) { return }
    if ($script:UIState.CancellationRequested) { return }

    $script:UIState.CancellationRequested = $true
    $script:UIState.CancellationState = 'Requested'
    $script:UIState.WorkerState = 'FinishingCurrentPhase'
    $ui.btnCancelOperation.IsEnabled = $false
    $ui.statusText.Text = 'Cancellation requested; finishing current phase...'
    Show-Toast 'Cancellation requested. The current phase will finish safely before the worker exits.' warn
    Write-Log 'GUI cancellation requested; waiting for the current non-cancellable phase boundary.' WARN
}

function Complete-AsyncWorker {
    if ($null -eq $script:AsyncPS) { return $null }
    if ($null -ne $script:AsyncResult -and -not $script:AsyncResult.IsCompleted) {
        return $null
    }

    $asyncPowerShell = $script:AsyncPS
    $asyncResult = $script:AsyncResult
    $endError = $null
    $script:UIState.WorkerState = 'Draining'
    try {
        if ($null -ne $asyncResult) {
            $asyncPowerShell.EndInvoke($asyncResult) | Out-Null
        }
    } catch {
        $endError = $_
    } finally {
        try { $asyncPowerShell.Dispose() } catch {}
        if ($null -ne $script:Runspace) {
            try { $script:Runspace.Close() } catch {}
            try { $script:Runspace.Dispose() } catch {}
        }
        $script:AsyncResult = $null
        $script:AsyncPS = $null
        $script:Runspace = $null
        $script:AsyncStarted = $null
    }
    return $endError
}

function Start-ModeAsync {
    param(
        [ValidateSet('Disable','Remove','Restore')][string]$ActionMode,
        [switch]$ForceOverride,
        [switch]$RepairWithoutManifest
    )
    if ($script:UIState.Busy) { return }
    $script:UIState.RunId = [guid]::NewGuid().ToString()
    $script:UIState.CancellationRequested = $false
    $script:UIState.CancellationState = 'Running'
    $script:UIState.WorkerState = 'Starting'
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
    $rs.SessionStateProxy.SetVariable('ForceOverride', [bool]$ForceOverride)
    $rs.SessionStateProxy.SetVariable('RepairWithoutManifest', [bool]$RepairWithoutManifest)

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
            $UIState.WorkerState = 'Running'
            $cancellationCallback = { [bool]$UIState.CancellationRequested }
            $operationOutput = @(switch ($ActionMode) {
                'Disable' { Invoke-DisableDefender -Force:$ForceOverride -LogPath $LogPath -LogCallback $logCallback -CancellationCallback $cancellationCallback -Confirm:$false }
                'Remove'  { Invoke-RemoveDefender -Force:$ForceOverride -LogPath $LogPath -LogCallback $logCallback -CancellationCallback $cancellationCallback -Confirm:$false }
                'Restore' {
                    Invoke-RestoreDefender -RepairWithoutManifest:$RepairWithoutManifest `
                        -LogPath $LogPath -LogCallback $logCallback -CancellationCallback $cancellationCallback -Confirm:$false
                }
            })
            $operationResult = @($operationOutput | Where-Object {
                $_.PSObject.Properties.Name -contains 'Succeeded' -and
                $_.PSObject.Properties.Name -contains 'Phases'
            } | Select-Object -Last 1)
            if ($operationResult.Count -eq 0 -or -not $operationResult[0].Succeeded) {
                throw "$ActionMode did not return a successful verified operation result."
            }
            $UIState.LastResult = $operationResult[0]
            $UIState.WorkerState = 'Completed'
        } catch {
            $cancelled = [bool]$UIState.CancellationRequested -or
                $_.Exception -is [System.OperationCanceledException]
            $message = if ($cancelled) {
                'Operation cancelled at a safe phase boundary; no phase was interrupted.'
            } else {
                "FATAL: $($_.Exception.Message)"
            }
            & $logCallback -Message $message -Level $(if ($cancelled) { 'WARN' } else { 'ERROR' })
            $UIState.LastResult = [PSCustomObject][ordered]@{
                Ok         = $false
                Succeeded  = $false
                Cancelled  = $cancelled
                Mode       = $ActionMode
                RunId      = $UIState.RunId
                Attempted  = 0
                Changed    = 0
                Verified   = 0
                Errors     = @($message)
                Evidence   = @()
                Phases     = @()
                Completed  = (Get-Date).ToString('o')
            }
            $UIState.WorkerState = if ($cancelled) { 'Cancelled' } else { 'Failed' }
        }
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($worker)
    $script:AsyncPS = $ps
    $script:Runspace = $rs
    $script:AsyncResult = $ps.BeginInvoke()
    $script:AsyncStarted = Get-Date
    $script:UIState.LastAction = $ActionMode
    $script:UIState.LastResult = $null
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
        $workerError = Complete-AsyncWorker
        if ($null -ne $workerError -and $null -eq $script:UIState.LastResult) {
            $script:UIState.LastResult = New-GuiWorkerFailureResult `
                -ActionMode $script:UIState.LastAction `
                -Message "Worker drain failed: $($workerError.Exception.Message)" `
                -Cancelled:$script:UIState.CancellationRequested
        }

        $result = $script:UIState.LastResult
        $action = $script:UIState.LastAction
        Set-Busy -IsBusy $false -Label 'Idle'
        if ($null -ne $result -and $result.Succeeded) {
            $completionMessage = Get-GuiText -Id 'gui.tray.success' -ArgumentList @(
                $action, $result.Verified, $result.Changed)
            Show-Toast $completionMessage ok
            Show-GuiCompletionNotification -Message $completionMessage -Status Success
        } elseif ($null -ne $result -and $result.Cancelled) {
            $completionMessage = Get-GuiText -Id 'gui.tray.cancelled' -ArgumentList @($action)
            Show-Toast $completionMessage warn
            Show-GuiCompletionNotification -Message $completionMessage -Status Cancelled
        } else {
            $errorText = if ($null -ne $result -and @($result.Errors).Count -gt 0) {
                @($result.Errors) -join '; '
            } else {
                Get-GuiText -Id 'gui.recovery.noresult'
            }
            $completionMessage = Get-GuiText -Id 'gui.tray.failed' -ArgumentList @($action, $errorText)
            Show-Toast $completionMessage error
            Show-GuiCompletionNotification -Message $completionMessage -Status Failed
        }
        Update-StatusTiles
        if ($ui.recoveryOverlay.Visibility -eq 'Visible' -and -not $script:UIState.RecoveryBusy) {
            Start-RecoveryWorkerAsync -Kind Refresh -Target (Get-RecoveryTargetSelection)
        }
    }
    # Drain the read-only recovery/diagnostics worker.
    if ($script:RecoveryAsyncResult -and $script:RecoveryAsyncResult.IsCompleted) {
        $kind = $script:RecoveryKind
        $workerError = Complete-RecoveryWorker
        $result = $script:UIState.RecoveryResult
        if ($null -ne $workerError -and $null -eq $result) {
            $result = New-RecoveryFailureResult -Kind $kind -Target $script:RecoveryTarget `
                -Message "Recovery worker drain failed: $($workerError.Exception.Message)" `
                -Cancelled:$script:UIState.RecoveryCancellationRequested
            $script:UIState.RecoveryResult = $result
        }
        Set-RecoveryBusy -IsBusy $false -Label 'Ready'
        if ($null -eq $result) {
            $result = New-RecoveryFailureResult -Kind $kind -Target $script:RecoveryTarget `
                -Message 'Recovery worker returned no result.'
            $script:UIState.RecoveryResult = $result
        }
        if ($result.Ok) {
            Update-RecoveryHubView -Data $result
            if ($kind -eq 'Refresh') {
                Show-Toast 'Recovery evidence refreshed.' ok
            } else {
                Show-Toast "Recovery $($kind.ToLowerInvariant()) completed locally." ok
            }
        } elseif ($result.Cancelled) {
            $ui.recoveryStatusText.Text = 'Cancelled at a safe query boundary; no success was reported.'
            $ui.recoveryStatusText.Foreground = $window.Resources['Yellow']
            Show-Toast 'Recovery query cancelled safely.' warn
        } else {
            $ui.recoveryStatusText.Text = "Recovery $($kind.ToLowerInvariant()) failed: $($result.Error)"
            $ui.recoveryStatusText.Foreground = $window.Resources['Red']
            Show-Toast "Recovery $($kind.ToLowerInvariant()) failed." error
        }
        $script:RecoveryKind = $null
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
function Update-MaximizeButtonState {
    if ($window.WindowState -eq 'Maximized') {
        $ui.btnMax.Content = [char]0xE923
        $ui.btnMax.ToolTip = 'Restore window'
        [System.Windows.Automation.AutomationProperties]::SetName($ui.btnMax, 'Restore window')
    } else {
        $ui.btnMax.Content = [char]0xE922
        $ui.btnMax.ToolTip = 'Maximize'
        [System.Windows.Automation.AutomationProperties]::SetName($ui.btnMax, 'Maximize window')
    }
}

function Invoke-WindowStateToggle {
    $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
}

function Open-RecoveryHub {
    $ui.recoveryOverlay.Visibility = 'Visible'
    if (-not $script:UIState.RecoveryBusy -and -not $script:UIState.Busy) {
        Start-RecoveryWorkerAsync -Kind Refresh -Target (Get-RecoveryTargetSelection)
    }
}

function Close-RecoveryHub {
    if ($script:UIState.RecoveryBusy) {
        Show-Toast 'Cancel the recovery query and wait for its safe boundary before closing the hub.' warn
        return
    }
    $ui.recoveryOverlay.Visibility = 'Collapsed'
}

function Get-RecoveryPhaseForAction {
    $data = $script:UIState.RecoveryResult
    if ($null -eq $data -or -not $data.Ok -or $data.Kind -ne 'Refresh' -or $null -eq $data.Phase) {
        return $null
    }
    if ([string]$data.Phase.Status -notin @('Running', 'Failed', 'Cancelled')) { return $null }
    if ([string]$data.Phase.Mode -notin @('Disable', 'Remove', 'Restore')) { return $null }
    return $data.Phase
}

$ui.titleBar.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) {
        Invoke-WindowStateToggle
        $e.Handled = $true
    } elseif ($window.WindowState -eq 'Normal') {
        $window.DragMove()
    }
})
$ui.btnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.btnMax.Add_Click({ Invoke-WindowStateToggle })
$ui.btnClose.Add_Click({ $window.Close() })
$window.Add_StateChanged({ Update-MaximizeButtonState })
$ui.btnRecoveryHub.Add_Click({ Open-RecoveryHub })
$ui.btnRecoveryClose.Add_Click({ Close-RecoveryHub })
$ui.btnRecoveryDone.Add_Click({ Close-RecoveryHub })
$ui.btnRecoveryCancel.Add_Click({ Request-RecoveryCancellation })
$ui.btnRecoveryRefresh.Add_Click({
    Start-RecoveryWorkerAsync -Kind Refresh -Target (Get-RecoveryTargetSelection)
})
$ui.cmbRecoveryTarget.Add_SelectionChanged({
    if ($ui.recoveryOverlay.Visibility -eq 'Visible' -and -not $script:UIState.RecoveryBusy) {
        Start-RecoveryWorkerAsync -Kind Refresh -Target (Get-RecoveryTargetSelection)
    }
})
$ui.btnRecoveryChooseBaseline.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Defender snapshots|*.json|All files|*.*'
    $dlg.Title = 'Select a Defender snapshot baseline'
    if ($dlg.ShowDialog($window)) {
        $ui.txtRecoveryBaselinePath.Text = $dlg.FileName
        $ui.recoveryStatusText.Text = 'Snapshot baseline selected.'
    }
})
$ui.btnRecoverySnapshot.Add_Click({
    $target = Get-RecoveryTargetSelection
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Defender snapshots|*.json|All files|*.*'
    $dlg.FileName = "DisableDefender-$($target.ToLowerInvariant())-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $dlg.Title = 'Save a target-aware Defender snapshot'
    if ($dlg.ShowDialog($window)) {
        Start-RecoveryWorkerAsync -Kind Snapshot -Target $target -OutputPath $dlg.FileName
    }
})
$ui.btnRecoveryCompare.Add_Click({
    $baselinePath = [string]$ui.txtRecoveryBaselinePath.Text
    if ([string]::IsNullOrWhiteSpace($baselinePath)) {
        Show-Toast 'Choose a snapshot baseline before comparing.' warn
        $ui.btnRecoveryChooseBaseline.Focus() | Out-Null
    } elseif (-not (Test-Path -LiteralPath $baselinePath)) {
        Show-Toast 'The selected snapshot baseline does not exist.' error
    } else {
        Start-RecoveryWorkerAsync -Kind Compare -Target (Get-RecoveryTargetSelection) -BaselinePath $baselinePath
    }
})
$ui.btnRecoveryExportReport.Add_Click({
    $target = Get-RecoveryTargetSelection
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'HTML reports|*.html|All files|*.*'
    $dlg.FileName = "DisableDefender-$($target.ToLowerInvariant())-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
    $dlg.Title = 'Export a local Defender HTML report'
    if ($dlg.ShowDialog($window)) {
        Start-RecoveryWorkerAsync -Kind Report -Target $target -OutputPath $dlg.FileName
    }
})
$ui.btnRecoveryExportSupport.Add_Click({
    $folder = New-Object System.Windows.Forms.FolderBrowserDialog
    $folder.Description = 'Select a local folder for the redacted DisableDefender support bundle'
    $folder.ShowNewFolderButton = $true
    if ($folder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Start-RecoveryWorkerAsync -Kind Support -Target (Get-RecoveryTargetSelection) -OutputDirectory $folder.SelectedPath
    }
})
$ui.btnRecoveryResume.Add_Click({
    $phase = Get-RecoveryPhaseForAction
    if ($phase) {
        $script:RecoveryPendingMode = [string]$phase.Mode
        $ui.recoveryOverlay.Visibility = 'Collapsed'
        Show-Confirm -Title "Resume $($script:RecoveryPendingMode) phase plan?" `
            -Body "The persisted phase state is $($phase.Status) at $($phase.FailedPhase). Rerun the idempotent $($script:RecoveryPendingMode) plan to resume verified work. Safety gates and the Firewall boundary still apply." `
            -Kind Warning -ConfirmLabel 'Resume phase plan' -OnProceed {
                Start-ModeAsync -ActionMode $script:RecoveryPendingMode
            }
    }
})
$ui.btnRecoveryRollback.Add_Click({
    $phase = Get-RecoveryPhaseForAction
    if ($phase) {
        $ui.recoveryOverlay.Visibility = 'Collapsed'
        Show-Confirm -Title 'Rollback the interrupted operation?' `
            -Body "Restore will replay the recorded baseline for the interrupted $($phase.Mode) operation and verify it before archiving the manifest. If no valid undo manifest exists, the action stops without changing the machine." `
            -Kind Recovery -ConfirmLabel 'Rollback with Restore' -OnProceed {
                Start-ModeAsync -ActionMode 'Restore'
            }
    }
})

# Confirmation modal buttons - registered once
$ui.btnConfirmCancel.Add_Click({ $ui.confirmOverlay.Visibility = 'Collapsed'; $script:ConfirmAction = $null })
$window.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape' -and $ui.confirmOverlay.Visibility -eq 'Visible') {
        $ui.confirmOverlay.Visibility = 'Collapsed'
        $script:ConfirmAction = $null
        $e.Handled = $true
    } elseif ($e.Key -eq 'Escape' -and $ui.recoveryOverlay.Visibility -eq 'Visible') {
        Close-RecoveryHub
        $e.Handled = $true
    } elseif ($e.Key -eq 'F5' -and $ui.confirmOverlay.Visibility -ne 'Visible' -and -not $script:UIState.Busy) {
        Update-StatusTiles
        Show-Toast 'Security status refreshed.' info
        $e.Handled = $true
    }
})
$ui.btnConfirmOk.Add_Click({
    $ui.confirmOverlay.Visibility = 'Collapsed'
    if ($ui.confirmForcePanel -and $ui.confirmForcePanel.Visibility -eq 'Visible' -and $ui.confirmForceOverride) {
        $script:ConfirmForceOverride = [bool]$ui.confirmForceOverride.IsChecked
    } else {
        $script:ConfirmForceOverride = $false
    }
    if ($script:ConfirmAction) {
        $action = $script:ConfirmAction
        $script:ConfirmAction = $null
        & $action
    }
})

$ui.btnCancelOperation.Add_Click({ Request-OperationCancellation })

$ui.btnOpenSecurity.Add_Click({
    Start-Process 'windowsdefender:' -ErrorAction SilentlyContinue
})

$ui.btnRefresh.Add_Click({
    Update-StatusTiles
    Show-Toast 'Status refreshed.' info
})

$ui.btnDisable.Add_Click({
    $diffText = Get-DisableTargetDiffText
    Show-Confirm -Title 'Disable Microsoft Defender?' -Body "Defender protection will be disabled using policy, service, task, and runtime-preference changes. This workflow is designed to be reversible through Restore.`n`nThe Windows Firewall boundary remains enforced." -DiffText $diffText -AllowForceOverride -Kind Warning -ConfirmLabel 'Disable Defender' -OnProceed {
        Start-ModeAsync -ActionMode 'Disable' -ForceOverride:$script:ConfirmForceOverride
    }
})

$ui.btnRemove.Add_Click({
    Show-Confirm -Title 'Full Remove Microsoft Defender?' -Body "This is the aggressive path. It will:`n  - Apply all Disable operations`n  - Deprovision the Windows Security UI app`n  - Remove SafeBoot\WinDefend so it cannot load in Safe Mode`n  - DISM-remove Defender platform packages`n`nSafe Mode is recommended. Recovery may require SFC or DISM repair. The Windows Firewall boundary remains enforced." -AllowForceOverride -Kind Danger -ConfirmLabel 'Proceed with removal' -OnProceed {
        Start-ModeAsync -ActionMode 'Remove' -ForceOverride:$script:ConfirmForceOverride
    }
})

$ui.btnRestore.Add_Click({
    Show-Confirm -Title 'Restore the recorded baseline?' -Body "DisableDefender will replay the selected undo manifest, restore the exact recorded policy, preference, task, service, Security Health, SafeBoot, and context-menu state, then verify it before archiving the manifest.`n`nIf no undo manifest exists, this action stops without changing the machine." -Kind Recovery -ConfirmLabel 'Restore baseline' -OnProceed {
        Start-ModeAsync -ActionMode 'Restore'
    }
})

$ui.btnRepair.Add_Click({
    Show-Confirm -Title 'Repair Defender defaults without an undo manifest?' -Body "This is a separate fixed-default repair preset. It does not reconstruct the machine's original non-default settings and cannot be used while an undo manifest is available.`n`nUse this only when no recorded baseline exists." -Kind Warning -ConfirmLabel 'Repair defaults' -OnProceed {
        Start-ModeAsync -ActionMode 'Restore' -RepairWithoutManifest
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
    if ($ui.policyStreamPanel) {
        $ui.policyStreamPanel.Children.Clear()
        if ($ui.policyEmptyState) { $ui.policyStreamPanel.Children.Add($ui.policyEmptyState) | Out-Null }
    }
    Show-Toast 'Log cleared.' info
})

# ---------------------------------------------------------------------------
# Initial render
# ---------------------------------------------------------------------------
Set-GuiPresentationResources
Initialize-GuiTrayIcon
$ui.versionText.Text = "v$script:Version"
$script:GuiAccessibilityReport = Test-GuiAccessibilityContract
$script:GuiHighContrast = Set-GuiHighContrastTheme
Update-MaximizeButtonState
Write-Log "=== $script:AppName GUI v$script:Version ready ==="
Update-StatusTiles

# Drain any pre-window log messages
while ($script:UIState.LogQueue.Count -gt 0) {
    Add-LogEntry ($script:UIState.LogQueue.Dequeue())
}

# ---------------------------------------------------------------------------
# Show window
# ---------------------------------------------------------------------------
$window.Add_Closing({
    param($source, $closingArgs)
    $workerActive = $script:UIState.Busy -or
        ($script:AsyncResult -and -not $script:AsyncResult.IsCompleted) -or
        $script:UIState.RecoveryBusy -or
        ($script:RecoveryAsyncResult -and -not $script:RecoveryAsyncResult.IsCompleted)
    if ($workerActive) {
        $closingArgs.Cancel = $true
        if ($script:UIState.RecoveryBusy -and -not $script:UIState.Busy) {
            Show-Toast 'A recovery query is still running. Cancel it and close after its safe query boundary completes.' warn
        } else {
            Show-Toast 'An operation is still running. Request cancellation and close after the safe phase boundary completes.' warn
        }
    }
})

$window.Add_Closed({
    $drainTimer.Stop()
    $statusTimer.Stop()
    try { $drainTimer.Dispose() } catch {}
    try { $statusTimer.Dispose() } catch {}
    if ($script:AsyncPS -and $script:AsyncResult -and $script:AsyncResult.IsCompleted) {
        Complete-AsyncWorker | Out-Null
    }
    if ($script:RecoveryAsyncPS -and $script:RecoveryAsyncResult -and $script:RecoveryAsyncResult.IsCompleted) {
        Complete-RecoveryWorker | Out-Null
    }
    foreach ($timer in @($script:ToastTimers)) {
        try { $timer.Stop() } catch {}
        try { $timer.Dispose() } catch {}
    }
    $script:ToastTimers.Clear()
    if ($script:TrayIcon) {
        $script:TrayIcon.Visible = $false
        try { $script:TrayIcon.Dispose() } catch {}
        $script:TrayIcon = $null
    }
    if ($script:TrayContextMenu) {
        try { $script:TrayContextMenu.Dispose() } catch {}
        $script:TrayContextMenu = $null
    }
    foreach ($icon in @($script:TrayStatusIcons)) {
        try { $icon.Dispose() } catch {}
    }
    $script:TrayStatusIcons.Clear()
})

$null = $window.ShowDialog()
