# Sert le fichier preseed a l'installateur Kali (VirtualBox NAT : l'hote est 10.0.2.2)
param(
  [string]$Template = "$PSScriptRoot\preseed.cfg.template",
  [string]$Secrets  = "$PSScriptRoot\..\secrets",
  [int]$Port = 8099,
  [int]$MaxRequests = 5
)
$pw  = ((Get-Content "$Secrets\identifiants.txt" -Encoding UTF8 | Select-String '^Mot de passe' | Select -First 1).Line -replace '^Mot de passe[^:]*:\s*','').Trim()
$key = (Get-Content "$Secrets\id_kali.pub" -Raw).Trim()
$body = (Get-Content $Template -Raw).Replace('__PASSWORD__',$pw).Replace('__PUBKEY__',$key) -replace "`r`n","`n"
$bytes = [Text.Encoding]::UTF8.GetBytes($body)

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Output "Preseed servi sur 127.0.0.1:$Port"
for ($i = 0; $i -lt $MaxRequests; $i++) {
  $client = $listener.AcceptTcpClient()
  $stream = $client.GetStream()
  $reader = [IO.StreamReader]::new($stream)
  $line = $reader.ReadLine()
  while (($h = $reader.ReadLine()) -ne '' -and $h -ne $null) {}
  Write-Output "$(Get-Date -Format T) $line"
  $head = "HTTP/1.0 200 OK`r`nContent-Type: text/plain`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb,0,$hb.Length); $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
  $client.Close()
}
$listener.Stop()
