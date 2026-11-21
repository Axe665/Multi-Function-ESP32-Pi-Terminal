param([string]$StageDirectory='S:\esp\xiaotian-pogo-panel', [string]$QtRoot='S:\Qt\6.10.1\mingw_64')
$ErrorActionPreference='Stop'
$env:PATH="S:\Qt\Tools\mingw1310_64\bin;$QtRoot\bin;S:\Qt\Tools\Ninja;$env:PATH"
& S:\Qt\Tools\CMake_64\bin\cmake.exe -S $PSScriptRoot -B $StageDirectory -G Ninja "-DCMAKE_PREFIX_PATH=$QtRoot" '-DCMAKE_BUILD_TYPE=Release' '-DCMAKE_MAKE_PROGRAM=S:/Qt/Tools/Ninja/ninja.exe'
if($LASTEXITCODE -ne 0){throw 'Panel configure failed'}
& S:\Qt\Tools\CMake_64\bin\cmake.exe --build $StageDirectory
if($LASTEXITCODE -ne 0){throw 'Panel build failed'}
Write-Output "Panel built: $StageDirectory\xiaotian-panel.exe"
