// Swoopy Pro: where to ask for a key, the price, and what keys are checked with.
// The check data is never in git: build.sh puts it in at build time (tools/pro-config.sh), from PRO_PUBLIC_KEY or
// ~/Library/Application Support/Pitch Shift Keys/signing-public.txt (made by tools/pro-keys.sh setup on the owner's
// Mac), and from issued.txt in the same folder (or PRO_ISSUED) for the older keys.
// With publicKey empty, nothing is locked and there is no Unlock button (a build from the public code just works).
enum ProConfig {
    // The public half of the owner's signing key pair (64 hex characters): it checks keys but can't make them.
    static let publicKey = ""  // filled in by build.sh; leave empty here
    // Fingerprints (SHA-256, hex) of the older 25-character keys sent out before signed keys: those still work.
    static let oldKeys: [String] = []  // filled in by build.sh; leave empty here
    static let email = "cbsweetland@gmail.com"  // people email this address for a key
    static let price = "$5"
}
