# The Last Telegraph - PC kopru (bridge) / Windows PowerShell 5.1+
#
# Bu depoda hicbir gizli bilgi yoktur. Bot token'i sadece PC'de,
# %USERPROFILE%\.tlt-bridge\config.json dosyasinda durur.
#
# Iki kanal:
#  1) Telegram sohbeti: izinli sohbetlerden gelen /ps, /file, /save, /ping,
#     /job, /jobs, /kill, /cd, /help komutlari. Yanit ayni sohbete gider.
#     getUpdates'i SADECE bu kopru cagirir.
#  2) Kutu kanali (Grok'un bilgisayari): botun dile ozel "description" slotlari
#     (gelen: ia, giden: eo) + sifreli (AES-256-CBC + HMAC-SHA256, anahtar bot
#     token'indan turetilir) satir ici veya telegra.ph sayfalari. Kutu tarafi
#     getUpdates cagirmaz, boylece iki taraf birbirinin mesajini calmaz.
#
# Calistirma:  powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.tlt-bridge\bridge.ps1"

param(
    [string]$Token,
    [string]$WorkDir,
    [string]$AllowedChats
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Version = '1.1.0'

# ---------------------------------------------------------------- basics

function Get-TltHome {
    if (-not [string]::IsNullOrWhiteSpace($env:TLT_HOME)) { return $env:TLT_HOME }
    $base = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $HOME }
    return (Join-Path $base '.tlt-bridge')
}

$script:HomeDir = Get-TltHome
$script:ConfigPath = Join-Path $script:HomeDir 'config.json'
$script:ApiBase = 'https://api.telegram.org'
if (-not [string]::IsNullOrWhiteSpace($env:TLT_API_BASE)) { $script:ApiBase = $env:TLT_API_BASE.TrimEnd('/') }
$script:TelegraphBase = 'https://api.telegra.ph'
if (-not [string]::IsNullOrWhiteSpace($env:TLT_TELEGRAPH_BASE)) { $script:TelegraphBase = $env:TLT_TELEGRAPH_BASE.TrimEnd('/') }

$script:InLang = 'ia'
$script:OutLang = 'eo'
$script:MaxDesc = 512
$script:InlineMax = 180
$script:PageMax = 60000
$script:StaleSec = 180
$script:AckAfterSec = 5
$script:MsgChunk = 3900
# Default allowed chat: supergroup "Grok ve Enki The Last Telegraph" (@TheLastTelegraphGameBot is admin there).
# Until someone pairs with /pair in a private chat, every member of an allowed group may send commands;
# after pairing, only paired users are accepted in groups.
$script:DefaultChatIds = @([int64]-1003927815137)

function Write-Log([string]$Text, [string]$Color) {
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + (Hide-Secret $Text)
    if ([string]::IsNullOrWhiteSpace($Color)) { Write-Host $line } else { Write-Host $line -ForegroundColor $Color }
}

function Hide-Secret([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if (-not [string]::IsNullOrWhiteSpace($script:Token)) { return $Text.Replace($script:Token, '***') }
    return $Text
}

function Initialize-Console {
    try { $null = & chcp.com 65001 2>$null } catch {}
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [Console]::OutputEncoding = $utf8
        [Console]::InputEncoding = $utf8
        $global:OutputEncoding = $utf8
    } catch {}
    try { $Host.UI.RawUI.WindowTitle = 'The Last Telegraph - kopru' } catch {}
}

function Initialize-Net {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}
    try { Add-Type -AssemblyName System.Net.Http } catch {}
    $handler = New-Object System.Net.Http.HttpClientHandler
    $script:Http = New-Object System.Net.Http.HttpClient($handler)
    $script:Http.Timeout = [TimeSpan]::FromSeconds(300)
}

function Get-UnixNow { return [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds) }
function Get-UnixMs { return [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds) }

# ---------------------------------------------------------------- config

function Read-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Log ('config.json okunamadi: ' + $_.Exception.Message) 'Yellow'
        return $null
    }
}

function Save-Config {
    if (-not (Test-Path -LiteralPath $script:HomeDir)) { New-Item -ItemType Directory -Path $script:HomeDir -Force | Out-Null }
    $obj = [ordered]@{
        Token          = $script:Token
        WorkDir        = $script:WorkDir
        AllowedChatIds = @($script:AllowedChatIds | ForEach-Object { [int64]$_ })
        AllowedUserIds = @($script:AllowedUserIds | ForEach-Object { [int64]$_ })
        FileChatId     = $script:FileChatId
        PairCode       = $script:PairCode
        LastInSeq      = $script:LastInSeq
        LastOutSeq     = $script:LastOutSeq
        TelegraphToken = $script:TelegraphToken
        Version        = $script:Version
    }
    $json = $obj | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding $true))
}

function New-PairCode {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $bytes = New-Object byte[] 8
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $s = ''
    foreach ($b in $bytes) { $s += $chars[$b % $chars.Length] }
    return $s
}

function ConvertTo-IdList($Value) {
    $list = New-Object System.Collections.Generic.List[int64]
    if ($null -eq $Value) { return ,$list }
    foreach ($v in @($Value)) {
        foreach ($part in ([string]$v -split '[,;\s]+')) {
            $p = $part.Trim()
            if ($p -match '^-?\d+$') {
                $n = [int64]$p
                if (-not $list.Contains($n)) { [void]$list.Add($n) }
            }
        }
    }
    return ,$list
}

