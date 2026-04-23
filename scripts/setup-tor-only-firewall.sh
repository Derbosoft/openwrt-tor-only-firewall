#!/bin/sh
set -e
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "[*] OpenWrt Tor-only firewall – installation"

# ---- 0) Prérequis
[ "$(id -u)" -eq 0 ] || { echo "ERR: exécuter en root"; exit 1; }

WAN_IFS="wan|wan6|wwan"
CRONLINE='0 4 * * * /usr/bin/update_tor_relays.sh >/var/log/tor_relays_update.log 2>&1'
API_URL="https://onionoo.torproject.org/details?running=true&fields=or_addresses"

# ---- 1) Paquets
# FIX: nftables n'existe pas comme paquet seul sur OpenWrt,
#      kmod-nft-core suffit (fw4 fournit déjà nft)
echo "[*] Installation des paquets requis"
#apk update
#apk install curl jq kmod-nft-core ca-bundle >/dev/null

# ---- 2) Nettoyage ancien état
echo "[*] Nettoyage ancienne config Tor (si présente)"
for n in Allow-LAN-to-TorRelays-v4 Allow-LAN-to-TorRelays-v6 Drop-LAN-to-WAN-except-Tor Allow-LAN-DNS; do
  # FIX: parsing UCI plus robuste avec named sections
  uci show firewall 2>/dev/null | grep -E "\.name='$n'" | cut -d. -f1-2 | while read section; do
    uci delete "$section" 2>/dev/null || true
  done
done
for s in tor_relays_v4 tor_relays_v6; do
  uci show firewall 2>/dev/null | grep -E "\.name='$s'" | cut -d. -f1-2 | while read section; do
    uci delete "$section" 2>/dev/null || true
  done
done
uci commit firewall || true
/etc/init.d/firewall restart >/dev/null || true

# ---- 3) Créer les ipsets fw4
echo "[*] Déclaration des ipsets (v4/v6)"
uci add firewall ipset >/dev/null
uci set firewall.@ipset[-1].name='tor_relays_v4'
uci set firewall.@ipset[-1].family='ipv4'
uci set firewall.@ipset[-1].match='dst_ip'
uci set firewall.@ipset[-1].enabled='1'

uci add firewall ipset >/dev/null
uci set firewall.@ipset[-1].name='tor_relays_v6'
uci set firewall.@ipset[-1].family='ipv6'
uci set firewall.@ipset[-1].match='dst_ip'
uci set firewall.@ipset[-1].enabled='1'

uci commit firewall
/etc/init.d/firewall restart

# ---- 4) Créer les règles fw4
echo "[*] Création des règles fw4"

# FIX: Autoriser DNS vers le routeur lui-même (évite fuite/panne DNS)
# Les clients doivent utiliser le routeur comme DNS (dnsmasq local)
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-LAN-DNS'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Autoriser LAN -> relais Tor (IPv4)
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-LAN-to-TorRelays-v4'
uci set firewall.@rule[-1].family='ipv4'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].ipset='tor_relays_v4'
uci set firewall.@rule[-1].target='ACCEPT'

# Autoriser LAN -> relais Tor (IPv6)
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-LAN-to-TorRelays-v6'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].ipset='tor_relays_v6'
uci set firewall.@rule[-1].target='ACCEPT'

# Tout le reste LAN -> WAN = DROP
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Drop-LAN-to-WAN-except-Tor'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].target='DROP'

uci commit firewall
/etc/init.d/firewall restart

# ---- 5) Script de mise à jour des relais Tor
echo "[*] Installation du script /usr/bin/update_tor_relays.sh"
cat >/usr/bin/update_tor_relays.sh <<'EOS'
#!/bin/sh
set -e
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

API_URL="https://onionoo.torproject.org/details?running=true&fields=or_addresses"
TMP="/tmp/tor_relays.$$"
mkdir -p "$TMP"

