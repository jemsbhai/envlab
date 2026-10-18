# kiosk_voice.ps1: speak kiosk events on this Windows laptop's speakers.
# Tails ~/envlab/events.jsonl on the Pi over SSH and voices each event with the Windows speech engine.
# Usage (PowerShell):  .\kiosk_voice.ps1                       (defaults to default@10.104.0.84)
#                      .\kiosk_voice.ps1 -PiHost user@host
# Enter the Pi password at the prompt; Ctrl+C stops it.
param(
    [string]$PiHost = "default@10.104.0.84",
    [string]$EventsPath = "~/envlab/events.jsonl"
)

Add-Type -AssemblyName System.Speech
$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voice.Rate = 1
$voice.Volume = 100

function Say([string]$text) {
    Write-Host ("{0}  {1}" -f (Get-Date -Format HH:mm:ss), $text)
    $voice.Speak($text)
}

Say "Kiosk voice ready"

& ssh $PiHost "tail -n 0 -F $EventsPath" | ForEach-Object {
    $line = $_
    try { $ev = $line | ConvertFrom-Json } catch { return }
    $name = if ($ev.id) { $ev.id } else { "unknown" }
    switch ($ev.type) {
        "checkin" {
            [console]::Beep(880, 150)
            Say ("Welcome {0}, checked in. Face match {1} percent." -f $name, [math]::Round(100 * $ev.score))
        }
        "checkout" {
            [console]::Beep(660, 150)
            Say ("{0} checked out after {1} minutes." -f $name, [math]::Round($ev.duration_s / 60, 1))
        }
        "face_reject" {
            [console]::Beep(220, 400)
            Say ("Face not recognized for {0}. Check in denied." -f $name)
        }
        "unknown_card" {
            [console]::Beep(330, 300)
            Say "Unknown card. Please enroll first."
        }
        "tamper" {
            [console]::Beep(440, 100); [console]::Beep(440, 100)
            Say "Reader moved."
        }
        "bind" {
            Say ("Card bound to {0}." -f $name)
        }
        "hello" {
            Say "Card reader online."
        }
    }
}