function Find-Token([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '\d{5,}:[A-Za-z0-9_-]{30,}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Resolve-Config {
    $cfg = Read-Config
    $tok = Find-Token $Token
    if (-not $tok) { $tok = Find-Token $env:TLT_TOKEN }
    if (-not $tok -and $cfg) { $tok = Find-Token ([string]$cfg.Token) }
    if (-not $tok) {
        Write-Host ''
        Write-Host 'Bot token''i bulunamadi.' -ForegroundColor Yellow
        Write-Host 'BotFather''in verdigi token''i yapistirip Enter''a basin:' -ForegroundColor Yellow
        $tok = Find-Token (Read-Host 'Token')
        if (-not $tok) { throw 'Gecerli bir token girilmedi (ornek bicim: 123456789:AA...).' }
    }
    $script:Token = $tok

    $wd = $WorkDir
    if ([string]::IsNullOrWhiteSpace($wd) -and $cfg) { $wd = [string]$cfg.WorkDir }
    if ([string]::IsNullOrWhiteSpace($wd)) {
        if ($env:OS -eq 'Windows_NT') { $wd = 'C:\TLT' } else { $wd = (Join-Path $HOME 'TLT') }
    }
    $script:WorkDir = $wd
    if (-not (Test-Path -LiteralPath $wd)) { New-Item -ItemType Directory -Path $wd -Force | Out-Null }

    $script:AllowedChatIds = ConvertTo-IdList $(if ($cfg) { $cfg.AllowedChatIds } else { $null })
    foreach ($id in $script:DefaultChatIds) { if (-not $script:AllowedChatIds.Contains($id)) { [void]$script:AllowedChatIds.Add($id) } }
    foreach ($id in (ConvertTo-IdList $AllowedChats)) { if (-not $script:AllowedChatIds.Contains($id)) { [void]$script:AllowedChatIds.Add($id) } }
    foreach ($id in (ConvertTo-IdList $env:TLT_CHATS)) { if (-not $script:AllowedChatIds.Contains($id)) { [void]$script:AllowedChatIds.Add($id) } }
    $script:AllowedUserIds = ConvertTo-IdList $(if ($cfg) { $cfg.AllowedUserIds } else { $null })

    $script:FileChatId = $null
    if ($cfg -and $cfg.FileChatId) { $script:FileChatId = [int64]$cfg.FileChatId }
    if (-not $script:FileChatId -and $script:DefaultChatIds.Count) { $script:FileChatId = $script:DefaultChatIds[0] }
    $script:PairCode = $null
    if ($cfg -and $cfg.PairCode) { $script:PairCode = [string]$cfg.PairCode }
    if ([string]::IsNullOrWhiteSpace($script:PairCode)) { $script:PairCode = New-PairCode }
    $script:LastInSeq = [int64]0
    if ($cfg -and $cfg.LastInSeq) { $script:LastInSeq = [int64]$cfg.LastInSeq }
    $script:LastOutSeq = [int64]0
    if ($cfg -and $cfg.LastOutSeq) { $script:LastOutSeq = [int64]$cfg.LastOutSeq }
    $script:TelegraphToken = $null
    if ($cfg -and $cfg.TelegraphToken) { $script:TelegraphToken = [string]$cfg.TelegraphToken }

    $raw = [System.Text.Encoding]::UTF8.GetBytes($script:Token)
    $script:EncKey = Get-Sha256 (Join-Bytes ([System.Text.Encoding]::UTF8.GetBytes('tlt-bridge-v1-enc|')) $raw)
    $script:MacKey = Get-Sha256 (Join-Bytes ([System.Text.Encoding]::UTF8.GetBytes('tlt-bridge-v1-mac|')) $raw)
    Save-Config
}

# ---------------------------------------------------------------- http / telegram

function Invoke-HttpRaw([string]$Method, [string]$Url, $Content) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
    if ($null -ne $Content) { $req.Content = $Content }
    $resp = $script:Http.SendAsync($req).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $resp.Dispose()
    return @{ Status = [int]$resp.StatusCode; Body = $body }
}

function ConvertTo-JsonContent($Obj) {
    $json = $Obj | ConvertTo-Json -Depth 10 -Compress
    return [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
}

function Invoke-Tg([string]$Method, $Fields, $Content) {
    $url = $script:ApiBase + '/bot' + $script:Token + '/' + $Method
    if ($null -eq $Content) {
        if ($null -eq $Fields) { $Fields = @{} }
        $Content = ConvertTo-JsonContent $Fields
    }
    $r = Invoke-HttpRaw 'POST' $url $Content
    $j = $null
    try { $j = $r.Body | ConvertFrom-Json } catch {}
    if ($null -eq $j) { throw ('Telegram ' + $Method + ' HTTP ' + $r.Status) }
    if (-not $j.ok) {
        $ex = New-Object System.Exception ('Telegram ' + $Method + ': ' + $j.error_code + ' ' + $j.description)
        $ex.Data['code'] = $j.error_code
        if ($j.parameters -and $j.parameters.retry_after) { $ex.Data['retry'] = [int]$j.parameters.retry_after }
        throw $ex
    }
    return $j.result
}

function Send-TgText([int64]$ChatId, [string]$Text, $ReplyTo) {
    if ([string]::IsNullOrEmpty($Text)) { $Text = '(bos)' }
    $f = @{ chat_id = $ChatId; text = $Text; disable_web_page_preview = $true }
    if ($ReplyTo) { $f['reply_to_message_id'] = [int64]$ReplyTo; $f['allow_sending_without_reply'] = $true }
    for ($try = 0; $try -lt 3; $try++) {
        try { return (Invoke-Tg 'sendMessage' $f $null) } catch {
            $retry = $_.Exception.Data['retry']
            if ($retry) { Start-Sleep -Seconds ([Math]::Min(30, $retry + 1)); continue }
            throw
        }
    }
}

function Send-TgDocument([int64]$ChatId, [string]$FileName, [byte[]]$Bytes, [string]$Path, [string]$Caption, $ReplyTo) {
    $mp = New-Object System.Net.Http.MultipartFormDataContent
    $mp.Add([System.Net.Http.StringContent]::new([string]$ChatId), 'chat_id')
    if (-not [string]::IsNullOrEmpty($Caption)) {
        if ($Caption.Length -gt 1000) { $Caption = $Caption.Substring(0, 1000) }
        $mp.Add([System.Net.Http.StringContent]::new($Caption, [System.Text.Encoding]::UTF8), 'caption')
    }
    if ($ReplyTo) {
        $mp.Add([System.Net.Http.StringContent]::new([string]$ReplyTo), 'reply_to_message_id')
        $mp.Add([System.Net.Http.StringContent]::new('true'), 'allow_sending_without_reply')
    }
    $stream = $null
    if ($Path) {
        $stream = [System.IO.File]::OpenRead($Path)
        $part = New-Object System.Net.Http.StreamContent($stream)
    } else {
        $part = New-Object System.Net.Http.ByteArrayContent(,$Bytes)
    }
    $part.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
    $mp.Add($part, 'document', $FileName)
    try { return (Invoke-Tg 'sendDocument' $null $mp) }
    finally { if ($stream) { $stream.Dispose() }; $mp.Dispose() }
}

function Save-TgFile([string]$FileId, [string]$Dest) {
    $info = Invoke-Tg 'getFile' @{ file_id = $FileId } $null
    if (-not $info.file_path) { throw 'Telegram dosya yolunu vermedi (20 MB ustu dosyalar bot ile indirilemez).' }
    $url = $script:ApiBase + '/file/bot' + $script:Token + '/' + $info.file_path
    $dir = Split-Path -Parent $Dest
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $resp = $script:Http.GetAsync($url).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { throw ('Dosya indirilemedi: HTTP ' + [int]$resp.StatusCode) }
    $fs = [System.IO.File]::Create($Dest)
    try { [void]($resp.Content.CopyToAsync($fs).GetAwaiter().GetResult()) } finally { $fs.Dispose(); $resp.Dispose() }
    return (Get-Item -LiteralPath $Dest).Length
}

# ---------------------------------------------------------------- crypto (box channel)

function Join-Bytes([byte[]]$A, [byte[]]$B) {
    $o = New-Object byte[] ($A.Length + $B.Length)
    [Array]::Copy($A, 0, $o, 0, $A.Length)
    [Array]::Copy($B, 0, $o, $A.Length, $B.Length)
    return ,$o
}

function Get-Sha256([byte[]]$Data) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ,($sha.ComputeHash($Data)) } finally { $sha.Dispose() }
}

