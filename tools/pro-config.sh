#!/bin/zsh
# For build.sh: tools/pro-config.sh PUBLIC_KEY ISSUED_FILE OUT
# Writes OUT, a copy of Sources/ProConfig.swift with Swoopy Pro's check data filled in: the public half of the
# owner's signing key pair (64 hex characters), and the fingerprints of the older 25-character keys listed in
# ISSUED_FILE (issued.txt: "date  name  key" per line), each the SHA-256 of "PSPRO-OLD:" + the key (capitals, no
# dashes). Must match Sources/Pro.swift (ProKey.oldFingerprint). A missing ISSUED_FILE = no older keys.
# Prints only how many older keys were found, never the keys.
set -e
cd "${0:A:h}/.."
public=$1 issued=$2 out=$3
[[ $public =~ ^[0-9a-f]{64}$ ]] || { echo "Swoopy Pro: the public key must be 64 hex characters (signing-public.txt)" >&2; exit 1; }
[[ -n $out ]] || { echo "Use: tools/pro-config.sh PUBLIC_KEY ISSUED_FILE OUT" >&2; exit 1; }
fingerprints=()
if [[ -n $issued && -f $issued ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    words=(${=line})
    (( ${#words} )) || continue
    key=${words[-1]:u}
    key=${key//[^A-Z0-9]/}
    [[ ${#key} == 25 ]] || continue
    fingerprints+=("$(printf 'PSPRO-OLD:%s' $key | shasum -a 256 | cut -c1-64)")
  done < "$issued"
fi
fingerprints=(${(u)fingerprints})  # each once
list=""
for f in $fingerprints; do list+="\"$f\", "; done
list=${list%, }
awk -v public="$public" -v list="$list" '
  /static let publicKey = ""/ { sub(/""/, "\"" public "\""); print; found1 = 1; next }
  /static let oldKeys: \[String\] = \[\]/ { sub(/= \[\]/, "= [" list "]"); print; found2 = 1; next }
  { print }
  END { if (!found1 || !found2) exit 1 }
' Sources/ProConfig.swift > "$out" || { echo "Couldn't fill in $out from Sources/ProConfig.swift" >&2; exit 1; }
grep -q "publicKey = \"$public\"" "$out" || { echo "Couldn't put the public key into $out" >&2; exit 1; }
echo "${#fingerprints}"
