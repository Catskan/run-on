#!/usr/bin/env bash
# nas-remote.sh — bibliothèque commune de la couche remote-exec / SSHFS.
# Sourcée par : run-on, which-host, mount-repo, umount-repo.
#
# Elle centralise ce qui était dupliqué (et divergent) entre les scripts :
#   - options SSH robustes (tableau, pas de chaîne éclatée : SSH_KEY avec espace ne casse plus)
#     + ControlMaster : la connexion du probe est RÉUTILISÉE par l'exec -> TOCTOU probe→exec
#     éliminé et latence divisée par 2 (une seule poignée de main SSH par commande).
#   - split_endpoint : parsing "user@host[:port]" UNIFORME entre tous les scripts.
#   - retry/backoff sur les opérations réseau (un paquet SYN perdu ne déclasse plus un hôte).
#   - mount_healthy : un mount est sain SSI présent dans /proc/mounts ET son daemon sshfs vivant
#     ET réactif — ZÉRO I/O sur le FUSE pour le vérifier, donc zéro risque d'état D.
#   - mutations de mounts.tsv sérialisées par flock + mktemp+mv (deux process concurrents ne
#     peuvent plus s'entrelacer sur le même fichier temporaire).
#
# Idempotente, sans effet de bord au source. N'active pas `set -e` (à la charge de l'appelant).

# --- Garde anti-double-source -------------------------------------------------
[ -n "${_NAS_REMOTE_SH:-}" ] && return 0
_NAS_REMOTE_SH=1

# --- Config commune (surchargée par l'environnement si besoin) -----------------
RUNON_STATE_DIR="${RUNON_STATE_DIR:-$HOME/.config/run-on}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_run_on_clients}"
MOUNTS="${MOUNTS:-$RUNON_STATE_DIR/mounts.tsv}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-6}"
SSH_CTRL_DIR="${SSH_CTRL_DIR:-/tmp/.run-on-ssh-ctrl}"
mkdir -p "$SSH_CTRL_DIR" "$RUNON_STATE_DIR" 2>/dev/null || true

# Options SSH sous forme de TABLEAU (jamais une chaîne re-splittée par le shell).
SSH_OPTS=(
  -i "$SSH_KEY"
  -o StrictHostKeyChecking=accept-new
  -o BatchMode=yes
  -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
  -o ControlMaster=auto
  -o "ControlPath=$SSH_CTRL_DIR/%r@%h:%p"
  -o ControlPersist=30s
)

# --- Résolution hôte / registre -----------------------------------------------
# HOSTS : premier hosts.json trouvé, du plus spécifique (override local) au plus générique
# (config embarquée dans l'install).
nr_find_hosts() {
  local c
  for c in "$RUNON_STATE_DIR/hosts.json" /etc/run-on/hosts.json /usr/local/etc/run-on/hosts.json; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# host_field <hosts.json> <hôte> <champ>
nr_host_field() { jq -r --arg h "$2" ".hosts[\$h].$3 // empty" "$1" 2>/dev/null; }

# split_endpoint "user@host[:port]" -> EP_ADDR (user@host) + EP_PORT (port ou 22).
# Adresses IPv4/noms d'hôtes uniquement -> le seul ':' possible est un port numérique.
split_endpoint() {
  local ep="$1" port
  case "$ep" in
    *:*) port="${ep##*:}"
         case "$port" in
           ''|*[!0-9]*) EP_ADDR="$ep"; EP_PORT=22 ;;
           *)           EP_ADDR="${ep%:*}"; EP_PORT="$port" ;;
         esac ;;
    *)   EP_ADDR="$ep"; EP_PORT=22 ;;
  esac
}

# resolve_mdns <nom.local> -> IPv4 sur stdout (vide si non résolu). Nécessite `avahi-resolve` ou
# équivalent installé séparément — pas de dépendance forte ici.
resolve_mdns() {
  command -v avahi-resolve >/dev/null 2>&1 || return 1
  avahi-resolve -4 -n "$1" 2>/dev/null | awk '{print $2}'
}

