# MemTrim Dashboard: on-demand "Clean Now" telemetry HUD.
# Run directly (double-click / shortcut), or as the compiled MemTrim.exe
# (see build.ps1) with Core.ps1 sitting next to it. Self-elevates only when
# you click Clean Memory and admin is needed for the standby-list purge.
# The app itself never needs to run elevated just to open.

$ErrorActionPreference = 'Stop'

# $PSScriptRoot/$MyInvocation.MyCommand.Path are both empty once this script
# has been compiled to an exe (ps2exe). There's no file on disk anymore to
# point at. AppDomain.BaseDirectory is the reliable answer there instead.
$here = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}

# Compiled, dot-sourcing the external Core.ps1 still goes through the
# system's execution policy even though the embedded script itself doesn't,
# scope this to the process only, not a system-wide change.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
. (Join-Path $here 'Core.ps1')

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# palette: monochrome + glass. Severity has no hue to lean on anymore, so it's
# carried entirely by brightness/glow intensity instead: calm is dim, critical
# is the brightest thing on screen.
$BG             = '#0A0A0B'
$PanelMain      = '#0DFFFFFF'   # ~5% white over BG, title bar
$PanelSecondary = '#14FFFFFF'   # ~8% white over BG, the glass card fill
$BorderColor    = '#26FFFFFF'   # ~15% white, outer window edge + hairlines
$BorderSoft     = '#14FFFFFF'   # ~8% white, faint internal borders/gridlines
$TextPrimary    = '#F2F2F3'
$TextSecondary  = '#9B9B9D'
$TextDim        = '#5A5A5C'
$Accent         = '#F5F5F5'     # primary action fill (Clean Memory)
$AccentHover    = '#FFFFFF'
$AccentPressed  = '#D4D4D4'
$SeverityCalm       = '#7A7A7C'   # OPTIMAL
$SeverityElevated   = '#C4C4C6'   # LOW
$SeverityCritical   = '#FFFFFF'   # CRITICAL
$SeverityCalmGlow     = '#0DFFFFFF'
$SeverityElevatedGlow = '#1AFFFFFF'
$SeverityCriticalGlow = '#33FFFFFF'

$FontUI   = 'Segoe UI'
$FontMono = 'Cascadia Mono, Consolas, Segoe UI'

