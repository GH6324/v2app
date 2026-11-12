param(
  [ValidateSet('android', 'windows', 'macos', 'linux')]
  [string]$Platform = 'android',
  [string]$AppName = '99294837',
  [string]$V2BoardUrl = 'https://free.99294837.xyz',
  [string]$Tagline = '登录后自动同步订阅，简单、安全、跨平台',
  [string]$ProfileLabel = '我的订阅',
  [string]$TimeoutSeconds = $env:V2BOARD_TIMEOUT_SECONDS,
  [string]$IconPath = '',
  [switch]$Release,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root 'env.json'
$env = [ordered]@{
  APP_ENV = if ($Release) { 'stable' } else { 'pre' }
  APP_NAME = $AppName
  V2BOARD_URL = $V2BoardUrl
  APP_TAGLINE = $Tagline
  PROFILE_LABEL = $ProfileLabel
}
if ($TimeoutSeconds) { $env.V2BOARD_TIMEOUT_SECONDS = $TimeoutSeconds }
$env | ConvertTo-Json | Set-Content -Encoding UTF8 $envFile

function Replace-Pattern([string]$RelativePath, [string]$Pattern, [scriptblock]$Builder) {
  $path = Join-Path $root $RelativePath
  if (-not (Test-Path -LiteralPath $path)) { return }
  $content = Get-Content -Raw -LiteralPath $path
  $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    & $Builder $match
  }
  $updated = [regex]::Replace(
    $content,
    $Pattern,
    $evaluator,
    [System.Text.RegularExpressions.RegexOptions]::Multiline
  )
  if ($updated -ne $content) {
    Set-Content -LiteralPath $path -Value $updated -Encoding UTF8
  }
}

# Keep native store/package labels aligned with the white-label name. Executable
# and service names stay stable so existing helper/service upgrades keep working.
function Quote-YamlScalar([string]$value) {
  return "'" + $value.Replace("'", "''") + "'"
}

$xmlApp = { param($match) '<string name="app_name">' + $AppName + '</string>' }
$xmlService = { param($match) '<string name="service_channel_name">' + $AppName + ' Service</string>' }
$yamlDisplay = { param($match) 'display_name: ' + (Quote-YamlScalar $AppName) }
$yamlGeneric = { param($match) 'generic_name: ' + (Quote-YamlScalar $AppName) }
$yamlApp = { param($match) 'app_name: ' + (Quote-YamlScalar $AppName) }
$xcProduct = { param($match) 'PRODUCT_NAME = ' + $AppName }
$cppTitle = { param($match) $match.Value -replace '"[^"]*"', ('"' + $AppName + '"') }
$winTitle = { param($match) 'if (!window.Create(L"' + $AppName + '", origin, size)) {' }
$rcDescription = { param($match) 'VALUE "FileDescription", "' + $AppName + '" "\0"' }

Replace-Pattern 'android/common/src/main/res/values/strings.xml' '<string name="app_name">[^<]*</string>' $xmlApp
Replace-Pattern 'android/common/src/main/res/values/strings.xml' '<string name="service_channel_name">[^<]*</string>' $xmlService
foreach ($file in @('linux/packaging/deb/make_config.yaml', 'linux/packaging/rpm/make_config.yaml', 'linux/packaging/appimage/make_config.yaml')) {
  Replace-Pattern $file '^display_name:\s*.*\r?$' $yamlDisplay
  Replace-Pattern $file '^generic_name:\s*.*\r?$' $yamlGeneric
}
Replace-Pattern 'windows/packaging/exe/make_config.yaml' '^display_name:\s*.*\r?$' $yamlDisplay
Replace-Pattern 'windows/packaging/exe/make_config.yaml' '^app_name:\s*.*\r?$' $yamlApp
Replace-Pattern 'distribute_options.yaml' '^app_name:\s*.*\r?$' $yamlApp
Replace-Pattern 'macos/Runner/Configs/AppInfo.xcconfig' '^PRODUCT_NAME\s*=.*\r?$' $xcProduct
Replace-Pattern 'linux/runner/my_application.cc' 'gtk_header_bar_set_title\(header_bar,\s*"[^"]*"\);' $cppTitle
Replace-Pattern 'linux/runner/my_application.cc' 'gtk_window_set_title\(window,\s*"[^"]*"\);' $cppTitle
Replace-Pattern 'windows/runner/main.cpp' 'if \(!window\.Create\(L"[^"]*", origin, size\)\) \{' $winTitle
Replace-Pattern 'windows/runner/Runner.rc' 'VALUE "FileDescription", "[^"]*" "\\0"' $rcDescription

if ($IconPath) {
  $icon = (Resolve-Path -LiteralPath $IconPath).Path
  Copy-Item -LiteralPath $icon -Destination (Join-Path $root 'assets/images/icon.png') -Force
  if ((Get-Command dart -ErrorAction SilentlyContinue) -and (Get-Command rsvg-convert -ErrorAction SilentlyContinue)) {
    Push-Location $root
    try { dart run tool/generate_status_icons.dart } finally { Pop-Location }
  } else {
    Write-Warning '未找到 dart 或 rsvg-convert；Windows 托盘图标不会自动生成。'
  }
  if (Get-Command magick -ErrorAction SilentlyContinue) {
    $androidSizes = @{
      'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192
    }
    foreach ($density in $androidSizes.Keys) {
      $target = Join-Path $root "android/app/src/main/res/mipmap-$density/ic_launcher.webp"
      & magick $icon -resize "$($androidSizes[$density])x$($androidSizes[$density])" $target
      Copy-Item $target (Join-Path $root "android/app/src/main/res/mipmap-$density/ic_launcher_round.webp") -Force
    }
    $macSizes = @(16, 32, 64, 128, 256, 512, 1024)
    foreach ($size in $macSizes) {
      $target = Join-Path $root "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png"
      & magick $icon -resize "${size}x${size}" $target
    }
  } else {
    Write-Warning '未找到 ImageMagick；Android/macOS 图标需要手动生成。'
  }
}

if ($SkipBuild) { exit 0 }

Push-Location $root
try {
  $buildArgs = @('build', $Platform, '--dart-define-from-file=env.json')
  if ($Release) { $buildArgs += '--release' }
  flutter @buildArgs
} finally {
  Pop-Location
}