# Adresse SSH effective d'un hôte : 1) public si RUNON_PREFER_PUBLIC=1, 2) mDNS->IP, 3) IP/host statique.
# Nécessite $HOSTS (chemin hosts.json) défini par l'appelant.
host_ssh_addr() {
  local name="$1" base mdns ip pub
  base="$(nr_host_field "$HOSTS" "$name" ssh)"
  [ -n "$base" ] || return 0
  if [ "${RUNON_PREFER_PUBLIC:-0}" = "1" ]; then
    pub="$(nr_host_field "$HOSTS" "$name" public)"
    [ -n "$pub" ] && { printf '%s' "$pub"; return 0; }
  fi
  mdns="$(nr_host_field "$HOSTS" "$name" mdns)"
  if [ -n "$mdns" ]; then
    ip="$(resolve_mdns "$mdns" || true)"
    [ -n "$ip" ] && { printf '%s@%s' "${base%@*}" "$ip"; return 0; }
  fi
  printf '%s' "$base"
}

# --- Réseau : retry/backoff + joignabilité -------------------------------------
# retry <cmd...> : jusqu'à 4 tentatives, backoff 1/2/4 s. Renvoie le code de la dernière.
retry() {
  local n rc=0
  for n in 1 2 4; do
    "$@" && return 0
    rc=$?
    sleep "$n"
  done
  "$@"; rc=$?
  return $rc
}

# reachable_ssh "user@host[:port]" : sonde le SOUS-SYSTÈME SFTP (ce que sshfs utilise), PAS une
# commande shell. Un hôte SFTP-only accepte l'auth par clé mais REFUSE l'exec d'une commande
# (`ssh host exit 0` -> « Permission denied » après auth OK) -> l'ancien probe le classait à tort
# « injoignable » alors que le montage marche. `sftp -b /dev/null` se connecte, ne fait rien, sort
# 0 si l'auth SFTP passe ; robuste multi-OS (SFTP = subsystem, pas de shell : cmd.exe/PowerShell
# n'entrent pas en jeu) et ne consomme pas de stdin. Capture stderr dans NR_SSH_LAST_ERR pour
# DISTINGUER un refus d'auth d'un vrai injoignable (nr_ssh_reason).
NR_SSH_LAST_ERR=""
reachable_ssh() {
  split_endpoint "$1"
  NR_SSH_LAST_ERR="$(sftp -b /dev/null "${SSH_OPTS[@]}" -P "$EP_PORT" "$EP_ADDR" 2>&1 >/dev/null)"
}
# reachable_ssh_retry : idem, avec backoff (un blip réseau ne déclasse plus l'hôte).
reachable_ssh_retry() { retry reachable_ssh "$1"; }

# nr_ssh_reason : traduit le dernier échec SSH (NR_SSH_LAST_ERR) en motif LISIBLE. Évite le piège
# récurrent où un simple « Permission denied » (clé non autorisée) était rapporté « injoignable ».
nr_ssh_reason() {
  case "$NR_SSH_LAST_ERR" in
    *"Permission denied"*|*"publickey"*|*"Too many authentication"*|*"Authentication failed"*)
        echo "authentication refused (client key not authorized on this host?)" ;;
    *"Connection refused"*)   echo "connection refused (no sshd on this port?)" ;;
    *"timed out"*|*"timeout"*) echo "timed out (host off / network down?)" ;;
    *"No route to host"*|*"Network is unreachable"*) echo "no network route" ;;
    *"Host key verification"*|*"IDENTIFICATION HAS CHANGED"*) echo "host key rejected/changed" ;;
    *"resolve"*|*"Name or service not known"*) echo "name not found (DNS/mDNS)" ;;
    "") echo "unreachable" ;;
    *)  echo "unreachable ($(printf '%s' "$NR_SSH_LAST_ERR" | head -1))" ;;
  esac
}

# --- État des montages SSHFS (SANS jamais toucher le VFS) -----------------------
# `mount` (sans arg) liste juste la table déjà en mémoire, jamais d'I/O sur le FS monté -> aussi
# instantané que /proc/mounts, mais portable (macOS n'a pas de procfs, /proc/mounts y est vide).
is_mounted() { mount 2>/dev/null | grep -qF " on $1 "; }

# nr_regex_escape : échappe les métacaractères ERE d'un chemin pour pgrep/pkill -f.
nr_regex_escape() { printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|/]/\\&/g'; }

# sshfs_daemon_alive <mnt> : le process sshfs qui sert ce mount est-il vivant ?
# pgrep -f => match sur la ligne de commande complète (sshfs user@ip:/remote <mnt> -o ...).
sshfs_daemon_alive() {
  local m; m="$(nr_regex_escape "$1")"
  pgrep -f "sshfs([^|]* )$m( |$)" >/dev/null 2>&1
}