function Compress-Bytes([byte[]]$Data) {
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gz.Write($Data, 0, $Data.Length); $gz.Dispose()
    return ,($ms.ToArray())
}

function Expand-Bytes([byte[]]$Data) {
    $in = New-Object System.IO.MemoryStream(,$Data)
    $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    $out = New-Object System.IO.MemoryStream
    $gz.CopyTo($out); $gz.Dispose()
    return ,($out.ToArray())
}

function ConvertTo-B64Url([byte[]]$B) { return ([Convert]::ToBase64String($B).TrimEnd('=').Replace('+', '-').Replace('/', '_')) }
function ConvertFrom-B64Url([string]$S) {
    $s = ($S -replace '\s', '').Replace('-', '+').Replace('_', '/')
    $pad = (4 - ($s.Length % 4)) % 4
    if ($pad) { $s += ('=' * $pad) }
    return ,([Convert]::FromBase64String($s))
}

function Protect-Payload($Obj) {
    $json = $Obj | ConvertTo-Json -Depth 10 -Compress
    $plain = Compress-Bytes ([System.Text.Encoding]::UTF8.GetBytes($json))
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.KeySize = 256; $aes.Key = $script:EncKey
        $aes.GenerateIV(); $iv = $aes.IV
        $enc = $aes.CreateEncryptor()
        try { $cipher = $enc.TransformFinalBlock($plain, 0, $plain.Length) } finally { $enc.Dispose() }
    } finally { $aes.Dispose() }
    $body = Join-Bytes (Join-Bytes ([byte[]](0x54, 0x4C, 0x54, 0x31)) $iv) $cipher
    $h = New-Object System.Security.Cryptography.HMACSHA256 (,$script:MacKey)
    try { $tag = $h.ComputeHash($body) } finally { $h.Dispose() }
    return (ConvertTo-B64Url (Join-Bytes $body $tag))
}

function Unprotect-Payload([string]$Blob) {
    $raw = ConvertFrom-B64Url $Blob
    if ($raw.Length -lt 68) { throw 'paket cok kisa' }
    $n = $raw.Length - 32
    $body = New-Object byte[] $n; [Array]::Copy($raw, 0, $body, 0, $n)
    $tag = New-Object byte[] 32; [Array]::Copy($raw, $n, $tag, 0, 32)
    if ($body[0] -ne 0x54 -or $body[1] -ne 0x4C -or $body[2] -ne 0x54 -or $body[3] -ne 0x31) { throw 'bilinmeyen paket' }
    $h = New-Object System.Security.Cryptography.HMACSHA256 (,$script:MacKey)
    try { $exp = $h.ComputeHash($body) } finally { $h.Dispose() }
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($exp[$i] -bxor $tag[$i]) }
    if ($diff -ne 0) { throw 'imza tutmadi' }
    $iv = New-Object byte[] 16; [Array]::Copy($body, 4, $iv, 0, 16)
    $cipher = New-Object byte[] ($body.Length - 20); [Array]::Copy($body, 20, $cipher, 0, $cipher.Length)
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.KeySize = 256; $aes.Key = $script:EncKey; $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        try { $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length) } finally { $dec.Dispose() }
    } finally { $aes.Dispose() }
    $json = [System.Text.Encoding]::UTF8.GetString((Expand-Bytes $plain))
    return ($json | ConvertFrom-Json)
}

# ---------------------------------------------------------------- telegra.ph + slots

function Invoke-Telegraph([string]$Method, $Fields) {
    $r = Invoke-HttpRaw 'POST' ($script:TelegraphBase + '/' + $Method) (ConvertTo-JsonContent $Fields)
    $j = $r.Body | ConvertFrom-Json
    if (-not $j.ok) { throw ('telegra.ph ' + $Method + ': ' + $j.error) }
    return $j.result
}

function Initialize-Telegraph {
    if (-not [string]::IsNullOrWhiteSpace($script:TelegraphToken)) { return }
    $res = Invoke-Telegraph 'createAccount' @{ short_name = 'tlt' }
    $script:TelegraphToken = [string]$res.access_token
    Save-Config
}

function Publish-Blob([string]$Blob) {
    if ($Blob.Length -le $script:InlineMax) { return ('i.' + $Blob) }
    Initialize-Telegraph
    $paths = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Blob.Length; $i += $script:PageMax) {
        $part = $Blob.Substring($i, [Math]::Min($script:PageMax, $Blob.Length - $i))
        $content = @( @{ tag = 'p'; children = @($part) } )
        $res = Invoke-Telegraph 'createPage' @{ access_token = $script:TelegraphToken; title = 'tlt'; content = $content }
        [void]$paths.Add([string]$res.path)
    }
    return ('t.' + ($paths -join ','))
}

function Read-Blob([string]$Ref) {
    if ($Ref.StartsWith('i.')) { return $Ref.Substring(2) }
    if (-not $Ref.StartsWith('t.')) { throw ('bilinmeyen referans: ' + $Ref) }
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $Ref.Substring(2).Split(',')) {
        $r = Invoke-HttpRaw 'GET' ($script:TelegraphBase + '/getPage/' + [Uri]::EscapeDataString($p) + '?return_content=true') $null
        $j = $r.Body | ConvertFrom-Json
        if (-not $j.ok) { throw ('telegra.ph getPage: ' + $j.error) }
        foreach ($node in @($j.result.content)) {
            foreach ($c in @($node.children)) { if ($c -is [string]) { [void]$sb.Append($c) } }
        }
    }
    return $sb.ToString()
}

