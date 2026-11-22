#!/usr/bin/env bash
# =====================================================================
#  Provisionnement de la VM Kali "kali-monitor"
#  Supervision reseau, securite et systeme du reseau local
#  Usage : sudo WEB_PASSWORD='...' MON_IF=eth1 bash provision.sh
# =====================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
SRC="$(cd "$(dirname "$0")" && pwd)"
MON_IF="${MON_IF:-eth1}"          # interface pontee sur le reseau local
WEB_PASSWORD="${WEB_PASSWORD:?WEB_PASSWORD manquant}"
LOG=/var/log/provision-monitoring.log
exec > >(tee -a "$LOG") 2>&1
step() { echo; echo "=== [$(date +%T)] $* ==="; }

step "1. Detection du reseau surveille ($MON_IF)"
ip link set "$MON_IF" up
for i in $(seq 1 30); do ip -4 addr show "$MON_IF" | grep -q inet && break; sleep 2; done
LAN_CIDR=$(ip -4 route show dev "$MON_IF" proto kernel | awk '{print $1; exit}')
# La route par defaut passe par eth0 (NAT) : la passerelle du LAN est lue dans le bail DHCP
GATEWAY=$(nmcli -g DHCP4.OPTION device show "$MON_IF" 2>/dev/null | tr '|' '\n' | grep -E '^\s*routers = ' | head -n1 | awk -F' = ' '{print $2}' | awk '{print $1}')
if [ -z "$GATEWAY" ]; then GATEWAY=$(echo "$LAN_CIDR" | sed 's#\.[0-9]*/.*#.254#'); fi
echo "Reseau : $LAN_CIDR  Passerelle : $GATEWAY"
install -d /etc/monitoring
cat > /etc/monitoring/monitoring.env <<EOF
MON_IF=$MON_IF
LAN_CIDR=$LAN_CIDR
GATEWAY=$GATEWAY
EOF

step "2. Mise a jour et paquets"
apt-get update
apt-get install -y \
  tcpdump tshark wireshark nmap arp-scan netdiscover \
  iftop nload bmon vnstat htop iotop sysstat \
  suricata suricata-update jq \
  darkstat arpwatch nftables \
  prometheus prometheus-node-exporter prometheus-blackbox-exporter \
  apt-transport-https gnupg curl ca-certificates

step "3. Grafana (depot officiel apt.grafana.com)"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y grafana

step "4. Droits de capture pour l'utilisateur yann"
usermod -aG wireshark,adm yann || true

step "5. Suricata (IDS) sur $MON_IF"
sed -i "s#^\(\s*HOME_NET:\s*\).*#\1\"[$LAN_CIDR]\"#" /etc/suricata/suricata.yaml
sed -i "0,/- interface: .*/s//- interface: $MON_IF/" /etc/suricata/suricata.yaml
sed -i 's/^\(\s*community-id:\s*\)false/\1true/' /etc/suricata/suricata.yaml
if [ -f /etc/default/suricata ]; then
  sed -i "s/^IFACE=.*/IFACE=$MON_IF/; s/^LISTENMODE=.*/LISTENMODE=af-packet/" /etc/default/suricata
fi
suricata-update update-sources || true
suricata-update enable-source et/open || true
# Bruit du pont Wi-Fi : trames Ethernet de type inconnu (decodeur) -> regle desactivee
echo "2200121" > /etc/suricata/disable.conf
suricata-update --no-test --disable-conf /etc/suricata/disable.conf
install -m 0644 "$SRC/suricata/local.rules" /var/lib/suricata/rules/local.rules
grep -q 'local.rules' /etc/suricata/suricata.yaml || \
  sed -i 's#^\(\s*\)- suricata.rules#&\n\1- /var/lib/suricata/rules/local.rules#' /etc/suricata/suricata.yaml
suricata -T -c /etc/suricata/suricata.yaml
# L'arret de Suricata peut bloquer plusieurs minutes sur af-packet : limite a 60 s
install -d /etc/systemd/system/suricata.service.d
printf '[Service]\nTimeoutStopSec=60\n' > /etc/systemd/system/suricata.service.d/arret.conf
systemctl daemon-reload
systemctl enable suricata
systemctl restart suricata

step "6. darkstat (analyse de trafic par appareil) sur le port 3001"
# ntopng n'est publie ni dans les depots Kali ni pour Kali sur packages.ntop.org :
# darkstat (depot Kali) le remplace. Ecoute uniquement sur la carte d'administration.
ADMIN_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
LAN_NET=$(echo "$LAN_CIDR" | cut -d/ -f1)
LAN_MASK=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]).netmask)" "$LAN_CIDR")
cat > /etc/darkstat/init.cfg <<EOF
START_DARKSTAT=yes
INTERFACE="-i $MON_IF"
DIR="/var/lib/darkstat"
PORT="-p 3001"
BINDIP="-b ${ADMIN_IP:-10.0.2.15}"
LOCAL="-l $LAN_NET/$LAN_MASK"
DNS="--no-dns"
DAYLOG="--daylog darkstat-daylog"
DB="--import darkstat-db --export darkstat-db"
EOF
systemctl enable darkstat
systemctl restart darkstat