echo "[*] Téléchargement de la liste Onionoo..."
curl -s --max-time 60 "$API_URL" \
| jq -r '.relays[]?.or_addresses[]?' \
| sed -E 's/^\[([0-9a-fA-F:]+)\]:[0-9]+$/\1/; s/^([0-9\.]+):[0-9]+$/\1/' \
| sort -u > "$TMP/all.txt"

grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$TMP/all.txt" > "$TMP/v4.txt" || true
grep -E ':'                                  "$TMP/all.txt" > "$TMP/v6.txt" || true

count_v4=$(wc -l < "$TMP/v4.txt")
count_v6=$(wc -l < "$TMP/v6.txt")
echo "[*] Relais trouvés : IPv4=$count_v4 IPv6=$count_v6"

# FIX: OR au lieu de AND — annuler si l'un OU l'autre est anormalement bas
if [ "$count_v4" -lt 100 ] || [ "$count_v6" -lt 50 ]; then
  echo "[WARN] Onionoo pauvre ou injoignable : v4=$count_v4 v6=$count_v6. MAJ annulée."
  rm -rf "$TMP"
  exit 0
fi

nft flush set inet fw4 tor_relays_v4 2>/dev/null || true
nft flush set inet fw4 tor_relays_v6 2>/dev/null || true

# FIX: batch nft en un seul appel au lieu d'une boucle par IP
# (évite ~7000 appels nft séparés qui saturaient le CPU)
if [ -s "$TMP/v4.txt" ]; then
  IPS=$(paste -sd ',' "$TMP/v4.txt")
  nft add element inet fw4 tor_relays_v4 "{ $IPS }" && \
    echo "[*] IPv4 : $count_v4 relais chargés" || \
    echo "[WARN] Échec chargement IPv4"
fi

if [ -s "$TMP/v6.txt" ]; then
  IPS=$(paste -sd ',' "$TMP/v6.txt")
  nft add element inet fw4 tor_relays_v6 "{ $IPS }" && \
    echo "[*] IPv6 : $count_v6 relais chargés" || \
    echo "[WARN] Échec chargement IPv6"
fi

rm -rf "$TMP"
echo "[✓] Mise à jour terminée."
EOS
chmod +x /usr/bin/update_tor_relays.sh

# ---- 6) Hotplug: mise à jour au boot (ifup WAN)
echo "[*] Hotplug au boot (wan up)"
cat >/etc/hotplug.d/iface/95-tor-relays-update <<EOF2
#!/bin/sh
[ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in
  $WAN_IFS)
    ( sleep 10; /usr/bin/update_tor_relays.sh ) &
  ;;
esac
EOF2
chmod +x /etc/hotplug.d/iface/95-tor-relays-update

# ---- 7) Cron: tous les jours à 04:00
echo "[*] Planification quotidienne (04:00)"
touch /etc/crontabs/root
sed -i '\#/usr/bin/update_tor_relays.sh#d' /etc/crontabs/root
echo "$CRONLINE" >> /etc/crontabs/root
/etc/init.d/cron restart

# ---- 8) Première mise à jour + vérifs
echo "[*] Première synchronisation de la liste Tor"
if /usr/bin/update_tor_relays.sh; then
  echo "[*] OK – sets remplis. Exemples :"
  nft list set inet fw4 tor_relays_v4 2>/dev/null | head -n 5 || true
  nft list set inet fw4 tor_relays_v6 2>/dev/null | head -n 5 || true
else
  echo "[WARN] Échec MAJ initiale – réessaie au prochain cron/hotplug."
fi

echo "
[✓] Installation terminée.
- Sans Tor Browser   : Internet bloqué (LAN->WAN DROP).
- Avec Tor Browser   : OK (TCP vers relais Tor autorisé).
- DNS                : Résolu par dnsmasq local (pas de fuite).
- Mise à jour relais : au boot (ifup WAN) + chaque jour à 04:00.

Vérifier les sets :
  nft list set inet fw4 tor_relays_v4
  nft list set inet fw4 tor_relays_v6
"