function Read-Manifest([string]$Text) {
    $list = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return ,$list }
    $parts = $Text.Trim().Split(' ')
    if ($parts[0] -ne 'TLT1') { return ,$list }
    for ($i = 1; $i -lt $parts.Length; $i++) {
        $kv = $parts[$i].Split('=', 2)
        if ($kv.Length -eq 2 -and $kv[0] -match '^\d+$') {
            [void]$list.Add((New-Object psobject -Property @{ Seq = [int64]$kv[0]; Ref = $kv[1] }))
        }
    }
    return ,$list
}

function Format-Manifest($Entries) {
    $sorted = @($Entries | Sort-Object Seq -Descending)
    $keep = New-Object System.Collections.Generic.List[string]
    $len = 4
    foreach ($e in $sorted) {
        $s = ([string]$e.Seq) + '=' + $e.Ref
        if ($len + 1 + $s.Length -gt $script:MaxDesc) { break }
        $keep.Insert(0, $s); $len += 1 + $s.Length
    }
    return ('TLT1 ' + ($keep -join ' ')).Trim()
}

function Send-SlotReply([string]$Id, [string]$Kind, [string]$Text, $Files, $Job) {
    $seq = [Math]::Max((Get-UnixMs), $script:LastOutSeq + 1)
    if ($Text.Length -gt 400000) { $Text = $Text.Substring(0, 200000) + "`n...[kesildi]...`n" + $Text.Substring($Text.Length - 200000) }
    $fileArr = @($Files | Where-Object { $_ })
    $payload = [ordered]@{ v = 1; seq = $seq; ts = (Get-UnixNow); id = $Id; kind = $Kind; text = $Text; job = $Job; files = $fileArr; host = $env:COMPUTERNAME }
    $ref = Publish-Blob (Protect-Payload $payload)
    [void]$script:OutEntries.Add((New-Object psobject -Property @{ Seq = $seq; Ref = $ref }))
    $desc = Format-Manifest $script:OutEntries
    # drop entries that no longer fit
    $kept = Read-Manifest $desc
    $script:OutEntries = $kept
    [void](Invoke-Tg 'setMyDescription' @{ description = $desc; language_code = $script:OutLang } $null)
    $script:LastOutSeq = $seq
    Save-Config
}

# ---------------------------------------------------------------- reply contexts

function New-ChatCtx([int64]$ChatId, $MsgId) { return @{ Kind = 'chat'; ChatId = $ChatId; MsgId = $MsgId; Id = $null } }
function New-SlotCtx([string]$Id) { return @{ Kind = 'slot'; ChatId = $null; MsgId = $null; Id = $Id } }

function Send-Reply($Ctx, [string]$Text, [string]$Kind, $Docs, $Job) {
    # Docs: list of @{ Name; Path } or @{ Name; Bytes }
    if ([string]::IsNullOrEmpty($Kind)) { $Kind = 'result' }
    if ($null -eq $Text) { $Text = '' }
    try {
        if ($Ctx.Kind -eq 'chat') {
            if ($Text.Length -gt ($script:MsgChunk * 3)) {
                $preview = $Text.Substring(0, 1500) + "`n... (tamami ekteki dosyada, " + $Text.Length + ' karakter)'
                [void](Send-TgText $Ctx.ChatId $preview $Ctx.MsgId)
                [void](Send-TgDocument $Ctx.ChatId 'cikti.txt' ([System.Text.Encoding]::UTF8.GetBytes($Text)) $null '' $Ctx.MsgId)
            } elseif ($Text.Length -gt 0) {
                for ($i = 0; $i -lt $Text.Length; $i += $script:MsgChunk) {
                    [void](Send-TgText $Ctx.ChatId ($Text.Substring($i, [Math]::Min($script:MsgChunk, $Text.Length - $i))) $Ctx.MsgId)
                }
            }
            foreach ($d in @($Docs)) {
                if ($null -eq $d) { continue }
                [void](Send-TgDocument $Ctx.ChatId $d.Name $d.Bytes $d.Path $d.Name $Ctx.MsgId)
            }
        } else {
            $files = New-Object System.Collections.Generic.List[object]
            foreach ($d in @($Docs)) {
                if ($null -eq $d) { continue }
                if (-not $script:FileChatId) { $Text += "`n[dosya gonderilemedi: FileChatId yok, once bir sohbeti /pair ile eslestirin]"; continue }
                $msg = Send-TgDocument $script:FileChatId $d.Name $d.Bytes $d.Path ('Grok icin: ' + $d.Name) $null
                [void]$files.Add([ordered]@{ name = $d.Name; file_id = [string]$msg.document.file_id; size = [int64]$msg.document.file_size })
                try { [void](Invoke-Tg 'deleteMessage' @{ chat_id = $script:FileChatId; message_id = $msg.message_id } $null) } catch {}
            }
            Send-SlotReply $Ctx.Id $Kind $Text $files.ToArray() $Job
        }
    } catch {
        Write-Log ('Yanit gonderilemedi: ' + $_.Exception.Message) 'Red'
    }
}

# ---------------------------------------------------------------- jobs

$script:JobBlock = {
    param($Code, $Dir)
    $ProgressPreference = 'SilentlyContinue'
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
    $OutputEncoding = New-Object System.Text.UTF8Encoding $false
    if ($Dir -and (Test-Path -LiteralPath $Dir)) { Set-Location -LiteralPath $Dir }
    $global:LASTEXITCODE = $null
    try {
        & ([scriptblock]::Create($Code)) *>&1 | Out-String -Stream -Width 250
    } catch {
        'HATA: ' + $_.Exception.Message
        if ($_.InvocationInfo) { $_.InvocationInfo.PositionMessage }
    }
    if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) { '[exit kodu: ' + $global:LASTEXITCODE + ']' }
}

$script:Jobs = [ordered]@{}
$script:NextJobId = 1

