#!/usr/bin/env bash

set -euo pipefail

INPUT="${1:-urls.txt}"
OUT="report_pretty.csv"
TIMEOUT="${TIMEOUT:-12}"
UA="${UA:-OSParser/1.0}"

# Format value for CSV output
csv() {
  local s="${1//\"/\"\"}"
  s="${s//$'\n'/ }"
  printf "\"%s\"" "$s"
}

# Calculate security grade
grade() {
  local final_url="$1" code="$2" hsts="$3" csp="$4"
  local score=100 reasons=()

  [[ "$final_url" != https://* ]] && score=$((score-60)) && reasons+=("No HTTPS")
  [[ "$code" == "000" ]] && score=$((score-40)) && reasons+=("No response")
  (( code >= 400 )) && score=$((score-30)) && reasons+=("HTTP $code")
  [[ "$hsts" == "no" ]] && score=$((score-10)) && reasons+=("No HSTS")
  [[ "$csp"  == "no" ]] && score=$((score-10)) && reasons+=("No CSP")

  local g
  (( score >= 80 )) && g="SAFE-ish" || (( score >= 50 )) && g="MEDIUM" || g="RISK"

  local r
  [[ ${#reasons[@]} -eq 0 ]] && r="OK" || r="$(IFS='; '; echo "${reasons[*]}")"

  printf "%s\t%s\t%s" "$g" "$score" "$r"
}

# Create CSV report
echo "\"url\",\"final_url\",\"http_code\",\"redirects\",\"grade\",\"score\",\"reasons\"" > "$OUT"

echo "URL                           CODE  GRADE     SCORE  REASONS"
echo "------------------------------------------------------------"

# Read input file line by line
while IFS= read -r raw; do

  # Skip empty lines and comments
  [[ -z "${raw// /}" || "$raw" == \#* ]] && continue

  # Add HTTPS if protocol is missing
  [[ "$raw" != *"://"* ]] && raw="https://$raw"

  # Get response info
  meta="$(curl -L -A "$UA" --max-time "$TIMEOUT" -sS -o /dev/null \
    -w "%{http_code}\t%{num_redirects}\t%{url_effective}" "$raw" 2>/dev/null || \
    echo -e "000\t0\t$raw")"

  IFS=$'\t' read -r code redirects final_url <<<"$meta"

  # Download headers
  headers="$(curl -I -L -A "$UA" --max-time "$TIMEOUT" -sS "$final_url" 2>/dev/null | tr -d '\r')"

  # Check security headers
  echo "$headers" | grep -qi '^Strict-Transport-Security:' && hsts="yes" || hsts="no"
  echo "$headers" | grep -qi '^Content-Security-Policy:' && csp="yes" || csp="no"

  # Generate grade
  IFS=$'\t' read -r g sc rs <<<"$(grade "$final_url" "$code" "$hsts" "$csp")"

  # Print formatted result
  printf "%-28s  %-4s  %-8s  %-5s  %s\n" \
    "$(echo "$raw" | sed -E 's#https?://##; s#/.*##')" \
    "$code" "$g" "$sc" "$rs"

  # Save CSV row
  {
    csv "$raw"; printf ","
    csv "$final_url"; printf ","
    csv "$code"; printf ","
    csv "$redirects"; printf ","
    csv "$g"; printf ","
    csv "$sc"; printf ","
    csv "$rs"
    printf "\n"
  } >> "$OUT"

done < "$INPUT"

echo
echo "Done: $OUT"