# mount_responsive <mnt> : le mount RÉPOND-il vraiment (pas EIO / wedgé) ? Sonde `stat` en
# ARRIÈRE-PLAN, n'attend que ~4 s -> ne se FIGE JAMAIS, même si le FUSE est wedgé (la sonde reste
# alors en D-state ; elle meurt quand nr_lazy_unmount tue le daemon). Vrai = stat OK dans les temps.
mount_responsive() {
  local p i=0
  stat "$1" >/dev/null 2>&1 & p=$!
  while [ "$i" -lt 4 ]; do
    kill -0 "$p" 2>/dev/null || { wait "$p"; return $?; }
    sleep 1; i=$((i + 1))
  done
  return 1   # toujours bloqué après ~4 s -> wedgé
}

# mount_healthy <mnt> : présent dans /proc/mounts ET daemon vivant ET RÉACTIF. Détecte à la fois
# l'endpoint FUSE mort (daemon disparu) ET le daemon WEDGÉ (vivant mais bloqué en I/O, ex. tunnel
# inverse tombé + reconnect qui boucle) — ce dernier passait le test daemon-vivant seul.
mount_healthy() { is_mounted "$1" && sshfs_daemon_alive "$1" && mount_responsive "$1"; }

# nr_lazy_unmount <mnt> : tue le daemon sshfs (SIGKILL — un daemon WEDGÉ ignore SIGTERM ; sa mort
# débloque les I/O en D-state -> ENOTCONN) PUIS détache le mount (lazy). Ordre important : tuer AVANT
# de démonter, sinon fusermount peut se figer sur un endpoint vivant-mais-bloqué.
nr_lazy_unmount() {
  local mnt="$1" m
  m="$(nr_regex_escape "$mnt")"
  pkill -KILL -f "sshfs([^|]* )$m( |$)" 2>/dev/null || true
  # fusermount(3) -uz : lazy unmount Linux. macOS n'a ni fusermount ni `umount -l` (BSD) -> repli
  # `umount -f` (force), qui marche des deux côtés pour un mount FUSE/macFUSE déjà mort.
  fusermount -uz "$mnt" 2>/dev/null || fusermount3 -uz "$mnt" 2>/dev/null \
    || umount -l "$mnt" 2>/dev/null || umount -f "$mnt" 2>/dev/null || true
}

# --- mounts.tsv : mutations sérialisées (flock) + atomiques (mktemp+mv) -----
# nr_mounts_lock : prend un verrou exclusif tenu jusqu'à la fin du process appelant (fd 9).
# À appeler UNE FOIS avant toute mutation. Deux process concurrents ne peuvent plus s'entrelacer
# sur le même fichier temporaire.
nr_mounts_lock() {
  mkdir -p "$(dirname "$MOUNTS")" 2>/dev/null || true
  exec 9>"${MOUNTS}.lock" || return 0
  flock 9 2>/dev/null || true
}

# nr_tsv_remove <mnt> : retire l'entrée du mount (atomique).
nr_tsv_remove() {
  [ -f "$MOUNTS" ] || return 0
  local tmp; tmp="$(mktemp "${MOUNTS}.XXXXXX")" || return 1
  awk -F'\t' -v m="$1" '$1!=m' "$MOUNTS" 2>/dev/null > "$tmp"
  mv "$tmp" "$MOUNTS"
}

# nr_tsv_upsert <mnt> <host> <remote> <ssh_record> : remplace/ajoute l'entrée (atomique).
nr_tsv_upsert() {
  mkdir -p "$(dirname "$MOUNTS")" 2>/dev/null || true
  [ -f "$MOUNTS" ] || : > "$MOUNTS"
  local tmp; tmp="$(mktemp "${MOUNTS}.XXXXXX")" || return 1
  awk -F'\t' -v m="$1" '$1!=m' "$MOUNTS" 2>/dev/null > "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$tmp"
  mv "$tmp" "$MOUNTS"
}

# --- Log avec rotation simple --------------------------------------------
# nr_log_rotate <fichier> [max_octets] : tronque en gardant la fin si le log dépasse la taille.
nr_log_rotate() {
  local f="$1" max="${2:-5242880}" sz
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  if [ "$sz" -gt "$max" ] 2>/dev/null; then
    tail -c "$((max/2))" "$f" > "$f.rot" 2>/dev/null && mv "$f.rot" "$f" 2>/dev/null || true
  fi
}