function Start-TltJob($Ctx, [string]$Code) {
    $id = $script:NextJobId; $script:NextJobId++
    $job = Start-Job -ScriptBlock $script:JobBlock -ArgumentList $Code, $script:WorkDir
    $script:Jobs[[string]$id] = @{ Id = $id; Job = $job; Ctx = $Ctx; Code = $Code; Started = Get-Date; AckSent = $false; Done = $false; Output = $null; State = 'Running'; Secs = 0 }
    $short = $Code; if ($short.Length -gt 80) { $short = $short.Substring(0, 80) + '...' }
    Write-Log ('Is #' + $id + ' basladi: ' + ($short -replace '\s+', ' ')) 'Cyan'
    # Trim history
    $doneIds = @($script:Jobs.Keys | Where-Object { $script:Jobs[$_].Done })
    if ($doneIds.Count -gt 40) { foreach ($k in ($doneIds | Select-Object -First ($doneIds.Count - 40))) { $script:Jobs.Remove($k) } }
}

function Get-JobText($Entry) {
    if ($Entry.Done) { return $Entry.Output }
    $lines = @(Receive-Job -Job $Entry.Job -Keep -ErrorAction SilentlyContinue 2>&1 | ForEach-Object { [string]$_ })
    return ($lines -join "`n")
}

function Get-Tail([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    return ('...' + $Text.Substring($Text.Length - $Max))
}

function Update-Jobs {
    foreach ($key in @($script:Jobs.Keys)) {
        $e = $script:Jobs[$key]
        if ($e.Done) { continue }
        $state = [string]$e.Job.State
        $secs = [int]((Get-Date) - $e.Started).TotalSeconds
        if ($state -in @('Completed', 'Failed', 'Stopped')) {
            $lines = @(Receive-Job -Job $e.Job -ErrorAction SilentlyContinue 2>&1 | ForEach-Object { [string]$_ })
            $out = ($lines -join "`n").TrimEnd().TrimStart([char[]]"`r`n")
            if ($state -eq 'Failed' -and $e.Job.ChildJobs.Count -gt 0 -and $e.Job.ChildJobs[0].JobStateInfo.Reason) {
                $out += "`nHATA: " + $e.Job.ChildJobs[0].JobStateInfo.Reason.Message
            }
            Remove-Job -Job $e.Job -Force -ErrorAction SilentlyContinue
            $e.Done = $true; $e.Output = $out; $e.State = $state; $e.Secs = $secs; $e.Job = $null
            $icon = '[OK]'; if ($state -ne 'Completed' -or $out -match '(?m)^HATA: ' -or $out -match '\[exit kodu: ') { $icon = '[!]' }
            if ($state -eq 'Stopped') { $icon = '[durduruldu]' }
            $body = $out; if ([string]::IsNullOrWhiteSpace($body)) { $body = '(cikti yok)' }
            Write-Log ('Is #' + $e.Id + ' bitti (' + $state + ', ' + $secs + ' sn)') 'Green'
            Send-Reply $e.Ctx ($icon + ' Is #' + $e.Id + ' (' + $secs + ' sn)' + "`n" + $body) 'result' $null $e.Id
        } elseif (-not $e.AckSent -and $secs -ge $script:AckAfterSec) {
            $e.AckSent = $true
            Send-Reply $e.Ctx ('Is #' + $e.Id + ' suruyor... Bitince sonuc otomatik gelecek. Ara cikti: /job ' + $e.Id + '  Durdur: /kill ' + $e.Id) 'ack' $null $e.Id
        }
    }
}

# ---------------------------------------------------------------- commands

function Resolve-PcPath([string]$P) {
    $p = $P.Trim().Trim('"').Trim("'")
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p.StartsWith('~')) { $p = $HOME + $p.Substring(1) }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $script:WorkDir $p }
    return [IO.Path]::GetFullPath($p)
}

function Get-HelpText {
    return @"
The Last Telegraph koprusu v$($script:Version) - komutlar:
/ping - bilgisayar adi ve saat
/ps <kod> - PowerShell calistirir (ayri is olarak; yeni satirdan cok satirli kod da olur)
/job <no> - isin durumu ve ara ciktisi
/jobs - son isler
/kill <no> - isi durdurur
/file <yol> - PC'deki dosyayi (klasorse zip) buraya gonderir
/save <yol> - bu aciklamayla gonderilen dosyayi PC'de <yol>'a kaydeder
/cd <yol> - varsayilan calisma klasorunu degistirir (simdi: $($script:WorkDir))
"@
}

