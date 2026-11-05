#!/bin/bash
# Swoopy Pro keys, for the owner. People email for a key; this makes one, and you email it back.
#
#   tools/pro-keys.sh new "their name or email"   makes a key (it unlocks one Mac), prints it, adds it to the list
#   tools/pro-keys.sh list                         every key made so far (date, name, key)
#   tools/pro-keys.sh check KEY                    says whether a key works, whether it was used, and who it was for
#   tools/pro-keys.sh server-setup                 makes the key server's secrets, once (done 2026-11-03)
#   tools/pro-keys.sh setup                        makes the older signed keys' key pair, once (done 2026-10-19)
#
# A key is 20 characters (XXXXX-XXXXX-XXXXX-XXXXX). It's made from server-secret.txt in
# ~/Library/Application Support/Pitch Shift Keys (only you can read it); the key server (server/) has the same
# secret. When someone enters a key, Swoopy sends it to the server once: the first Mac gets it, every other Mac is
# refused. "new" asks the server whether the new key is good and unused before printing it (it needs the internet for
# that; without it, it says so and the key is still good). Never put the Pitch Shift Keys folder in git or send it to
# anyone: anyone with server-secret.txt can make keys. Keep a copy of the whole folder somewhere safe (a USB stick).
# The list of keys made is issued.txt in the same folder; build.sh also uses it so the keys sent out before
# 2026-11-03 (checked on the Mac alone, with signing-public.txt) keep working.
#
# Spaces, dashes and line breaks don't matter when a key is pasted. Checks only: "test [FILE]" checks the fixed
# examples in tools/pro-keys-test.txt (the app checks the same file with --pro-test, the server with npm test).
# PITCH_SHIFT_KEYS_DIR=/some/folder uses another folder instead of the real one, SWOOPY_PRO_SERVER=URL another server.
# Needs only what's on this Mac (bash and the Swift of the Command Line Tools); the work is done by pro-keys.swift.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ -f $here/pro-keys.swift ]] || { echo "pro-keys.swift must be next to this script ($here)" >&2; exit 1; }
if [[ ${1:-} == test && -z ${2:-} ]]; then set -- test "$here/pro-keys-test.txt"; fi
exec /usr/bin/swift "$here/pro-keys.swift" "$@"
