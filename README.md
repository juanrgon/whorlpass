# whorlpass

A tiny macOS command-line tool that keeps a password on one Mac and unlocks it with Touch ID. Press Control+Option+Command+P, touch the sensor, and the password is on your clipboard for 30 seconds.

It is one Swift file with no dependencies.

## How it works

- The first time you store a secret, whorlpass creates a P-256 key inside the Secure Enclave. The key requires Touch ID for every use (`.biometryAny`) and is only usable while the Mac is unlocked (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- Each secret is encrypted to that key (ephemeral P-256 key agreement, HKDF-SHA256, AES-GCM) and saved in `~/.local/share/whorlpass/secrets/`.
- The private key never leaves the Secure Enclave. The encrypted files and the key file are useless on any other Mac.
- Copied passwords are marked with the `org.nspasteboard.ConcealedType` and `TransientType` types, so well-behaved clipboard managers skip them. The clipboard is cleared after 30 seconds unless you copied something else in the meantime.

## Requirements

- A Mac with a Secure Enclave (Apple silicon or T2) and Touch ID set up
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```sh
git clone https://github.com/juanrgon/whorlpass.git
cd whorlpass
./install.sh
```

This builds `~/.local/bin/whorlpass` and starts a LaunchAgent (`com.whorlpass.agent`) that listens for the hotkey. Use `./install.sh --no-agent` to skip the hotkey, or set `PREFIX` to install somewhere else.

Then store your password:

```sh
whorlpass set
```

## Usage

| Command | What it does |
| --- | --- |
| `whorlpass set [name]` | Store a secret. Prompts twice, or reads from stdin. |
| `whorlpass get [name]` | Print a secret after Touch ID. |
| `whorlpass copy [name]` | Copy a secret to the clipboard for 30 seconds after Touch ID. |
| `whorlpass list` | List stored names. |
| `whorlpass rm <name>` | Delete a secret. |

The name defaults to `default`. The hotkey always copies `default`.

After the hotkey, a "Tink" sound means the password was copied. A "Basso" sound means Touch ID was cancelled or there is no secret named `default`. Details go to `~/.local/share/whorlpass/agent.log`.

## Limits and threat model

whorlpass protects a secret from someone who copies your files, steals a backup, or gets at your Mac while it is locked. It is not a password manager, and it does not protect you from everything.

- **No backup or recovery.** If you wipe or replace the Mac, the secret is gone. Keep the real password somewhere else too.
- **No password fallback.** If Touch ID is unavailable, so is the secret. With the lid closed you need a keyboard with Touch ID.
- **New fingerprints work.** The key uses `.biometryAny`, so a fingerprint added later can also unlock it. Anyone who knows your login password can add one.
- **Malware running as you is out of scope.** The binary and LaunchAgent live in folders you can write to. Malware could replace them with a version that shows a real Touch ID prompt and then keeps the password.
- **The clipboard is shared.** Any app can read the clipboard during those 30 seconds.
- **`rm` does not ask for Touch ID.** Anything running as you can delete a secret.

## Uninstall

```sh
./uninstall.sh
```

This stops the agent and removes the command. Your key and secrets stay in `~/.local/share/whorlpass` until you delete that folder.

## License

MIT
