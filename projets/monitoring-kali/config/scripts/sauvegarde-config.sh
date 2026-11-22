#!/usr/bin/env bash
# Sauvegarde quotidienne de la configuration de supervision (14 jours conserves)
set -euo pipefail
umask 077                     # archives lisibles par root uniquement (base Grafana incluse)
DEST=/var/backups/monitoring
install -d -m 0700 "$DEST"
F="$DEST/config-$(date +%Y%m%d-%H%M).tar.gz"
tar -czf "$F" --ignore-failed-read \
  /etc/monitoring /etc/prometheus /etc/default/prometheus-* \
  /etc/suricata/suricata.yaml /var/lib/suricata/rules/local.rules \
  /etc/darkstat /etc/nftables.conf /etc/grafana /var/lib/grafana/grafana.db \
  /var/lib/monitoring /usr/local/bin/decouverte-reseau /usr/local/bin/metriques-securite \
  /usr/local/bin/etat-supervision /usr/local/bin/sauvegarde-config 2>/dev/null
find "$DEST" -name 'config-*.tar.gz' -mtime +14 -delete
tar -tzf "$F" >/dev/null && echo "Sauvegarde OK : $F ($(du -h "$F" | cut -f1))"