step "7. arpwatch (nouvelles machines sur le reseau)"
systemctl disable --now arpwatch 2>/dev/null || true
systemctl enable "arpwatch@$MON_IF"
systemctl restart "arpwatch@$MON_IF"

step "8. vnStat (volumes de trafic)"
systemctl enable --now vnstat
sleep 3
vnstat --add -i "$MON_IF" 2>/dev/null || true
systemctl restart vnstat

step "9. Prometheus, node_exporter, blackbox_exporter"
install -d /var/lib/node_exporter/textfile_collector /etc/prometheus/targets
chown prometheus:prometheus /var/lib/node_exporter/textfile_collector
install -m 0644 "$SRC/prometheus/prometheus.yml"    /etc/prometheus/prometheus.yml
install -m 0644 "$SRC/prometheus/alertes.rules.yml" /etc/prometheus/alertes.rules.yml
install -m 0644 "$SRC/prometheus/blackbox.yml"      /etc/prometheus/blackbox.yml
echo "ARGS=\"--collector.textfile.directory=/var/lib/node_exporter/textfile_collector --collector.systemd\"" > /etc/default/prometheus-node-exporter
echo "ARGS=\"--config.file=/etc/prometheus/blackbox.yml\"" > /etc/default/prometheus-blackbox-exporter
setcap cap_net_raw+ep "$(command -v prometheus-blackbox-exporter)" || true
cat > /etc/prometheus/targets/infra.yml <<EOF
- targets: ['$GATEWAY']
  labels: {role: 'passerelle', nom: 'box-internet'}
- targets: ['1.1.1.1', '9.9.9.9']
  labels: {role: 'internet', nom: 'dns-public'}
EOF
install -m 0755 "$SRC/scripts/decouverte-reseau.sh"  /usr/local/bin/decouverte-reseau
install -m 0755 "$SRC/scripts/metriques-securite.sh" /usr/local/bin/metriques-securite
install -m 0755 "$SRC/scripts/etat-supervision.sh"   /usr/local/bin/etat-supervision
install -m 0755 "$SRC/scripts/sauvegarde-config.sh"  /usr/local/bin/sauvegarde-config
install -m 0644 "$SRC/systemd/"*.service "$SRC/systemd/"*.timer /etc/systemd/system/
systemctl daemon-reload
/usr/local/bin/decouverte-reseau
/usr/local/bin/metriques-securite
chown -R prometheus:prometheus /etc/prometheus/targets
promtool check config /etc/prometheus/prometheus.yml
# Interface Web officielle de Prometheus (absente du paquet Debian)
bash /usr/share/prometheus/install-ui.sh || true
systemctl enable prometheus prometheus-node-exporter prometheus-blackbox-exporter
systemctl restart prometheus-node-exporter prometheus-blackbox-exporter prometheus
systemctl enable --now decouverte-reseau.timer metriques-securite.timer sauvegarde-config.timer

step "10. Grafana : source de donnees, tableaux de bord, mot de passe"
install -d /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
install -m 0644 "$SRC/grafana/datasource.yml" /etc/grafana/provisioning/datasources/prometheus.yml
install -m 0644 "$SRC/grafana/dashboards.yml" /etc/grafana/provisioning/dashboards/monitoring.yml
install -m 0644 "$SRC/grafana/"*.json /var/lib/grafana/dashboards/
# Tableau de bord communautaire "Node Exporter Full" (grafana.com, id 1860)
curl -fsSL https://grafana.com/api/dashboards/1860/revisions/latest/download \
  | sed 's/\${DS_PROMETHEUS}/prometheus/g' > /var/lib/grafana/dashboards/node-exporter-full.json || true
chown -R grafana:grafana /var/lib/grafana/dashboards
sed -i 's/^;\?\s*http_port = .*/http_port = 3000/' /etc/grafana/grafana.ini
sed -i 's/^;\?\s*allow_sign_up = .*/allow_sign_up = false/' /etc/grafana/grafana.ini
sed -i 's/^;\?\s*reporting_enabled = .*/reporting_enabled = false/' /etc/grafana/grafana.ini
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server
sleep 10
grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini admin reset-admin-password "$WEB_PASSWORD" >/dev/null \
  || grafana-cli --homepath /usr/share/grafana admin reset-admin-password "$WEB_PASSWORD" >/dev/null
# Le compte administrateur Grafana s'appelle "yann"
for i in $(seq 1 30); do curl -sf http://localhost:3000/api/health >/dev/null && break; sleep 2; done
curl -sf -u "admin:$WEB_PASSWORD" -X PUT -H 'Content-Type: application/json' \
  -d '{"login":"yann","name":"Yann","email":"yann@kali-monitor.lan"}' http://localhost:3000/api/user >/dev/null || true

step "10b. Pare-feu : la sonde reste discrete sur le reseau surveille"
install -m 0644 "$SRC/nftables.conf" /etc/nftables.conf
sed -i "s/__MON_IF__/$MON_IF/g" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

step "11. Premiere sauvegarde"
/usr/local/bin/sauvegarde-config

step "Termine"
/usr/local/bin/etat-supervision || true
