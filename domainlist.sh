#!/usr/bin/env bash
set -euo pipefail

OUT="/opt/sniproxy/domainlist.csv"
TMP="$(mktemp)"

URLS=(
  "https://cdn.jsdelivr.net/gh/VPSDance/ai-proxy-rules@main/rules/surge/all.list"
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/netflix.list"
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/tiktok.list"
)

> "$TMP"

for url in "${URLS[@]}"; do
    echo "Fetching $url"

    curl -fsSL "$url" |
    sed 's/\r$//' |
    awk -F, '
    /^[[:space:]]*$/ { next }
    /^#/ { next }
    /^\/\// { next }

    # MetaCubeX：+.example.com -> example.com,suffix
    /^\+\./ {
        d=$0
        sub(/^\+\./, "", d)
        print d ",suffix"
        next
    }


    $1=="DOMAIN" {
        print $2 ",fqdn"
        next
    }

    $1=="DOMAIN-SUFFIX" {
        print $2 ",suffix"
        next
    }

    $1=="DOMAIN-WILDCARD" {
        print $2 ",suffix"
        next
    }


    $1=="DOMAIN-KEYWORD" { next }
    $1 ~ /^IP-/ { next }


    /^[A-Za-z0-9._-]+$/ {
        print $0 ",fqdn"
        next
    }
    ' >> "$TMP"
done

sort -u "$TMP" -o "$TMP"

if grep -qvE '^[A-Za-z0-9._-]+,(prefix|suffix|fqdn)$' "$TMP"; then
    echo "Invalid rule found:" >&2
    grep -vE '^[A-Za-z0-9._-]+,(prefix|suffix|fqdn)$' "$TMP" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$OUT"

echo "Generated: $OUT"
echo "Total rules: $(wc -l < "$OUT")"
