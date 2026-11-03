#!/bin/bash
# Swoopy Pro keys, for the owner. People email for a key; this makes one, and you email it back.
#
#   tools/pro-keys.sh setup                        makes your key pair, once (never replaces one that's there)
#   tools/pro-keys.sh new "their name or email"   makes a key, prints it, and adds it to the list
#   tools/pro-keys.sh list                         every key made so far (date, name, key)
#   tools/pro-keys.sh check KEY                    says whether a key works, and who it was made for
#
# Keys are signed: the private half of your key pair (signing-private.txt) makes them, and the app holds only the
# public half (signing-public.txt, built in by build.sh), which can check keys but can't make them. Both live in
# ~/Library/Application Support/Pitch Shift Keys (only you can read it). Never put signing-private.txt in git or send it
# to anyone: anyone with it can make keys. Keep a copy of the whole folder somewhere safe (a USB stick): without
# signing-private.txt no more keys can be made for the app, and a new pair would make every key already sent out stop
# working. The list of keys made is issued.txt in the same folder; build.sh also uses it so the older 25-character
# keys sent out before signed keys keep working.
#
# A key is 115 characters (shown in groups of 5, 6 groups per line); spaces, dashes and line breaks don't matter when
# it's pasted. Checks only: "test [FILE]" checks the fixed examples in tools/pro-keys-test.txt (the app checks the same
# file with --pro-test). PITCH_SHIFT_KEYS_DIR=/some/folder uses another folder instead of the real one.
# Needs only what's on this Mac (bash and the Swift of the Command Line Tools); the work is done by pro-keys.swift.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ -f $here/pro-keys.swift ]] || { echo "pro-keys.swift must be next to this script ($here)" >&2; exit 1; }
if [[ ${1:-} == test && -z ${2:-} ]]; then set -- test "$here/pro-keys-test.txt"; fi
exec /usr/bin/swift "$here/pro-keys.swift" "$@"