# Icon is optional at the XAML level on purpose: a missing file here would
# throw a XamlParseException on load and crash before the window even
# appears, same failure class as the ControlTemplate name-scope bug.
$IconPath = Join-Path $here 'assets\icon.ico'
$IconAttr = if (Test-Path $IconPath) { "Icon=`"$IconPath`"" } else { '' }

# brush helper
$Script:BrushCache = @{}
function Get-Brush([string]$Hex) {
    if (-not $Script:BrushCache.ContainsKey($Hex)) {
        $b = [Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
        $b.Freeze()
        $Script:BrushCache[$Hex] = $b
    }
    return $Script:BrushCache[$Hex]
}

# health state
function Get-HealthState([double]$freePercent) {
    if ($freePercent -le 10) {
        [PSCustomObject]@{ Name = 'CRITICAL'; Hex = $SeverityCritical;   GlowHex = $SeverityCriticalGlow;   Context = 'MEMORY PRESSURE HIGH' }
    } elseif ($freePercent -le 20) {
        [PSCustomObject]@{ Name = 'LOW';      Hex = $SeverityElevated; GlowHex = $SeverityElevatedGlow; Context = 'MEMORY PRESSURE ELEVATED' }
    } else {
        [PSCustomObject]@{ Name = 'OPTIMAL';  Hex = $SeverityCalm;  GlowHex = $SeverityCalmGlow;  Context = 'AVAILABLE MEMORY' }
    }
}

# XAML
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MemTrim" Width="480" Height="700"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="False"
        Background="$BG" WindowStartupLocation="CenterScreen"
        FontFamily="$FontUI" $IconAttr>
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
    <Style TargetType="ToggleButton">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>

    <Style x:Key="EyebrowText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="$TextDim"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="TitleBarIconButton" TargetType="Button">
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Foreground" Value="$TextSecondary"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" Margin="2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="$BorderSoft"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CleanCheckBox" TargetType="CheckBox">
      <Setter Property="Foreground" Value="$TextPrimary"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="Box" Width="16" Height="16" CornerRadius="3" Background="$PanelSecondary" BorderBrush="$BorderColor" BorderThickness="1" VerticalAlignment="Center">
                <Path x:Name="Check" Data="M 3,8 L 6.5,11.5 L 13,4" Stroke="$BG" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="$Accent"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="$Accent"/>
                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TuneSlider" TargetType="Slider">
      <Setter Property="Height" Value="24"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center" Height="24">
              <Border Height="4" Background="$BorderColor" CornerRadius="2" VerticalAlignment="Center"/>
              <Border x:Name="PART_Fill" Height="4" Background="$Accent" CornerRadius="2" HorizontalAlignment="Left" VerticalAlignment="Center" Width="0"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb x:Name="PART_Thumb" Width="14" Height="14">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Fill="$TextPrimary" Stroke="$Accent" StrokeThickness="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TuneButton" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Foreground" Value="$TextPrimary"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="$PanelSecondary" BorderBrush="$BorderColor" BorderThickness="1" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="$Accent"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="$BorderSoft"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MemTrimScrollBar" TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="$BorderColor" CornerRadius="4" Margin="2,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MemTrimScrollViewer" TargetType="ScrollViewer">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollViewer">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <ScrollContentPresenter x:Name="PART_ScrollContentPresenter" Grid.Column="0"/>
              <ScrollBar x:Name="PART_VerticalScrollBar" Grid.Column="1"
                         Value="{TemplateBinding VerticalOffset}"
                         Maximum="{TemplateBinding ScrollableHeight}"
                         ViewportSize="{TemplateBinding ViewportHeight}"
                         Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"
                         Style="{StaticResource MemTrimScrollBar}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border BorderBrush="$BorderColor" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="40"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- title bar -->
      <Grid x:Name="TitleBar" Grid.Row="0" Background="$PanelMain">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
          <Ellipse x:Name="StatusDot" Width="7" Height="7" Fill="$TextPrimary" Margin="0,0,9,0">
            <Ellipse.Effect>
              <DropShadowEffect x:Name="StatusDotGlow" Color="$TextPrimary" BlurRadius="10" ShadowDepth="0" Opacity="0.9"/>
            </Ellipse.Effect>
          </Ellipse>
          <TextBlock Text="MEMTRIM" Foreground="$TextPrimary" FontSize="12" FontWeight="SemiBold"/>
          <TextBlock Text="  ·  " Foreground="$TextDim" FontSize="11"/>
          <TextBlock x:Name="WatchdogLabel" Text="WATCHDOG ON" Foreground="$TextSecondary" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="MinBtn" Content="—" Style="{StaticResource TitleBarIconButton}"/>
          <Button x:Name="CloseBtn" Content="✕" Style="{StaticResource TitleBarIconButton}"/>
        </StackPanel>
      </Grid>

      <!-- body: in a ScrollViewer because the Tuning drawer changes height and
           the window itself is fixed-size (see the chevron/Tuning handlers below) -->
      <ScrollViewer Grid.Row="1" Style="{StaticResource MemTrimScrollViewer}"
                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <Grid Margin="20,18,20,16">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>  <!-- 0 health header -->
          <RowDefinition Height="16"/>
          <RowDefinition Height="Auto"/>  <!-- 2 gauge -->
          <RowDefinition Height="16"/>
          <RowDefinition Height="Auto"/>  <!-- 4 sparkline panel -->
          <RowDefinition Height="16"/>
          <RowDefinition Height="Auto"/>  <!-- 6 stats -->
          <RowDefinition Height="18"/>
          <RowDefinition Height="Auto"/>  <!-- 8 clean button -->
          <RowDefinition Height="14"/>
          <RowDefinition Height="Auto"/>  <!-- 10 tune toggle -->
          <RowDefinition Height="Auto"/>  <!-- 11 tune drawer -->
          <RowDefinition Height="20"/>  <!-- fixed gap: a Star row collapses to zero inside a ScrollViewer's unbounded height -->
          <RowDefinition Height="Auto"/>  <!-- 13 footer -->
        </Grid.RowDefinitions>

        <!-- 0: memory health header -->
        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <TextBlock Text="MEMORY HEALTH" Style="{StaticResource EyebrowText}"/>
            <TextBlock x:Name="HealthStateText" Text="OPTIMAL" Foreground="$SeverityCalm" FontSize="21" FontWeight="SemiBold" Margin="0,3,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="1" HorizontalAlignment="Right">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Ellipse Width="5" Height="5" Fill="$TextPrimary" Margin="0,0,5,0" VerticalAlignment="Center"/>
              <TextBlock Text="LIVE" Foreground="$TextPrimary" FontSize="10" FontWeight="Bold"/>
            </StackPanel>
            <TextBlock x:Name="LiveClock" Text="--:--:--" Foreground="$TextDim" FontFamily="$FontMono" FontSize="10" Margin="0,3,0,0" HorizontalAlignment="Right"/>
          </StackPanel>
        </Grid>

        <!-- 2: gauge -->
        <Canvas Grid.Row="2" Width="224" Height="224" HorizontalAlignment="Center">
          <Ellipse x:Name="GaugeGlow" Width="188" Height="188" Canvas.Left="18" Canvas.Top="18" Fill="$SeverityCalmGlow">
            <Ellipse.Effect>
              <BlurEffect Radius="24"/>
            </Ellipse.Effect>
          </Ellipse>
          <Ellipse Width="212" Height="212" Canvas.Left="6" Canvas.Top="6" Stroke="$BorderSoft" StrokeThickness="1"/>
          <Path x:Name="GaugeTrack" Stroke="$BorderColor" StrokeThickness="13" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
          <Path x:Name="GaugeValue" Stroke="$SeverityCalm" StrokeThickness="13" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
          <TextBlock x:Name="GaugeNumber" Text="--" FontFamily="$FontMono" FontSize="50" FontWeight="Bold" Foreground="$TextPrimary" Canvas.Left="12" Canvas.Top="80" Width="200" TextAlignment="Center"/>
          <TextBlock Text="% FREE" FontSize="11" FontWeight="SemiBold" Foreground="$TextSecondary" Canvas.Left="12" Canvas.Top="140" Width="200" TextAlignment="Center"/>
          <TextBlock x:Name="GaugeContext" Text="AVAILABLE MEMORY" FontSize="9" FontWeight="SemiBold" Foreground="$TextDim" Canvas.Left="12" Canvas.Top="160" Width="200" TextAlignment="Center"/>
        </Canvas>

        <!-- 4: sparkline panel: the one card that gets the full glass treatment,
             translucent fill + a border brighter at the top than the bottom,
             like light catching the top edge of frosted glass. -->
        <Border Grid.Row="4" Background="$PanelSecondary" BorderThickness="1" CornerRadius="10" Padding="14,12,14,12">
          <Border.BorderBrush>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#40FFFFFF" Offset="0"/>
              <GradientStop Color="#0FFFFFFF" Offset="1"/>
            </LinearGradientBrush>
          </Border.BorderBrush>
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="FREE MEMORY" Style="{StaticResource EyebrowText}" Foreground="$TextSecondary"/>
              <TextBlock Grid.Column="1" Text="LAST 3 MIN" Style="{StaticResource EyebrowText}"/>
            </Grid>
            <Canvas x:Name="SparkCanvas" Height="64" Margin="0,10,0,0"/>
          </StackPanel>
        </Border>

        <!-- 6: stat row -->
        <Grid Grid.Row="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="1"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="1"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" HorizontalAlignment="Center">
            <TextBlock x:Name="FreeStat" Text="--" FontFamily="$FontMono" FontSize="19" FontWeight="SemiBold" Foreground="$TextPrimary" HorizontalAlignment="Center"/>
            <TextBlock Text="FREE GB" FontSize="9" FontWeight="SemiBold" Foreground="$TextDim" HorizontalAlignment="Center" Margin="0,3,0,0"/>
          </StackPanel>
          <Rectangle Grid.Column="1" Fill="$BorderSoft" Width="1" Margin="0,4"/>
          <StackPanel Grid.Column="2" HorizontalAlignment="Center">
            <TextBlock x:Name="UsedStat" Text="--" FontFamily="$FontMono" FontSize="19" FontWeight="SemiBold" Foreground="$TextPrimary" HorizontalAlignment="Center"/>
            <TextBlock Text="USED GB" FontSize="9" FontWeight="SemiBold" Foreground="$TextDim" HorizontalAlignment="Center" Margin="0,3,0,0"/>
          </StackPanel>
          <Rectangle Grid.Column="3" Fill="$BorderSoft" Width="1" Margin="0,4"/>
          <StackPanel Grid.Column="4" HorizontalAlignment="Center">
            <TextBlock x:Name="CacheStat" Text="--" FontFamily="$FontMono" FontSize="19" FontWeight="SemiBold" Foreground="$TextPrimary" HorizontalAlignment="Center"/>
            <TextBlock Text="CACHE GB" FontSize="9" FontWeight="SemiBold" Foreground="$TextDim" HorizontalAlignment="Center" Margin="0,3,0,0"/>
          </StackPanel>
        </Grid>

        <!-- 8: clean button -->
        <Button x:Name="CleanBtn" Grid.Row="8" Height="60" Cursor="Hand">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="Bd" Background="$Accent" CornerRadius="6">
                <ContentPresenter/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="$AccentHover"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                  <Setter TargetName="Bd" Property="Background" Value="$AccentPressed"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                  <Setter TargetName="Bd" Property="Opacity" Value="0.55"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
          <!-- Content (not the template) so these names land in the window's
               namescope and $window.FindName(...) can actually see them. -->
          <Grid Margin="18,0,18,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" VerticalAlignment="Center">
              <TextBlock x:Name="CleanBtnTitle" Text="CLEAN MEMORY" Foreground="$BG" FontWeight="Bold" FontSize="14"/>
              <TextBlock x:Name="CleanBtnSubtitle" Text="Trim working sets + purge standby list" Foreground="#5C5C5C" FontSize="10" Margin="0,2,0,0"/>
            </StackPanel>
            <TextBlock x:Name="CleanBtnIcon" Grid.Column="1" Text="→" Foreground="$BG" FontSize="18" VerticalAlignment="Center"/>
          </Grid>
        </Button>

        <!-- 10: tuning toggle -->
        <ToggleButton x:Name="TuneToggle" Grid.Row="10" Background="Transparent" BorderThickness="0" HorizontalAlignment="Left" Cursor="Hand">
          <ToggleButton.Template>
            <ControlTemplate TargetType="ToggleButton">
              <StackPanel Orientation="Horizontal">
                <ContentPresenter/>
              </StackPanel>
            </ControlTemplate>
          </ToggleButton.Template>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="TUNING" Foreground="$TextSecondary" FontSize="11" FontWeight="SemiBold"/>
            <TextBlock Text="⌄" Foreground="$TextDim" FontSize="12" Margin="6,0,0,0" RenderTransformOrigin="0.5,0.5">
              <TextBlock.RenderTransform>
                <RotateTransform x:Name="TuneChevronRotate" Angle="0"/>
              </TextBlock.RenderTransform>
            </TextBlock>
          </StackPanel>
        </ToggleButton>

        <!-- 11: tuning drawer -->
        <StackPanel x:Name="TuneDrawer" Grid.Row="11" Visibility="Collapsed" Margin="0,14,0,0">
          <CheckBox x:Name="WatchdogCheck" Content="Background watchdog enabled" Style="{StaticResource CleanCheckBox}" Margin="0,0,0,14"/>

          <TextBlock Foreground="$TextSecondary" FontSize="11" Margin="0,0,0,6">
            <Run Text="Trim when free RAM drops below "/><Run x:Name="ThresholdLabel" Text="12" Foreground="$TextPrimary" FontWeight="SemiBold"/><Run Text="%"/>
          </TextBlock>
          <Slider x:Name="ThresholdSlider" Style="{StaticResource TuneSlider}" Minimum="5" Maximum="30" Value="12" Margin="0,0,0,14"/>

          <TextBlock Foreground="$TextSecondary" FontSize="11" Margin="0,0,0,6">
            <Run Text="Check every "/><Run x:Name="IntervalLabel" Text="20" Foreground="$TextPrimary" FontWeight="SemiBold"/><Run Text=" sec"/>
          </TextBlock>
          <Slider x:Name="IntervalSlider" Style="{StaticResource TuneSlider}" Minimum="10" Maximum="60" Value="20" Margin="0,0,0,14"/>

          <CheckBox x:Name="FullscreenCheck" Content="Skip trims while a fullscreen app is focused" Style="{StaticResource CleanCheckBox}" Margin="0,0,0,16"/>

          <Button x:Name="SaveBtn" Content="SAVE SETTINGS" Style="{StaticResource TuneButton}"/>
        </StackPanel>

        <!-- 13: footer -->
        <TextBlock x:Name="StatusLine" Grid.Row="13" Text="Ready." FontFamily="$FontMono" FontSize="10" Foreground="$TextDim" TextWrapping="Wrap" VerticalAlignment="Bottom"/>
      </Grid>
      </ScrollViewer>
    </Grid>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Safety net: without a System.Windows.Application object, an exception that
# escapes any event handler (Click, Tick, ValueChanged...) would otherwise be
# unhandled on the dispatcher thread and silently kill the whole process.
# That is exactly what "the window just closes" looks like. Catch it, log
# it, keep the app alive.
$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    try {
        $detail = "$($e.Exception.GetType().FullName): $($e.Exception.Message)"
        Write-MemTrimLog "UNHANDLED UI EXCEPTION: $detail"
        $statusEl = $window.FindName('StatusLine')
        if ($statusEl) { $statusEl.Text = "Error: $($e.Exception.Message)" }
    } catch { }
    $e.Handled = $true
})

# resolve named elements
$names = @('TitleBar','MinBtn','CloseBtn','WatchdogLabel','StatusDot','StatusDotGlow',
           'HealthStateText','LiveClock',
           'GaugeGlow','GaugeTrack','GaugeValue','GaugeNumber','GaugeContext',
           'SparkCanvas','FreeStat','UsedStat','CacheStat',
           'CleanBtn','CleanBtnTitle','CleanBtnSubtitle','CleanBtnIcon',
           'TuneToggle','TuneChevronRotate','TuneDrawer',
           'WatchdogCheck','ThresholdSlider','ThresholdLabel','IntervalSlider','IntervalLabel',
           'FullscreenCheck','SaveBtn','StatusLine')
$ui = @{}
foreach ($n in $names) { $ui[$n] = $window.FindName($n) }

# gauge math
$GaugeCx = 112.0; $GaugeCy = 112.0; $GaugeR = 93.0
$Theta0 = 150.0; $ThetaSpan = 240.0   # classic speedometer opening at the bottom

function Get-ArcPoint([double]$deg) {
    $rad = $deg * [math]::PI / 180.0
    [PSCustomObject]@{ X = $GaugeCx + $GaugeR * [math]::Cos($rad); Y = $GaugeCy + $GaugeR * [math]::Sin($rad) }
}

function Set-GaugeArc($path, [double]$fromDeg, [double]$toDeg) {
    $p0 = Get-ArcPoint $fromDeg
    $p1 = Get-ArcPoint $toDeg
    $isLarge = if (($toDeg - $fromDeg) -gt 180) { 1 } else { 0 }
    $data = "M {0:0.##},{1:0.##} A {2},{2} 0 {3} 1 {4:0.##},{5:0.##}" -f $p0.X,$p0.Y,$GaugeR,$isLarge,$p1.X,$p1.Y
    $path.Data = [Windows.Media.Geometry]::Parse($data)
}

Set-GaugeArc $ui.GaugeTrack $Theta0 ($Theta0 + $ThetaSpan)

function Update-GaugeValue([double]$freePercent) {
    # Clamp defensively: GlobalMemoryStatusEx should always hand back 0-100,
    # but a degenerate arc (0 or 100) must still render without throwing.
    $pct = [math]::Max(0.0, [math]::Min(100.0, $freePercent))
    Set-GaugeArc $ui.GaugeValue $Theta0 ($Theta0 + $ThetaSpan * ($pct / 100.0))
}

# sparkline history
$Script:History = New-Object System.Collections.Generic.List[double]
$Script:MaxHistory = 90   # 90 samples * 2s refresh = 3 min, matches the panel label

function Update-Sparkline([string]$LineHex) {
    $canvas = $ui.SparkCanvas
    $canvas.Children.Clear()
    $w = 392.0; $h = 64.0
    $canvas.Width = $w

    # baseline grid: three faint reference lines so the trace reads as a
    # chart, not a bare floating line
    foreach ($frac in @(0.0, 0.5, 1.0)) {
        $y = $h * $frac
        $line = New-Object System.Windows.Shapes.Rectangle
        $line.Width = $w; $line.Height = 1
        $line.Fill = Get-Brush $(if ($frac -eq 1.0) { $BorderColor } else { $BorderSoft })
        [System.Windows.Controls.Canvas]::SetLeft($line, 0)
        [System.Windows.Controls.Canvas]::SetTop($line, $y)
        $canvas.Children.Add($line) | Out-Null
    }

    if ($Script:History.Count -lt 2) { return }

    $maxV = [double]($Script:History | Measure-Object -Maximum).Maximum
    $minV = [double]($Script:History | Measure-Object -Minimum).Minimum
    if ($maxV -eq $minV) { $maxV += 1 }   # flat history, avoid a divide by zero
    $n = $Script:History.Count

    $pts = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $n; $i++) {
        $x = $w * $i / [math]::Max(1, ($Script:MaxHistory - 1))
        $norm = ($Script:History[$i] - $minV) / ($maxV - $minV)
        $y = 4 + (($h - 8) - ($norm * ($h - 8)))
        $pts.Add((New-Object System.Windows.Point($x, $y)))
    }

    # filled area under the trace, fading to transparent, reads as an
    # intentional area chart rather than a floating line
    $areaPts = New-Object System.Windows.Media.PointCollection
    foreach ($p in $pts) { $areaPts.Add($p) }
    $areaPts.Add((New-Object System.Windows.Point($pts[$n-1].X, $h)))
    $areaPts.Add((New-Object System.Windows.Point($pts[0].X, $h)))
    $area = New-Object System.Windows.Shapes.Polygon
    $area.Points = $areaPts
    $gradient = New-Object System.Windows.Media.LinearGradientBrush
    $gradient.StartPoint = New-Object System.Windows.Point(0,0)
    $gradient.EndPoint = New-Object System.Windows.Point(0,1)
    $c1 = [Windows.Media.ColorConverter]::ConvertFromString($LineHex)
    $c1.A = 46
    $c2 = [Windows.Media.ColorConverter]::ConvertFromString($LineHex)
    $c2.A = 0
    $gradient.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c1, 0)))
    $gradient.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c2, 1)))
    $area.Fill = $gradient
    $canvas.Children.Add($area) | Out-Null

    $poly = New-Object System.Windows.Shapes.Polyline
    $poly.Points = $pts
    $poly.Stroke = Get-Brush $LineHex
    $poly.StrokeThickness = 1.8
    $poly.StrokeLineJoin = 'Round'
    $canvas.Children.Add($poly) | Out-Null
}

# slider fill
function Update-SliderFill($slider) {
    $track = $slider.Template.FindName('PART_Track', $slider)
    $fill  = $slider.Template.FindName('PART_Fill', $slider)
    if (-not $track -or -not $fill) { return }
    $width = $slider.ActualWidth
    if ($width -le 0) { return }
    $range = $slider.Maximum - $slider.Minimum
    if ($range -le 0) { return }
    $frac = ($slider.Value - $slider.Minimum) / $range
    $fill.Width = [math]::Max(0, [math]::Min($width, $width * $frac))
}

# clean button
function Set-CleanButtonState([bool]$Cleaning) {
    if ($Cleaning) {
        $ui.CleanBtnTitle.Text = 'CLEANING...'
        $ui.CleanBtnSubtitle.Text = 'Trimming working sets and purging standby'
        $ui.CleanBtnIcon.Text = '⟳'
    } else {
        $ui.CleanBtnTitle.Text = 'CLEAN MEMORY'
        $ui.CleanBtnSubtitle.Text = 'Trim working sets + purge standby list'
        $ui.CleanBtnIcon.Text = '→'
    }
}

# chevron
function Set-ChevronAngle($rotate, [double]$angle) {
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.To = $angle
    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))
    $rotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
}

# startup
$config = Get-MemTrimConfig
$ui.WatchdogCheck.IsChecked = [bool]$config.watchdogEnabled
$ui.ThresholdSlider.Value = [double]$config.thresholdPercent
$ui.IntervalSlider.Value = [double]$config.checkIntervalSec
$ui.FullscreenCheck.IsChecked = [bool]$config.skipWhenFullscreen
$ui.ThresholdLabel.Text = [string]$config.thresholdPercent
$ui.IntervalLabel.Text = [string]$config.checkIntervalSec
$ui.WatchdogLabel.Text = if ($config.watchdogEnabled) { 'WATCHDOG ON' } else { 'WATCHDOG OFF' }
$ui.StatusDot.Fill = Get-Brush $(if ($config.watchdogEnabled) { $TextPrimary } else { $TextDim })
$ui.StatusDotGlow.Color = [Windows.Media.ColorConverter]::ConvertFromString($(if ($config.watchdogEnabled) { $TextPrimary } else { $TextDim }))

function Update-Dashboard {
    $s = Get-MemTrimStatus
    $health = Get-HealthState $s.FreePercent

    $ui.GaugeNumber.Text = [string]([int][math]::Round([math]::Max(0, [math]::Min(100, $s.FreePercent))))
    $ui.GaugeContext.Text = $health.Context
    $ui.HealthStateText.Text = $health.Name
    $ui.HealthStateText.Foreground = Get-Brush $health.Hex
    $ui.GaugeValue.Stroke = Get-Brush $health.Hex
    $ui.GaugeGlow.Fill = Get-Brush $health.GlowHex
    Update-GaugeValue $s.FreePercent

    $ui.FreeStat.Text = [string]$s.FreeGB
    $ui.UsedStat.Text = [string]$s.UsedGB
    $ui.CacheStat.Text = [string]$s.StandbyGB
    $ui.LiveClock.Text = (Get-Date).ToString('HH:mm:ss')

    $Script:History.Add($s.FreePercent)
    if ($Script:History.Count -gt $Script:MaxHistory) { $Script:History.RemoveAt(0) }
    Update-Sparkline $health.Hex
}

Update-Dashboard
$window.Dispatcher.InvokeAsync({
    Update-SliderFill $ui.ThresholdSlider
    Update-SliderFill $ui.IntervalSlider
}, [Windows.Threading.DispatcherPriority]::Loaded) | Out-Null

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-Dashboard })
$timer.Start()

# interactions
$ui.TitleBar.Add_MouseLeftButtonDown({ $window.DragMove() })
$ui.MinBtn.Add_Click({ $window.WindowState = 'Minimized' })
$ui.CloseBtn.Add_Click({ $window.Close() })

$ui.TuneToggle.Add_Checked({
    $ui.TuneDrawer.Visibility = 'Visible'
    Set-ChevronAngle $ui.TuneChevronRotate 180
})
$ui.TuneToggle.Add_Unchecked({
    Set-ChevronAngle $ui.TuneChevronRotate 0
    $ui.TuneDrawer.Visibility = 'Collapsed'
})

$ui.ThresholdSlider.Add_ValueChanged({
    $ui.ThresholdLabel.Text = [string][int]$ui.ThresholdSlider.Value
    Update-SliderFill $ui.ThresholdSlider
})
$ui.IntervalSlider.Add_ValueChanged({
    $ui.IntervalLabel.Text = [string][int]$ui.IntervalSlider.Value
    Update-SliderFill $ui.IntervalSlider
})

$ui.SaveBtn.Add_Click({
    $cfg = Get-MemTrimConfig
    $cfg.watchdogEnabled = [bool]$ui.WatchdogCheck.IsChecked
    $cfg.thresholdPercent = [int]$ui.ThresholdSlider.Value
    $cfg.checkIntervalSec = [int]$ui.IntervalSlider.Value
    $cfg.skipWhenFullscreen = [bool]$ui.FullscreenCheck.IsChecked
    Save-MemTrimConfig $cfg
    $ui.WatchdogLabel.Text = if ($cfg.watchdogEnabled) { 'WATCHDOG ON' } else { 'WATCHDOG OFF' }
    $onHex = if ($cfg.watchdogEnabled) { $TextPrimary } else { $TextDim }
    $ui.StatusDot.Fill = Get-Brush $onHex
    $ui.StatusDotGlow.Color = [Windows.Media.ColorConverter]::ConvertFromString($onHex)
    $ui.StatusLine.Text = Write-MemTrimLog "Settings saved: threshold=$($cfg.thresholdPercent)% interval=$($cfg.checkIntervalSec)s watchdog=$($cfg.watchdogEnabled)"
})

$ui.CleanBtn.Add_Click({
    if (-not $ui.CleanBtn.IsEnabled) { return }   # guards against a double-fire mid-click

    $ui.CleanBtn.IsEnabled = $false
    Set-CleanButtonState $true
    # Flush the "CLEANING..." state to screen before the synchronous trim
    # work below blocks this same UI thread for its (sub-second) duration.
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)

    try {
        $trimResult = Invoke-MemTrimWorkingSets -SkipForeground -ExcludeProcesses (Get-MemTrimConfig).excludeProcesses

        $standbyMsg = ''
        if (Test-MemTrimIsAdmin) {
            $purge = Invoke-MemTrimStandbyPurge
            $standbyMsg = if ($purge.Success) { ' · standby purged' } else { " · standby purge failed ($($purge.Reason))" }
        } else {
            $standbyMsg = ' · standby purge needs admin (run shortcut as administrator)'
        }

        # DeltaGB is available-memory before/after, not a causally-attributed
        # "freed" amount, other processes can allocate or release memory in
        # the same window, so it's reported as a change, not a claim.
        $msg = 'Available {0:+0.00;-0.00;0.00} GB · {1} processes trimmed{2} · {3:HH:mm:ss}' -f $trimResult.DeltaGB, $trimResult.ProcessesTrimmed, $standbyMsg, (Get-Date)
        $ui.StatusLine.Text = (Write-MemTrimLog $msg)
    } catch {
        $ui.StatusLine.Text = (Write-MemTrimLog "Clean failed: $($_.Exception.Message)")
    } finally {
        Set-CleanButtonState $false
        $ui.CleanBtn.IsEnabled = $true
        Update-Dashboard
    }
})

$window.ShowDialog() | Out-Null
