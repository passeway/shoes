#!/usr/bin/env bash
set -euo pipefail

OUT="${OUT:-/opt/sniproxy/domainlist.csv}"
URLS=(
  'https://cdn.jsdelivr.net/gh/VPSDance/ai-proxy-rules@main/rules/surge/all.list'
  'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/netflix.list'
  'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/tiktok.list'
)

for command in curl awk sort mktemp; do
  command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
mkdir -p -- "$(dirname -- "$OUT")"
WORK_DIR=$(mktemp -d "$(dirname -- "$OUT")/.domainlist.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
: > "$WORK_DIR/all"

for url in "${URLS[@]}"; do
  echo "Fetching $url"
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 \
    --max-time 60 --retry 2 "$url" -o "$WORK_DIR/source"
  awk -F, '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function emit(d, kind, labels, n, i) {
      d=tolower(trim(d))
      if (d !~ /^[a-z0-9_.-]+$/ || d ~ /\.\./) { bad=1; return }
      # A boundary dot is intentional for wildcard prefix/suffix rules.
      n=split(d, labels, ".")
      for (i=1; i<=n; i++) {
        if ((i==1 || i==n) && labels[i]=="" && kind!="fqdn") continue
        if (labels[i] !~ /^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?$/ || length(labels[i])>63) { bad=1; return }
      }
      if (length(d)>253 || d==".") { bad=1; return }
      print d "," kind
    }
    {
      sub(/\r$/, ""); $0=trim($0)
      if ($0=="" || $0 ~ /^(#|\/\/)/) next
      if ($0 ~ /^\+\./) { emit(substr($0,3),"suffix"); next }
      if ($1=="DOMAIN") { emit($2,"fqdn"); next }
      if ($1=="DOMAIN-SUFFIX") { emit($2,"suffix"); next }
      if ($1=="DOMAIN-WILDCARD") {
        d=trim($2)
        if (d ~ /^\*\.[A-Za-z0-9_.-]+$/) emit(substr(d,2),"suffix")
        else if (d ~ /^[A-Za-z0-9_.-]+\.\*$/) emit(substr(d,1,length(d)-1),"prefix")
        else { print "Unsupported wildcard: " d > "/dev/stderr"; bad=1 }
        next
      }
      if ($1=="DOMAIN-KEYWORD" || $1 ~ /^IP-/) next
      if ($0 ~ /^[A-Za-z0-9_.-]+$/) emit($0,"fqdn")
    }
    END { if (bad) { print "Invalid domain rule; original output retained." > "/dev/stderr"; exit 1 } }
  ' "$WORK_DIR/source" > "$WORK_DIR/parsed"
  if [[ ! -s "$WORK_DIR/parsed" ]]; then
    echo "No usable rules from $url; original output retained." >&2
    exit 1
  fi
  cat "$WORK_DIR/parsed" >> "$WORK_DIR/all"
done
LC_ALL=C sort -u "$WORK_DIR/all" > "$WORK_DIR/result"
[[ -s "$WORK_DIR/result" ]]
chmod 644 "$WORK_DIR/result"
# The staging directory is on the destination filesystem, so replacement is atomic.
mv -f -- "$WORK_DIR/result" "$OUT"
echo "Generated: $OUT"
echo "Total rules: $(wc -l < "$OUT")"
