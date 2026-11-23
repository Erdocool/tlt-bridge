# The Last Telegraph - kopru bekcisi (watchdog) / Windows PowerShell 5.1+
#
# Her 5 dakikada bir (ve oturum acilisinda) Gorev Zamanlayici calistirir:
#   - bridge.pid'deki islem yasiyor mu ve heartbeat.txt taze mi (< 5 dk)?
#   - degilse: eski kopru islemlerini kapatir, kopruyu yeniden baslatir.
#   - her kontrol C:\TLT\bridge_watchdog.log dosyasina yazilir.
# Yonetici (UAC) gerekmez: gorev sadece bu kullanici icin, normal yetkiyle kurulur.
#
# Kurulum:  powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.tlt-bridge\watchdog.ps1" -Install
# Kaldirma: ... watchdog.ps1 -Uninstall
param([switch]$Install, [switch]$Uninstall, [switch]$Force, [int]$StaleSec = 300)

$ErrorActionPreference = 'Continue'
$TaskName = 'TLT Kopru Bekcisi'
$dir = $env:TLT_HOME; if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path $env:USERPROFILE '.tlt-bridge' }
$bridge = Join-Path $dir 'bridge.ps1'
$pidFile = Join-Path $dir 'bridge.pid'
$hbFile = Join-Path $dir 'heartbeat.txt'
$logDir = 'C:\TLT'; if (-not (Test-Path -LiteralPath $logDir)) { $logDir = $dir }
$log = Join-Path $logDir 'bridge_watchdog.log'

function Log([string]$t) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $t
    try {
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) { Move-Item -Force -LiteralPath $log -Destination ($log + '.old') }
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    } catch {}
}
function UnixNow { [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds) }

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Log 'gorev kaldirildi'; 'removed'; return
}

if ($Install) {
    $vbs = Join-Path $dir 'watchdog.vbs'   # runs this script with no window at all (no flashing console every 5 min)
    $vbsText = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + (Join-Path $dir 'watchdog.ps1') + '""", 0, False'
    [System.IO.File]::WriteAllText($vbs, $vbsText, (New-Object System.Text.ASCIIEncoding))
    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "' + $vbs + '"') -WorkingDirectory $dir
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $t2 = New-ScheduledTaskTrigger -AtLogOn -User $user
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger @($t1, $t2) -Settings $set -Principal $pr -Description 'The Last Telegraph koprusu: takilirsa ya da kapanirsa yeniden baslatir' -Force | Out-Null
    $tk = Get-ScheduledTask -TaskName $TaskName
    Log ('gorev kuruldu: ' + $tk.TaskName + ' (' + $tk.State + ') kullanici ' + $user)
    'installed: ' + $tk.TaskName + ' state=' + $tk.State + ' triggers=' + $tk.Triggers.Count
    return
}

# ---------------------------------------------------------------- check
$bridgePid = 0; try { $bridgePid = [int]([System.IO.File]::ReadAllText($pidFile).Trim()) } catch {}
$proc = if ($bridgePid) { Get-Process -Id $bridgePid -ErrorAction SilentlyContinue } else { $null }
$age = 99999; $hbPid = 0
try { $hb = ([System.IO.File]::ReadAllText($hbFile).Trim() -split ' '); $age = (UnixNow) - [int64]$hb[0]; $hbPid = [int]$hb[1] } catch {}
# every powershell running bridge.ps1 (old windows started by hand included)
$all = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match 'tlt-bridge\\bridge\.ps1' })

$healthy = $proc -and ($age -lt $StaleSec) -and ($hbPid -eq $bridgePid) -and -not $Force
if ($healthy) {
    # extra bridges besides the live one would steal updates (409): close them
    foreach ($p in $all) { if ($p.ProcessId -ne $bridgePid) { Log ('fazladan kopru kapatildi pid ' + $p.ProcessId); Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }
    $last = $null; try { $last = (Get-Content -LiteralPath $log -Tail 1 -ErrorAction Stop) } catch {}
    if (-not $last -or $last -notmatch 'saglam' -or ((Get-Date).Minute -lt 5)) { Log ('saglam: pid ' + $bridgePid + ', heartbeat ' + $age + ' sn once') }   # ~1 line per hour while healthy
    return
}

$why = if (-not $bridgePid) { 'pid dosyasi yok' } elseif (-not $proc) { 'kopru islemi yok (pid ' + $bridgePid + ')' } elseif ($hbPid -ne $bridgePid) { 'heartbeat baska isleme ait' } elseif ($Force) { 'elle yeniden baslatma' } else { 'heartbeat eski (' + $age + ' sn)' }
Log ('SORUN: ' + $why + ' -> yeniden baslatiliyor')
foreach ($p in $all) {
    Log ('  eski kopru kapatiliyor pid ' + $p.ProcessId)
    # the cmd window that started it (TLT-Kopru.cmd ends with "pause") goes too
    try { $par = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.ParentProcessId) -ErrorAction SilentlyContinue; if ($par -and $par.Name -eq 'cmd.exe' -and $par.CommandLine -match 'TLT-Kopru') { Stop-Process -Id $par.ProcessId -Force -ErrorAction SilentlyContinue } } catch {}
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($proc -and -not ($all | Where-Object { $_.ProcessId -eq $bridgePid })) { Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3
Remove-Item -LiteralPath $pidFile, $hbFile -ErrorAction SilentlyContinue
$env:TLT_START_REASON = 'bekci (' + $why + ')'
$np = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $bridge + '"')) -WindowStyle Minimized -WorkingDirectory $dir -PassThru
Start-Sleep -Seconds 25
$ok = $false; try { $hb = ([System.IO.File]::ReadAllText($hbFile).Trim() -split ' '); $ok = ([int]$hb[1] -eq $np.Id) -and ((UnixNow) - [int64]$hb[0] -lt 60) } catch {}
Log ('  yeni kopru pid ' + $np.Id + ': ' + $(if ($ok) { 'calisiyor (heartbeat geldi)' } else { 'heartbeat henuz yok' }))