function Invoke-Command2($Ctx, [string]$Text, $Files) {
    $t = ([string]$Text).TrimStart()
    $m = [regex]::Match($t, '^/([A-Za-z_]+)(?:@([A-Za-z0-9_]+))?(?:[ \t]+|\r?\n|$)')
    if (-not $m.Success) { return }
    if ($m.Groups[2].Success -and $script:BotUser -and ($m.Groups[2].Value -ne $script:BotUser)) { return }
    $cmd = $m.Groups[1].Value.ToLowerInvariant()
    $rest = $t.Substring($m.Length).Trim()
    switch ($cmd) {
        'ping' {
            $txt = 'pong | ' + $env:COMPUTERNAME + ' | ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' (' + [TimeZoneInfo]::Local.Id + ') | v' + $script:Version +
                "`nKlasor: " + $script:WorkDir + ' | aktif is: ' + @($script:Jobs.Values | Where-Object { -not $_.Done }).Count +
                ' | PowerShell ' + $PSVersionTable.PSVersion.ToString() + ' | FileChatId: ' + $script:FileChatId
            Send-Reply $Ctx $txt 'result' $null $null
        }
        { $_ -in @('help', 'start') } { Send-Reply $Ctx (Get-HelpText) 'result' $null $null }
        'ps' {
            if ([string]::IsNullOrWhiteSpace($rest)) { Send-Reply $Ctx 'Kullanim: /ps <PowerShell kodu>' 'result' $null $null; return }
            Start-TltJob $Ctx $rest
        }
        'job' {
            $e = $script:Jobs[$rest]
            if (-not $e) { Send-Reply $Ctx ('Is bulunamadi: ' + $rest) 'result' $null $null; return }
            $txt = Get-JobText $e
            if ([string]::IsNullOrWhiteSpace($txt)) { $txt = '(henuz cikti yok)' }
            $st = $e.State; if (-not $e.Done) { $st = [string]$e.Job.State + ', ' + [int]((Get-Date) - $e.Started).TotalSeconds + ' sn' }
            Send-Reply $Ctx ('Is #' + $e.Id + ' [' + $st + "]`n" + (Get-Tail $txt 11000)) 'result' $null $e.Id
        }
        'jobs' {
            $lines = foreach ($e in $script:Jobs.Values) {
                $st = $e.State; if (-not $e.Done) { $st = [string]$e.Job.State }
                $c = ($e.Code -replace '\s+', ' '); if ($c.Length -gt 60) { $c = $c.Substring(0, 60) + '...' }
                '#' + $e.Id + ' [' + $st + '] ' + $c
            }
            $txt = (@($lines) -join "`n"); if (-not $txt) { $txt = 'Hic is yok.' }
            Send-Reply $Ctx $txt 'result' $null $null
        }
        'kill' {
            $e = $script:Jobs[$rest]
            if (-not $e -or $e.Done) { Send-Reply $Ctx ('Calisan is bulunamadi: ' + $rest) 'result' $null $null; return }
            Stop-Job -Job $e.Job -ErrorAction SilentlyContinue
            Write-Log ('Is #' + $e.Id + ' durduruldu') 'Yellow'
        }
        'cd' {
            if ([string]::IsNullOrWhiteSpace($rest)) { Send-Reply $Ctx ('Klasor: ' + $script:WorkDir) 'result' $null $null; return }
            $p = Resolve-PcPath $rest
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
            $script:WorkDir = $p; Save-Config
            Send-Reply $Ctx ('Yeni calisma klasoru: ' + $p) 'result' $null $null
        }
        'file' {
            if ([string]::IsNullOrWhiteSpace($rest)) { Send-Reply $Ctx 'Kullanim: /file <yol>' 'result' $null $null; return }
            $p = Resolve-PcPath $rest
            if (-not (Test-Path -LiteralPath $p)) { Send-Reply $Ctx ('Bulunamadi: ' + $p) 'result' $null $null; return }
            $send = $p; $name = Split-Path -Leaf $p
            if (Test-Path -LiteralPath $p -PathType Container) {
                $send = Join-Path ([IO.Path]::GetTempPath()) ($name + '_' + (Get-Date -Format 'HHmmss') + '.zip')
                Compress-Archive -Path (Join-Path $p '*') -DestinationPath $send -Force
                $name = Split-Path -Leaf $send
            }
            $size = (Get-Item -LiteralPath $send).Length
            if ($size -gt 50MB) { Send-Reply $Ctx ('Dosya cok buyuk (' + [Math]::Round($size / 1MB, 1) + ' MB). Telegram botlari en fazla 50 MB gonderebilir.') 'result' $null $null; return }
            Write-Log ('Dosya gonderiliyor: ' + $send) 'Cyan'
            Send-Reply $Ctx '' 'result' @(@{ Name = $name; Path = $send }) $null
        }
        'save' {
            $f = @($Files | Where-Object { $_ })
            if ($f.Count -eq 0) { Send-Reply $Ctx 'Dosya yok. /save <yol> yazisini bir DOSYANIN aciklamasina (caption) yazin.' 'result' $null $null; return }
            $results = foreach ($one in $f) {
                $target = $rest
                if ([string]::IsNullOrWhiteSpace($target)) { $target = $one.name }
                $p = Resolve-PcPath $target
                if ((Test-Path -LiteralPath $p -PathType Container) -or $target.EndsWith('\') -or $target.EndsWith('/')) { $p = Join-Path $p ([string]$one.name) }
                try {
                    $n = Save-TgFile ([string]$one.file_id) $p
                    Write-Log ('Kaydedildi: ' + $p + ' (' + $n + ' bayt)') 'Green'
                    'Kaydedildi: ' + $p + ' (' + $n + ' bayt)'
                } catch { 'Kaydedilemedi: ' + $p + ' - ' + $_.Exception.Message }
            }
            Send-Reply $Ctx (@($results) -join "`n") 'result' $null $null
        }
        default { Send-Reply $Ctx ('Bilinmeyen komut: /' + $cmd + '. /help yazin.') 'result' $null $null }
    }
}

# ---------------------------------------------------------------- telegram updates

$script:Offset = 0
$script:BadPair = @{}

function Test-Allowed($Msg) {
    $chat = [int64]$Msg.chat.id
    if (-not $script:AllowedChatIds.Contains($chat)) { return $false }
    if ($Msg.chat.type -eq 'private') { return $true }
    if ($script:AllowedUserIds.Count -eq 0) { return $true }
    if ($Msg.from -and $script:AllowedUserIds.Contains([int64]$Msg.from.id)) { return $true }
    return $false
}

function Get-MsgFiles($Msg) {
    $list = New-Object System.Collections.Generic.List[object]
    if ($Msg.document) {
        $name = [string]$Msg.document.file_name; if (-not $name) { $name = 'dosya.bin' }
        [void]$list.Add(@{ name = $name; file_id = [string]$Msg.document.file_id })
    }
    return ,$list
}

function Invoke-Update($U) {
    $msg = $U.message
    if ($null -eq $msg) { $msg = $U.edited_message; if ($msg) { return } }
    if ($null -eq $msg -or $null -eq $msg.chat) { return }
    $text = [string]$msg.text
    if ([string]::IsNullOrEmpty($text)) { $text = [string]$msg.caption }
    $chatId = [int64]$msg.chat.id
    $who = ''; if ($msg.from) { $who = ([string]$msg.from.first_name + ' @' + [string]$msg.from.username + ' id=' + $msg.from.id) }
    $title = [string]$msg.chat.title; if (-not $title) { $title = '(ozel sohbet)' }

    if (-not (Test-Allowed $msg)) {
        Write-Log ('Izinsiz sohbetten mesaj: chat_id=' + $chatId + ' tur=' + $msg.chat.type + ' baslik=' + $title + ' gonderen=' + $who) 'DarkYellow'
        $pm = [regex]::Match($text.Trim(), '^/pair(?:@[A-Za-z0-9_]+)?\s+(\S+)')
        if ($pm.Success) {
            $k = [string]$chatId
            if (($script:BadPair[$k] -as [int]) -ge 5) { return }
            if ($pm.Groups[1].Value.Trim().ToUpperInvariant() -eq $script:PairCode) {
                if (-not $script:AllowedChatIds.Contains($chatId)) { [void]$script:AllowedChatIds.Add($chatId) }
                if ($msg.from -and -not $script:AllowedUserIds.Contains([int64]$msg.from.id)) { [void]$script:AllowedUserIds.Add([int64]$msg.from.id) }
                if (-not $script:FileChatId -or $msg.chat.type -eq 'private') { $script:FileChatId = $chatId }
                Save-Config
                Write-Log ('Eslesti: ' + $title + ' (chat_id=' + $chatId + ')') 'Green'
                Send-Reply (New-ChatCtx $chatId $msg.message_id) ("Eslesti. Bu sohbet artik The Last Telegraph koprusunu kullanabilir.`n" + (Get-HelpText)) 'result' $null $null
            } else {
                $script:BadPair[$k] = ($script:BadPair[$k] -as [int]) + 1
                Send-Reply (New-ChatCtx $chatId $msg.message_id) 'Kod yanlis.' 'result' $null $null
            }
        } elseif ($script:AllowedChatIds.Count -eq 0 -and $text.StartsWith('/')) {
            Send-Reply (New-ChatCtx $chatId $msg.message_id) ('Bu sohbetin id''si: ' + $chatId + '. Eslestirmek icin PC ekranindaki kodla yazin: /pair KOD') 'result' $null $null
        }
        return
    }
    if (-not $text.StartsWith('/')) { return }
    $short = $text; if ($short.Length -gt 100) { $short = $short.Substring(0, 100) + '...' }
    Write-Log ('[' + $title + '] ' + ($short -replace '\s+', ' ')) 'White'
    try {
        Invoke-Command2 (New-ChatCtx $chatId $msg.message_id) $text (Get-MsgFiles $msg)
    } catch {
        Write-Log ('Komut hatasi: ' + $_.Exception.Message) 'Red'
        Send-Reply (New-ChatCtx $chatId $msg.message_id) ('Hata: ' + (Hide-Secret $_.Exception.Message)) 'result' $null $null
    }
}

function Receive-Updates([int]$Timeout) {
    $f = @{ offset = $script:Offset; timeout = $Timeout; allowed_updates = @('message') }
    $updates = @(Invoke-Tg 'getUpdates' $f $null)
    foreach ($u in $updates) {
        $script:Offset = [int64]$u.update_id + 1
        try { Invoke-Update $u } catch { Write-Log ('Mesaj islenemedi: ' + $_.Exception.Message) 'Red' }
    }
}

# ---------------------------------------------------------------- box channel

$script:SlotFails = @{}

function Receive-Slot {
    $res = Invoke-Tg 'getMyDescription' @{ language_code = $script:InLang } $null
    $entries = @((Read-Manifest ([string]$res.description)) | Sort-Object Seq)
    foreach ($e in $entries) {
        if ($e.Seq -le $script:LastInSeq) { continue }
        try {
            $p = Unprotect-Payload (Read-Blob $e.Ref)
        } catch {
            $k = [string]$e.Seq
            $script:SlotFails[$k] = ($script:SlotFails[$k] -as [int]) + 1
            Write-Log ('Kutu paketi okunamadi (seq ' + $e.Seq + '): ' + $_.Exception.Message) 'Yellow'
            if ($script:SlotFails[$k] -ge 3) { $script:LastInSeq = $e.Seq; Save-Config }
            return
        }
        $script:LastInSeq = $e.Seq; Save-Config
        if (((Get-UnixNow) - [int64]$p.ts) -gt $script:StaleSec) {
            Write-Log ('Eski kutu komutu atlandi (seq ' + $e.Seq + ')') 'DarkGray'
            continue
        }
        $text = [string]$p.text
        $short = $text; if ($short.Length -gt 100) { $short = $short.Substring(0, 100) + '...' }
        Write-Log ('[Grok] ' + ($short -replace '\s+', ' ')) 'Magenta'
        $ctx = New-SlotCtx ([string]$p.id)
        try {
            Invoke-Command2 $ctx $text @($p.files)
        } catch {
            Write-Log ('Komut hatasi: ' + $_.Exception.Message) 'Red'
            Send-Reply $ctx ('Hata: ' + (Hide-Secret $_.Exception.Message)) 'result' $null $null
        }
    }
}

# ---------------------------------------------------------------- heartbeat / single instance (watchdog.ps1 reads these)

$script:HeartbeatPath = Join-Path $script:HomeDir 'heartbeat.txt'
$script:PidPath = Join-Path $script:HomeDir 'bridge.pid'

function Write-Heartbeat([int64]$Loop) {
    # "<unix seconds> <pid> <loop>" - rewritten every poll loop; the watchdog restarts the bridge when it gets old
    try { [System.IO.File]::WriteAllText($script:HeartbeatPath, ('' + (Get-UnixNow) + ' ' + $PID + ' ' + $Loop)) } catch {}
}

function Test-OtherBridge {
    # another live bridge with a fresh heartbeat -> do not start a second one (Telegram would answer 409)
    try {
        if (-not (Test-Path -LiteralPath $script:PidPath) -or -not (Test-Path -LiteralPath $script:HeartbeatPath)) { return $false }
        $other = [int]([System.IO.File]::ReadAllText($script:PidPath).Trim())
        if ($other -eq $PID) { return $false }
        $p = Get-Process -Id $other -ErrorAction SilentlyContinue
        if (-not $p) { return $false }
        $hb = ([System.IO.File]::ReadAllText($script:HeartbeatPath).Trim() -split ' ')
        return (((Get-UnixNow) - [int64]$hb[0]) -lt 120 -and [int]$hb[1] -eq $other)
    } catch { return $false }
}

function Set-StayAwake {
    # keep Windows from going to sleep while the bridge runs (the screen may still turn off); no admin, no setting changed.
    # Ends by itself when the bridge closes. TLT_ALLOW_SLEEP=1 turns it off.
    if ($env:TLT_ALLOW_SLEEP -eq '1' -or $env:OS -ne 'Windows_NT') { return }
    try {
        if (-not ('TLT.Power' -as [type])) { Add-Type -Namespace TLT -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' }
        [void][TLT.Power]::SetThreadExecutionState([uint32]2147483649)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        Write-Log 'Uyku engellendi: kopru acikken bilgisayar uyumaz (ekran kapanabilir).' 'DarkGray'
    } catch { Write-Log ('Uyku engellenemedi: ' + $_.Exception.Message) 'Yellow' }
}

function Send-StartNotice {
    # a short line in the group whenever the bridge (re)starts, so a restart is visible from the chat
    $why = 'elle'
    if (-not [string]::IsNullOrWhiteSpace($env:TLT_START_REASON)) { $why = $env:TLT_START_REASON }
    $chat = $script:FileChatId
    if (-not $chat -and $script:DefaultChatIds.Count) { $chat = $script:DefaultChatIds[0] }
    if (-not $chat) { return }
    $text = 'TLT koprusu basladi (v' + $script:Version + ') | ' + $env:COMPUTERNAME + ' | ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | sebep: ' + $why
    $note = 'grup mesaji gonderildi'
    try { [void](Send-TgText ([int64]$chat) $text $null) } catch { $note = 'grup mesaji GONDERILEMEDI: ' + (Hide-Secret $_.Exception.Message); Write-Log ('Baslangic mesaji gonderilemedi: ' + $_.Exception.Message) 'Yellow' }
    try { if (Test-Path -LiteralPath 'C:\TLT') { Add-Content -LiteralPath 'C:\TLT\bridge_watchdog.log' -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  kopru v' + $script:Version + ' basladi (pid ' + $PID + ', sebep: ' + $why + '), ' + $note) -Encoding UTF8 } } catch {}
}

# ---------------------------------------------------------------- main

function Show-Banner {
    Write-Host ''
    Write-Host '==============================================' -ForegroundColor DarkCyan
    Write-Host '  THE LAST TELEGRAPH - PC koprusu v' -NoNewline -ForegroundColor Cyan; Write-Host $script:Version -ForegroundColor Cyan
    Write-Host '==============================================' -ForegroundColor DarkCyan
    Write-Host ('  Bot:           @' + $script:BotUser)
    Write-Host ('  Bilgisayar:    ' + $env:COMPUTERNAME)
    Write-Host ('  Calisma klas.: ' + $script:WorkDir)
    Write-Host ('  Izinli sohbet: ' + $(if ($script:AllowedChatIds.Count) { ($script:AllowedChatIds -join ', ') } else { '(henuz yok)' }))
    Write-Host ''
    Write-Host '  Eslestirme kodu: ' -NoNewline; Write-Host $script:PairCode -ForegroundColor Yellow
    Write-Host ('  Telegram''da @' + $script:BotUser + ' botuna OZELDEN bir kez yazin:  /pair ' + $script:PairCode) -ForegroundColor Yellow
    Write-Host '  (Grup "Grok ve Enki The Last Telegraph" zaten izinli.)' -ForegroundColor DarkGray
    Write-Host '  Bu pencereyi acik tutun. Kapatmak icin Ctrl+C.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('Dinleniyor... (The Last Telegraph k' + [char]0x00F6 + 'pr' + [char]0x00FC + 's' + [char]0x00FC + ')') -ForegroundColor Green
}

function Start-Bridge {
    Initialize-Console
    if (-not (Test-Path -LiteralPath $script:HomeDir)) { New-Item -ItemType Directory -Path $script:HomeDir -Force | Out-Null }
    if ((Test-OtherBridge) -and $env:TLT_FORCE -ne '1') {
        Write-Host 'Kopru zaten calisiyor (baska bir pencerede ya da arka planda). Bu pencere kapanabilir.' -ForegroundColor Yellow
        return
    }
    [System.IO.File]::WriteAllText($script:PidPath, [string]$PID)
    Write-Heartbeat 0
    Set-StayAwake
    Initialize-Net
    Resolve-Config
    try {
        $me = Invoke-Tg 'getMe' $null $null
        $script:BotUser = [string]$me.username
    } catch {
        Write-Host ('Bot''a baglanilamadi: ' + (Hide-Secret $_.Exception.Message)) -ForegroundColor Red
        Write-Host 'Token yanlis olabilir. config.json''u silip tekrar kurun.' -ForegroundColor Red
        throw
    }
    try { [void](Invoke-Tg 'deleteWebhook' @{ drop_pending_updates = $false } $null) } catch {}
    # skip the backlog: only messages that arrive from now on are processed
    try {
        $last = @(Invoke-Tg 'getUpdates' @{ offset = -1; timeout = 0 } $null)
        if ($last.Count -gt 0) { $script:Offset = [int64]$last[-1].update_id + 1 }
    } catch {}
    try {
        $cur = Invoke-Tg 'getMyDescription' @{ language_code = $script:OutLang } $null
        $script:OutEntries = Read-Manifest ([string]$cur.description)
    } catch { $script:OutEntries = New-Object System.Collections.Generic.List[object] }
    if ($script:LastInSeq -eq 0) {
        # fresh install: ignore whatever is already queued in the box slot
        try {
            $q = Invoke-Tg 'getMyDescription' @{ language_code = $script:InLang } $null
            foreach ($e in (Read-Manifest ([string]$q.description))) { if ($e.Seq -gt $script:LastInSeq) { $script:LastInSeq = $e.Seq } }
            Save-Config
        } catch {}
    }
    Show-Banner
    Send-StartNotice

    $poll = 2
    if ($env:TLT_POLL) { $poll = [int]$env:TLT_POLL }
    $backoff = 0
    $maxLoops = 0; if ($env:TLT_MAX_LOOPS) { $maxLoops = [int]$env:TLT_MAX_LOOPS }
    $loops = 0
    while ($true) {
        $loops++
        Write-Heartbeat $loops
        if ($maxLoops -gt 0 -and $loops -gt $maxLoops) { break }
        $okLoop = $true
        try { Receive-Updates $poll } catch {
            $okLoop = $false
            $code = $_.Exception.Data['code']
            if ($code -eq 409) { Write-Log 'Baska bir kopru ayni botu dinliyor (409). Diger pencereyi kapatin.' 'Red' }
            elseif ($code -eq 401) { Write-Log 'Token gecersiz (401). config.json''u silip yeniden kurun.' 'Red' }
            else { Write-Log ('Baglanti hatasi: ' + $_.Exception.Message) 'Yellow' }
        }
        try { Receive-Slot } catch { $okLoop = $false; Write-Log ('Kutu kanali hatasi: ' + $_.Exception.Message) 'Yellow' }
        try { Update-Jobs } catch { Write-Log ('Is kontrol hatasi: ' + $_.Exception.Message) 'Yellow' }
        if ($okLoop) { $backoff = 0 } else {
            $backoff = [Math]::Min(30, [Math]::Max(2, $backoff * 2))
            Start-Sleep -Seconds $backoff
        }
    }
}

if ($env:TLT_NO_AUTOSTART -ne '1') { Start-Bridge }
