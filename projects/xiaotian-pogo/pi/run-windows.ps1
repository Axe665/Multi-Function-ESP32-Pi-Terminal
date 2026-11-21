param([switch]$Demo,[string]$Port='',[string]$Device='',[string]$ModuleIp='',
      [string]$Panel='S:\esp\xiaotian-pogo-panel\xiaotian-panel.exe',
      [string]$Python='S:\esp\.espressif\python_env\idf5.5_py3.10_env\Scripts\python.exe')
$ErrorActionPreference='Stop'
$env:PATH="S:\Qt\6.10.1\mingw_64\bin;S:\Qt\Tools\mingw1310_64\bin;$env:PATH"
$panelArgs=@()
if($Demo){$panelArgs=@('--demo')}
else {
    $panelArgs=@('--worker',(Join-Path $PSScriptRoot 'worker.py'),'--python',$Python)
    if($Port){$panelArgs+=@('--serial',$Port)}
    elseif($Device){$panelArgs+=@('--device',$Device)}
    else{throw 'Use -Demo, -Port COMxx, or -Device private-pairing.json'}
    if($ModuleIp){$panelArgs+=@('--host',$ModuleIp)}
}
& $Panel @panelArgs
