# Creation de la VM VirtualBox "kali-monitor" (a lancer sur le PC hote Windows)
param(
  [string]$Iso = "$PSScriptRoot\..\kali-linux-2026.3-installer-amd64.iso",
  [string]$Nom = "kali-monitor",
  [string]$CartePontee = "Realtek 8922AE WiFi 7 PCI-E NIC"   # Get-NetAdapter -Physical
)
$v = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$dir = "$env:USERPROFILE\VirtualBox VMs\$Nom"

& $v createvm --name $Nom --ostype Debian_64 --register
& $v modifyvm $Nom --memory 8192 --cpus 4 --vram 128 --graphicscontroller vmsvga `
  --firmware bios --audio-enabled off --clipboard-mode bidirectional --boot1 dvd --boot2 disk
# Carte 1 : NAT pour l'administration depuis l'hote (redirections sur 127.0.0.1 uniquement)
& $v modifyvm $Nom --nic1 nat --nictype1 82540EM `
  --natpf1 "ssh,tcp,127.0.0.1,2222,,22" --natpf1 "grafana,tcp,127.0.0.1,3000,,3000" `
  --natpf1 "darkstat,tcp,127.0.0.1,3001,,3001" --natpf1 "prometheus,tcp,127.0.0.1,9090,,9090"
& $v createmedium disk --filename "$dir\$Nom.vdi" --size 81920 --format VDI
& $v storagectl $Nom --name SATA --add sata --controller IntelAhci --portcount 2
& $v storageattach $Nom --storagectl SATA --port 0 --device 0 --type hdd --medium "$dir\$Nom.vdi"
& $v storageattach $Nom --storagectl SATA --port 1 --device 0 --type dvddrive --medium $Iso

# Installation : lancer serve-preseed.ps1, demarrer la VM, choisir "Install", touche Tab et ajouter :
#   auto=true priority=critical url=http://10.0.2.2:8099/preseed.cfg hostname=kali-monitor domain=lan locale=fr_FR.UTF-8 keymap=fr
# Apres l'installation (VM eteinte) : carte 2 en pont sur le reseau local, mode promiscuite
#   & $v storageattach $Nom --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
#   & $v modifyvm $Nom --nic2 bridged --bridgeadapter2 $CartePontee --nictype2 82540EM --nicpromisc2 allow-all

