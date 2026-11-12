#!/usr/bin/env bash
# =============================================================================
# recon.sh - Collecte d'informations sur un nom de domaine
#   1. DNS (dig)              -> IP publiques, IPv6, NS, MX, TXT
#   2. WHOIS                  -> domaine + IP (hébergeur)
#   3. Sous-domaines          -> crt.sh, Cert Spotter, OTX, HackerTarget,
#                                subfinder (si installé)
#   4. Pages / URLs du site   -> Wayback Machine (passif), puis en option :
#                                robots/sitemap, crawl, brute-force
#
# Usage : ./recon.sh [options] [domaine.com]
#         (sans domaine en argument, le script le demande au lancement)
#   -o DIR      dossier de sortie (défaut : ./recon_<domaine>_<date>)
#   -d N        profondeur du crawl (défaut : 3)
#   -w FICHIER  wordlist pour le brute-force
#   -h          aide
#
# Actions qui CONTACTENT la cible (visibles dans ses logs) - désactivées par
# défaut. Sans aucune de ces options, le script demande quoi activer :
#   -r          lire robots.txt et sitemap.xml   (quelques requêtes, discret)
#   -c          crawler le site                  (nombreuses requêtes, visible)
#   -b          brute-force de répertoires       (milliers de requêtes, très visible)
#   -a          activer -r -c -b sans poser de question
#   -p          mode 100% passif, sans poser de question
#
# ⚠ À utiliser uniquement sur des sites qui vous appartiennent ou pour lesquels
#   vous avez une autorisation écrite. Les parties 1 à 3 et Wayback sont
#   passives ; le crawl et le brute-force envoient du trafic vers la cible.
# =============================================================================

set -uo pipefail

DEPTH=3
DO_PROBE=0      # robots.txt + sitemap.xml
DO_CRAWL=0      # crawl du site
DO_BRUTE=0      # brute-force de répertoires
CHOICE_MADE=0   # 1 si l'utilisateur a déjà tranché via les options
WORDLIST=""
OUTDIR=""

# --- Couleurs ----------------------------------------------------------------
B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
section() { echo -e "\n${B}${C}=== $* ===${N}"; }
ok()      { echo -e "${G}[+]${N} $*"; }
warn()    { echo -e "${Y}[!]${N} $*"; }
err()     { echo -e "${R}[x]${N} $*" >&2; }
have()    { command -v "$1" >/dev/null 2>&1; }

usage() { awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit "${1:-0}"; }

# --- Arguments ---------------------------------------------------------------
while getopts "o:d:rcbapw:h" opt; do
  case $opt in
    o) OUTDIR="$OPTARG" ;;
    d) DEPTH="$OPTARG" ;;
    r) DO_PROBE=1; CHOICE_MADE=1 ;;
    c) DO_CRAWL=1; CHOICE_MADE=1 ;;
    b) DO_BRUTE=1; CHOICE_MADE=1 ;;
    a) DO_PROBE=1; DO_CRAWL=1; DO_BRUTE=1; CHOICE_MADE=1 ;;
    p) DO_PROBE=0; DO_CRAWL=0; DO_BRUTE=0; CHOICE_MADE=1 ;;
    w) WORDLIST="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))

