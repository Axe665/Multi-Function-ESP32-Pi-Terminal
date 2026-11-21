param(
    [string]$IdfPath = 'S:\esp\esp-idf',
    [string]$ToolsPath = 'S:\esp\.espressif',
    [string]$StageDirectory = ''
)
$ErrorActionPreference = 'Stop'
if (!$StageDirectory) {
    $StageDirectory = Join-Path ([IO.Path]::GetTempPath()) ('xiaotian-io4-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
}
$stagePath = [IO.Path]::GetFullPath($StageDirectory)
if ($stagePath -match '[^\x00-\x7f]') { throw 'Build staging path must use ASCII characters.' }
New-Item -ItemType Directory -Path $stagePath -Force | Out-Null
foreach ($name in @('CMakeLists.txt', 'sdkconfig.defaults', 'partitions.csv')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $stagePath -Force
}
$stageMain = Join-Path $stagePath 'main'
New-Item -ItemType Directory -Path $stageMain -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'main') -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $stageMain -Force
}

$stageComponents = Join-Path $stagePath 'components'
New-Item -ItemType Directory -Path $stageComponents -Force | Out-Null
foreach ($component in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'components') -Directory) {
    $target = Join-Path $stageComponents $component.Name
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Get-ChildItem -LiteralPath $component.FullName | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
    }
}

$pythonEnv = Join-Path $ToolsPath 'python_env\idf5.5_py3.10_env'
$pythonExe = Join-Path $pythonEnv 'Scripts\python.exe'
$ninja = Join-Path $ToolsPath 'tools\ninja\1.12.1'
$compiler = Join-Path $ToolsPath 'tools\xtensa-esp-elf\esp-14.2.0_20260121\xtensa-esp-elf\bin'
$cmake = Join-Path $ToolsPath 'tools\cmake\3.30.2\bin'
$env:IDF_PATH = $IdfPath
$env:IDF_TOOLS_PATH = $ToolsPath
$env:IDF_PYTHON_ENV_PATH = $pythonEnv
$env:IDF_CCACHE_ENABLE = '0'
$env:IDF_COMPONENT_MANAGER = '0'
$env:PYTHONUTF8 = '1'
$env:ESP_ROM_ELF_DIR = Join-Path $ToolsPath 'tools\esp-rom-elfs\20241011'
$env:CMAKE_PROGRAM_PATH = "$ninja;$compiler"
$env:PATH = "$pythonEnv\Scripts;$cmake;$ninja;$compiler;$env:PATH"
$records = Join-Path $PSScriptRoot 'verification'
New-Item -ItemType Directory -Path $records -Force | Out-Null
Set-Content -LiteralPath (Join-Path $records 'build-stage.txt') -Value $stagePath -Encoding utf8
Push-Location -LiteralPath $stagePath
try {
    & $pythonExe (Join-Path $IdfPath 'tools\idf.py') '-DIDF_TARGET=esp32s3' "-DCMAKE_MAKE_PROGRAM=$ninja\ninja.exe" build 2>&1 |
        Tee-Object -FilePath (Join-Path $records 'build.log')
    if ($LASTEXITCODE -ne 0) { throw "Build failed: $LASTEXITCODE" }
} finally { Pop-Location }

$config = Get-Content -LiteralPath (Join-Path $stagePath 'sdkconfig') -Raw
foreach ($expected in @('CONFIG_IDF_TARGET="esp32s3"', 'CONFIG_BOOT_ROM_LOG_ALWAYS_ON=y', 'CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y')) {
    if ($config -notmatch "(?m)^$([regex]::Escape($expected))\r?$") { throw "Unexpected configuration: $expected" }
}
$artifacts = Join-Path $PSScriptRoot 'artifacts'
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
$files = @{
    'build\xiaotian_io4_probe.bin' = 'xiaotian_io4_probe.bin'
    'build\xiaotian_io4_probe.elf' = 'xiaotian_io4_probe.elf'
    'build\bootloader\bootloader.bin' = 'bootloader.bin'
    'build\partition_table\partition-table.bin' = 'partition-table.bin'
    'build\flasher_args.json' = 'flasher_args.json'
    'sdkconfig' = 'sdkconfig.verified'
}
foreach ($entry in $files.GetEnumerator()) {
    Copy-Item -LiteralPath (Join-Path $stagePath $entry.Key) -Destination (Join-Path $artifacts $entry.Value) -Force
}
$flashPath = Join-Path $artifacts 'flasher_args.json'
$flash = Get-Content -LiteralPath $flashPath -Raw | ConvertFrom-Json
foreach ($file in $flash.flash_files.PSObject.Properties) { $file.Value = Split-Path -Leaf $file.Value }
foreach ($section in @('bootloader', 'app', 'partition-table')) { $flash.$section.file = Split-Path -Leaf $flash.$section.file }
$flash | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $flashPath -Encoding utf8
Get-ChildItem -LiteralPath $artifacts -Filter '*.bin' | Get-FileHash -Algorithm SHA256 |
    Select-Object Hash, @{Name='File'; Expression={Split-Path -Leaf $_.Path}} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifacts 'sha256.json') -Encoding utf8
Write-Output "Build passed. Artifacts: $artifacts"
