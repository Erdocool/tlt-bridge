# tlt-bridge — The Last Telegraph PC köprüsü

Windows PC'de PowerShell'de çalışan küçük bir köprü. Telegram botu **@TheLastTelegraphGameBot** üzerinden gelen komutları bilgisayarda çalıştırır ve sonucu geri gönderir. Unity projesi (The Last Telegraph) için kullanılır.

**Bu depoda hiçbir gizli bilgi yok.** Bot token'ı sadece PC'de, `%USERPROFILE%\.tlt-bridge\config.json` dosyasında durur.

## Kurulum (tek satır)

Yeni bir PowerShell penceresi aç ve şunu yapıştır:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/Erdocool/tlt-bridge/main/install.ps1 | iex #
```

Sondaki ` #` bilerek var: Telegram'dan kopyalarken sona eklenen saat yazısı yorum satırı olur, komutu bozmaz.

İlk çalıştırmada token sorar. BotFather'daki token'ı **sadece bu PowerShell penceresine** yapıştır (sohbete yazma). Sonra şu satırı görürsün:

```
Dinleniyor... (The Last Telegraph köprüsü)
```

Pencereyi açık tut. Sonraki seferlerde masaüstündeki **TLT Kopru** kısayoluna çift tıklaman yeterli (ya da aynı tek satırı tekrar yapıştır; bu aynı zamanda güncelleme yapar).

## Kimler komut verebilir?

- "Grok ve Enki The Last Telegraph" grubu (`-1003927815137`) varsayılan olarak izinli.
- Kendi özel sohbetin için: PC ekranındaki eşleştirme kodunu bota özelden yaz: `/pair KOD`.
- Özelden eşleştirdikten sonra grupta sadece eşleşmiş kişilerin komutları çalışır.
- Başka sohbetlerden gelen mesajlar çalıştırılmaz; PC penceresinde chat id'leri yazılır.

## Komutlar

| Komut | Ne yapar |
| --- | --- |
| `/ping` | Bilgisayar adı ve saat |
| `/ps <kod>` | PowerShell çalıştırır (ayrı iş olarak; köprü donmaz). Uzun çıktılar parça parça ya da `.txt` olarak gelir |
| `/job <no>` / `/jobs` / `/kill <no>` | İşin ara çıktısı / iş listesi / durdurma |
| `/file <yol>` | PC'deki dosyayı (klasörse zip yapıp) gönderir (en fazla 50 MB) |
| `/save <yol>` | Bu açıklamayla (caption) gönderilen dosyayı PC'ye kaydeder (en fazla 20 MB) |
| `/cd <yol>` | Varsayılan çalışma klasörü (başlangıç: `C:\TLT`) |

## Grok (kutu) nasıl bağlanıyor?

Telegram'dan güncelleme okuyan (`getUpdates`) tek taraf bu köprü. Grok'un bilgisayarı `getUpdates` çağırmaz, böylece iki taraf birbirinin mesajını çalmaz. Grok komutlarını botun dile özel açıklama alanına (`ia`) yazar, köprü sonuçları başka bir alana (`eo`) yazar; uzun içerik telegra.ph sayfalarında durur. Hepsi bot token'ından türetilen anahtarla şifrelenir (AES-256 + HMAC). Dosyalar Telegram dosya kimlikleriyle taşınır.

## Kendi kendini onarma (bekçi)

- Köprü her döngüde `%USERPROFILE%\.tlt-bridge\heartbeat.txt` dosyasına zaman yazar, PID'ini `bridge.pid`'e koyar.
- **TLT Kopru Bekcisi** zamanlanmış görevi (sadece bu kullanıcı, yönetici/UAC gerekmez) her 5 dakikada bir ve oturum açılışında `watchdog.ps1`'i penceresiz çalıştırır.
- Köprü kapalıysa ya da heartbeat 5 dakikadan eskiyse eski köprü pencerelerini kapatır ve köprüyü küçültülmüş pencerede yeniden başlatır.
- Her kontrol `C:\TLT\bridge_watchdog.log` dosyasına yazılır. Köprü her (yeniden) başladığında grupta kısa bir mesaj atar.
- Köprü açıkken Windows uyku moduna geçmez (ekran yine kapanabilir); hiçbir ayar değiştirilmez, köprü kapanınca biter. İstemezsen `TLT_ALLOW_SLEEP=1`.
- İkinci bir köprü açılmaya çalışılırsa (canlı biri varken) kendini kapatır, böylece 409 çakışması olmaz.
- Kurulum elle: `powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.tlt-bridge\watchdog.ps1" -Install` (kaldırmak için `-Uninstall`, zorla yeniden başlatmak için `-Force`).

## Notlar

- Aynı botla iki köprüyü aynı anda açma (409 hatası verir).
- Yönetici (UAC) isteyen komutlar onay penceresi açar; onu PC başında onaylaman gerekir.
- Token'ı değiştirmek için `%USERPROFILE%\.tlt-bridge\config.json` dosyasını silip kurulumu tekrar çalıştır.
