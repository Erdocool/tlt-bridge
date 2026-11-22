# The Last Telegraph - PC koprusu kurulumu
# Kullanim (PowerShell'e tek satir):
#   [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/Erdocool/tlt-bridge/main/install.ps1 | iex #
# Token'i onceden vermek icin:  $TLT_TOKEN='123:ABC...'; <ayni satir>
# Bu dosyada gizli bilgi yoktur. Token sadece %USERPROFILE%\.tlt-bridge\config.json icinde saklanir.

& {
    param([string]$Token = $TLT_TOKEN, [string]$WorkDir = $TLT_WORKDIR, [switch]$NoStart = [bool]$TLT_NOSTART)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

    $repo = 'https://raw.githubusercontent.com/Erdocool/tlt-bridge/main'
    if ($env:TLT_REPO_RAW) { $repo = $env:TLT_REPO_RAW.TrimEnd('/') }
    $base = $env:USERPROFILE; if ([string]::IsNullOrWhiteSpace($base)) { $base = $HOME }
    $dir = Join-Path $base '.tlt-bridge'
    if ($env:TLT_HOME) { $dir = $env:TLT_HOME }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Write-Host ''
    Write-Host 'The Last Telegraph koprusu kuruluyor...' -ForegroundColor Cyan

    # 1) bridge.ps1'i indir (UTF-8 BOM ile kaydet ki Windows PowerShell 5.1 Turkce karakterleri dogru okusun)
    $wc = New-Object System.Net.WebClient
    $bytes = $wc.DownloadData($repo + '/bridge.ps1?t=' + [DateTime]::UtcNow.Ticks)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $target = Join-Path $dir 'bridge.ps1'
    $fs = [System.IO.File]::Create($target)
    try {
        if (-not $hasBom) { $fs.Write([byte[]](0xEF, 0xBB, 0xBF), 0, 3) }
        $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
    Write-Host ('  Indirildi: ' + $target)

    # 2) Token'i al ve kaydet (yoksa sor)
    $cfgPath = Join-Path $dir 'config.json'
    $cfg = $null
    if (Test-Path -LiteralPath $cfgPath) { try { $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {} }
    $re = '\d{5,}:[A-Za-z0-9_-]{30,}'
    $tok = $null
    if ($Token -and ($Token -match $re)) { $tok = $Matches[0] }
    elseif ($cfg -and ([string]$cfg.Token -match $re)) { $tok = $Matches[0] }
    while (-not $tok) {
        Write-Host ''
        Write-Host 'BotFather''in verdigi bot token''ini yapistirip Enter''a basin' -ForegroundColor Yellow
        Write-Host '(ornek: 1234567890:AAH...; sag tik = yapistir):' -ForegroundColor Yellow
        $in = Read-Host 'Token'
        if ($in -match $re) { $tok = $Matches[0] } else { Write-Host 'Bu bir bot token''i gibi gorunmuyor, tekrar deneyin.' -ForegroundColor Red }
    }
    try {
        $me = Invoke-RestMethod -Uri ('https://api.telegram.org/bot' + $tok + '/getMe') -TimeoutSec 20
        Write-Host ('  Bot dogrulandi: @' + $me.result.username) -ForegroundColor Green
    } catch {
        if (-not $env:TLT_API_BASE) { Write-Host '  Uyari: token Telegram''da dogrulanamadi (internet ya da yanlis token). Yine de devam ediliyor.' -ForegroundColor Yellow }
    }
    if ($cfg) { $cfg.Token = $tok } else { $cfg = [pscustomobject]@{ Token = $tok } }
    if ($WorkDir) {
        if ($cfg.PSObject.Properties['WorkDir']) { $cfg.WorkDir = $WorkDir } else { $cfg | Add-Member -NotePropertyName WorkDir -NotePropertyValue $WorkDir }
    }
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $true))

    # 3) Cift tiklanabilir baslatici + masaustu kisayolu
    $cmdPath = Join-Path $dir 'TLT-Kopru.cmd'
    $cmd = "@echo off`r`ntitle The Last Telegraph - kopru`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""%~dp0bridge.ps1""`r`npause`r`n"
    [System.IO.File]::WriteAllText($cmdPath, $cmd, (New-Object System.Text.ASCIIEncoding))
    try {
        if ($env:OS -eq 'Windows_NT') {
            $desk = [Environment]::GetFolderPath('Desktop')
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut((Join-Path $desk 'TLT Kopru.lnk'))
            $lnk.TargetPath = $cmdPath
            $lnk.WorkingDirectory = $dir
            $lnk.Save()
            Write-Host '  Masaustune "TLT Kopru" kisayolu eklendi (sonraki seferler icin cift tiklayin).'
        }
    } catch {}

    if ($NoStart) { Write-Host 'Kurulum bitti (baslatilmadi).' -ForegroundColor Green; return }

    # 4) Kopruyu bu pencerede baslat
    Write-Host ''
    Write-Host 'Kopru baslatiliyor... Bu pencereyi acik tutun.' -ForegroundColor Cyan
    if ($env:OS -eq 'Windows_NT') {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target
    } else {
        & pwsh -NoProfile -File $target
    }
}
