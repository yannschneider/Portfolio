# Sonde de supervision réseau et sécurité sous Kali Linux

Fichiers du projet 08 du portfolio. La procédure complète et les résultats sont dans les PDF :

- [Documentation d'installation](../../docs/monitoring-kali-installation.pdf)
- [Guide utilisateur](../../docs/monitoring-kali-guide-utilisateur.pdf)

## Contenu

| Dossier | Rôle |
|---|---|
| `install/creer-vm.ps1` | Création de la VM VirtualBox `kali-monitor` (4 vCPU, 8 Go, 80 Go, NAT + pont) |
| `install/preseed.cfg.template` | Réponses de l'installateur Kali (compte, langue, disque, logiciels) |
| `install/serve-preseed.ps1` | Mini serveur HTTP qui sert le preseed à l'installateur (10.0.2.2:8099) |
| `install/reseau-nm.sh` | Connexions NetworkManager : `admin-nat` (eth0) et `lan-surveillee` (eth1) |
| `config/provision.sh` | Installe et configure tous les outils (idempotent) |
| `config/suricata/local.rules` | Règles de détection locales (balayages, protocoles en clair) |
| `config/prometheus/` | Collecte, sondes blackbox, 10 règles d'alerte |
| `config/grafana/` | Source de données et tableau de bord provisionnés |
| `config/scripts/` | Découverte réseau, métriques de sécurité, état, sauvegarde |
| `config/systemd/` | Minuteries (15 min, 1 min, quotidienne) |
| `config/tests/recette.sh` | Cahier de recette automatisé |

## Utilisation rapide

```powershell
.\install\creer-vm.ps1
.\install\serve-preseed.ps1      # puis démarrer la VM, "Install" + Tab + options de la doc
scp -r config kali-monitor:/tmp/
ssh kali-monitor "sudo env WEB_PASSWORD='...' MON_IF=eth1 bash /tmp/config/provision.sh"
```

Aucun mot de passe ni aucune clé ne sont publiés ici : le serveur de preseed les lit dans un dossier `secrets/` local.