# Si aucun domaine n'est passé en argument, on le demande à l'utilisateur
if [[ $# -ge 1 ]]; then
  INPUT="$1"
else
  INPUT=""
  while [[ -z "${INPUT// /}" ]]; do
    read -rp "Nom de domaine à analyser (ex: exemple.com) : " INPUT
  done
fi

# Nettoie l'entrée : retire http(s)://, chemin, port, "www." conservé tel quel
DOMAIN=$(echo "$INPUT" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#:[0-9]+$##' | tr '[:upper:]' '[:lower:]')
[[ -z "$DOMAIN" ]] && { err "Domaine invalide"; exit 1; }

# --- Choix des actions visibles / agressives ---------------------------------
ask() {  # ask "question" -> code 0 si oui (réponse par défaut : non)
  local rep
  read -rp "$1 [o/N] " rep
  [[ "$rep" =~ ^[oOyY]$ ]]
}

if (( CHOICE_MADE == 0 )) && [[ -t 0 ]]; then
  echo
  echo "${B}Actions qui contactent directement ${DOMAIN} (visibles dans ses logs).${N}"
  echo "Réponds ${B}o${N} pour activer, Entrée pour ignorer."
  ask "  1. Lire robots.txt et sitemap.xml  (quelques requêtes, discret) ?"         && DO_PROBE=1
  ask "  2. Crawler le site                 (nombreuses requêtes, visible) ?"        && DO_CRAWL=1
  ask "  3. Brute-forcer les répertoires    (milliers de requêtes, très visible) ?"  && DO_BRUTE=1
fi

OUTDIR="${OUTDIR:-./recon_${DOMAIN}_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/rapport.txt"

# Tout ce qui s'affiche est aussi sauvegardé dans le rapport
exec > >(tee -a "$REPORT") 2>&1

echo "${B}Cible : $DOMAIN${N}"
echo "Dossier de sortie : $OUTDIR"
echo "Date : $(date)"
MODE="passif (Wayback, DNS, WHOIS, crt.sh)"
(( DO_PROBE )) && MODE+=" + robots/sitemap"
(( DO_CRAWL )) && MODE+=" + crawl"
(( DO_BRUTE )) && MODE+=" + brute-force"
echo "Mode : $MODE"

# --- Vérification des outils -------------------------------------------------
for t in dig whois curl; do
  have "$t" || warn "Outil manquant : $t (sudo apt install dnsutils whois curl)"
done

# =============================================================================
# 1. DNS
# =============================================================================
section "1. DNS (dig)"

# Réponse complète pour l'enregistrement A (avec TTL et éventuels CNAME)
dig +noall +answer "$DOMAIN" A | tee "$OUTDIR/dig_A.txt"

# IP publiques (IPv4) : on ne garde que les lignes qui sont des adresses,
# pour ignorer les noms (CNAME) que dig +short affiche aussi
mapfile -t IPS < <(dig +short "$DOMAIN" A 2>/dev/null \
  | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u)

if [[ ${#IPS[@]} -eq 0 ]]; then
  err "Impossible de résoudre $DOMAIN"
else
  ok "IP publique(s) : ${IPS[*]}"
fi

for type in AAAA NS MX TXT; do
  echo -e "\n${B}-- $type --${N}"
  dig +noall +answer "$DOMAIN" "$type" 2>/dev/null | tee -a "$OUTDIR/dig_${type}.txt"
done

# =============================================================================
# 2. WHOIS
# =============================================================================
section "2. WHOIS"

echo -e "${B}-- Domaine --${N}"
whois "$DOMAIN" 2>/dev/null > "$OUTDIR/whois_domaine.txt"
grep -iE '^(Registrar|Registrant (Organization|Country)|Creation Date|Registry Expiry Date|Updated Date|Name Server|Domain Status|DNSSEC):' \
  "$OUTDIR/whois_domaine.txt" | sort -u

for ip in "${IPS[@]:-}"; do
  [[ -z "$ip" ]] && continue
  echo -e "\n${B}-- Hébergeur de $ip --${N}"
  whois "$ip" 2>/dev/null > "$OUTDIR/whois_${ip//[:.]/_}.txt"
  grep -iE '^(NetName|OrgName|org-name|Organization|descr|Country|CIDR|inetnum|NetRange|OriginAS|origin|abuse-mailbox|OrgAbuseEmail):' \
    "$OUTDIR/whois_${ip//[:.]/_}.txt" | sort -u | head -n 15
done

# =============================================================================
# 3. SOUS-DOMAINES
# =============================================================================
section "3. Sous-domaines"

SUBS_RAW="$OUTDIR/.subs_raw.txt"
SUBS="$OUTDIR/sous_domaines.txt"
: > "$SUBS_RAW"
DOM_RE="${DOMAIN//./\\.}"   # domaine échappé pour les expressions régulières

# Télécharge une URL avec 3 tentatives (crt.sh est souvent surchargé)
get_retry() {
  local url="$1" i out
  for i in 1 2 3; do
    out=$(curl -s --max-time 60 -A "Mozilla/5.0" "$url") && [[ -n "$out" ]] \
      && { printf '%s' "$out"; return 0; }
    sleep 3
  done
  return 1
}

# Extrait tous les noms d'hôtes du domaine depuis n'importe quelle réponse
# (JSON ou texte), sans dépendre de jq.
extract_hosts() {
  sed 's/\\n/\n/g' | tr '[:upper:]' '[:lower:]' \
    | grep -oE "([a-z0-9_*-]+\.)*${DOM_RE}" | sed 's/^\*\.//' | sort -u
}

# Ajoute les résultats d'une source et affiche combien elle en a trouvé
add_source() {   # add_source "Nom" "réponse brute"
  local name="$1" data="$2" found n=0
  if [[ -z "$data" ]]; then
    warn "$name : aucune réponse (service indisponible ou limite atteinte)"
    return
  fi
  found=$(printf '%s' "$data" | extract_hosts)
  [[ -n "$found" ]] && n=$(wc -l <<< "$found")
  if (( n > 0 )); then
    ok "$name : $n hôte(s)"
    printf '%s\n' "$found" >> "$SUBS_RAW"
  else
    warn "$name : 0 résultat (réponse vide ou service surchargé, réessaie plus tard)"
  fi
}

# 3a. crt.sh (certificats publics)
echo "-> crt.sh..."
add_source "crt.sh" "$(get_retry "https://crt.sh/?q=%25.${DOMAIN}&output=json")"

# 3b. Cert Spotter (autre base de certificats, sans clé, quota limité)
echo "-> Cert Spotter..."
add_source "Cert Spotter" "$(get_retry "https://api.certspotter.com/v1/issuances?domain=${DOMAIN}&include_subdomains=true&expand=dns_names")"

# 3c. AlienVault OTX (DNS passif : noms vus dans des résolutions réelles)
echo "-> AlienVault OTX..."
add_source "AlienVault OTX" "$(get_retry "https://otx.alienvault.com/api/v1/indicators/domain/${DOMAIN}/passive_dns")"

# 3d. HackerTarget (sans clé, quota quotidien limité)
echo "-> HackerTarget..."
add_source "HackerTarget" "$(get_retry "https://api.hackertarget.com/hostsearch/?q=${DOMAIN}")"

# 3e. subfinder (si installé)
if have subfinder; then
  echo "-> subfinder..."
  add_source "subfinder" "$(subfinder -silent -d "$DOMAIN" 2>/dev/null)"
fi

sort -u "$SUBS_RAW" > "$SUBS"
rm -f "$SUBS_RAW"

echo
ok "$(wc -l < "$SUBS") sous-domaine(s) unique(s) au total -> $SUBS"
head -n 50 "$SUBS"
[[ $(wc -l < "$SUBS") -gt 50 ]] && echo "... (voir $SUBS pour la liste complète)"

# =============================================================================
# 4. PAGES / URLS DU SITE
# =============================================================================
section "4. Pages et URLs"

URLS_RAW="$OUTDIR/.urls_raw.txt"
URLS="$OUTDIR/urls.txt"
: > "$URLS_RAW"

# --- 4a. Wayback Machine (PASSIF : la cible n'est jamais contactée) ---------
echo "-> [passif] Wayback Machine..."
curl -s --max-time 60 \
  "http://web.archive.org/cdx/search/cdx?url=${DOMAIN}/*&output=text&fl=original&collapse=urlkey&limit=5000" \
  >> "$URLS_RAW"

# --- Détection du schéma (uniquement si une action visible est demandée) -----
BASE=""
if (( DO_PROBE || DO_CRAWL || DO_BRUTE )); then
  for scheme in https http; do
    if curl -s -o /dev/null --max-time 10 -L "${scheme}://${DOMAIN}"; then
      BASE="${scheme}://${DOMAIN}"; break
    fi
  done
  [[ -z "$BASE" ]] && warn "Le site ne répond ni en HTTPS ni en HTTP : actions visibles annulées"
fi

# --- 4b. robots.txt + sitemap.xml (VISIBLE, léger) ---------------------------
if (( DO_PROBE )) && [[ -n "$BASE" ]]; then
  echo "-> [visible] robots.txt et sitemap.xml..."
  curl -s --max-time 10 "$BASE/robots.txt" > "$OUTDIR/robots.txt"
  grep -iE '^(Allow|Disallow|Sitemap):' "$OUTDIR/robots.txt" | head -n 30
  grep -iE '^(Allow|Disallow):' "$OUTDIR/robots.txt" | awk '{print $2}' \
    | grep '^/' | sed "s#^#${BASE}#" >> "$URLS_RAW"

  SITEMAPS=$( { echo "$BASE/sitemap.xml"; grep -i '^Sitemap:' "$OUTDIR/robots.txt" 2>/dev/null | awk '{print $2}'; } | sort -u)
  for sm in $SITEMAPS; do
    curl -s --max-time 15 "$sm" | grep -oE '<loc>[^<]+</loc>' | sed -E 's#</?loc>##g' >> "$URLS_RAW"
  done
elif (( DO_PROBE == 0 )); then
  echo "(ignoré) robots.txt / sitemap.xml  -> option -r"
fi

# --- 4c. Crawl (VISIBLE, nombreuses requêtes) --------------------------------
if (( DO_CRAWL )) && [[ -n "$BASE" ]]; then
  if have katana; then
    echo "-> [visible] Crawl avec katana (profondeur $DEPTH)..."
    katana -silent -u "$BASE" -d "$DEPTH" -jc >> "$URLS_RAW" 2>/dev/null
  elif have wget; then
    echo "-> [visible] Crawl avec wget --spider (profondeur $DEPTH)..."
    TMPDL=$(mktemp -d)
    ( cd "$TMPDL" && wget --spider -r -l "$DEPTH" -nd -nv -T 10 -t 1 --wait=0.2 \
        --no-parent --domains="$DOMAIN" "$BASE" 2>&1 ) \
      | grep -oE 'URL:[^ ]+' | sed 's/^URL://' >> "$URLS_RAW"
    rm -rf "$TMPDL"
  else
    warn "Ni katana ni wget : crawl ignoré"
  fi
elif (( DO_CRAWL == 0 )); then
  echo "(ignoré) crawl du site             -> option -c"
fi

# --- 4d. Brute-force de répertoires (TRÈS VISIBLE) ---------------------------
if (( DO_BRUTE )) && [[ -n "$BASE" ]]; then
  if [[ -z "$WORDLIST" ]]; then
    for w in /usr/share/seclists/Discovery/Web-Content/common.txt \
             /usr/share/wordlists/dirb/common.txt \
             /usr/share/dirb/wordlists/common.txt; do
      [[ -f "$w" ]] && { WORDLIST="$w"; break; }
    done
  fi
  if [[ -z "$WORDLIST" || ! -f "$WORDLIST" ]]; then
    warn "Aucune wordlist trouvée (sudo apt install seclists ou utilise -w)"
  elif have ffuf; then
    echo "-> [très visible] Brute-force avec ffuf ($WORDLIST)..."
    ffuf -s -u "$BASE/FUZZ" -w "$WORDLIST" -mc 200,204,301,302,307,401,403 \
      -t 20 -rate 50 2>/dev/null | sed "s#^#${BASE}/#" >> "$URLS_RAW"
  elif have gobuster; then
    echo "-> [très visible] Brute-force avec gobuster ($WORDLIST)..."
    gobuster dir -q -u "$BASE" -w "$WORDLIST" -t 20 --no-error 2>/dev/null \
      | awk '{print $1}' | sed "s#^#${BASE}#" >> "$URLS_RAW"
  else
    warn "Ni ffuf ni gobuster installé (sudo apt install ffuf)"
  fi
elif (( DO_BRUTE == 0 )); then
  echo "(ignoré) brute-force répertoires   -> option -b"
fi

# Nettoyage final
grep -E '^https?://' "$URLS_RAW" | sed 's/#.*$//' | sort -u > "$URLS"
rm -f "$URLS_RAW"

ok "$(wc -l < "$URLS") URL(s) unique(s) -> $URLS"
head -n 40 "$URLS"
[[ $(wc -l < "$URLS") -gt 40 ]] && echo "... (voir $URLS pour la liste complète)"

# =============================================================================
# Résumé
# =============================================================================
section "Terminé"
echo "Fichiers générés dans : $OUTDIR"
ls -1 "$OUTDIR" | sed 's/^/  - /'
