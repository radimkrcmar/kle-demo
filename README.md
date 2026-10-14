# Zkl (KLE) prototype: QEMU + Linux + OpenSSL, AES only

A minimal implementation of the RISC-V Cryptographic Lockers extension,
KLE ([riscv/riscv-high-assurance-cryptography](https://github.com/riscv/riscv-high-assurance-cryptography)
at c6ada5683d69, a development draft after Zkl v0.6), to check that the
design works end to end, with OpenSSL as the consumer.  All of it is an
experiment; nothing is intended for upstream as is.

## Trees (branch `zkl` everywhere)

| Tree | What |
|---|---|
| [radimkrcmar/qemu](https://github.com/radimkrcmar/qemu/tree/zkl) | `target/riscv`: the KLE unit (`tcg/zkl_helper.c`: AES ECB, CTR and GCM Machines), CSRs, KLS, Smklstatus and Ssklstatus, exceptions; bare-metal `tests/tcg/riscv64/test-zkl.c`, checked against the spec's KAT models |
| [radimkrcmar/linux](https://github.com/radimkrcmar/linux/tree/zkl) | `arch/riscv/kernel/kle.c`: per-task lockers, saved and restored across context switches, first-use enable, per-process SLocality, hwprobe; selftest `tools/testing/selftests/riscv/zkl` |
| [radimkrcmar/openssl](https://github.com/radimkrcmar/openssl/tree/zkl) | `include/crypto/riscv_kle.h`; the default provider puts AES keys in lockers transparently (`cipher_aes_hw_kle.c`); the `kle` provider (`enable-kle`) offers EVP_SKEY keys that never leave the unit, and AES-GCM on the GCM Machine; `test/kle_test.c`, `demos/kle/kle-https.c` |

## Running

```sh
F=github:radimkrcmar/kle-demo                    # or . in a clone
nix run $F                                       # boot Linux, run all guest tests ($F#test)
nix run $F#https [-- host|localhost]             # HTTPS from the guest, checked to use the kle provider
nix run $F#provision [-- message]                # a key sealed on the host decrypts a message in the guest
nix run $F#seal -- --csk HEX --key HEX > key.scc # the sealer alone: the spec's model
nix run $F#vm                                    # interactive shell in the guest
nix build $F#checks.x86_64-linux.vm-test         # the test boots, as a check
nix build $F#checks.x86_64-linux.vectors         # QEMU's test vectors match the pinned spec
nix build $F#checks.x86_64-linux.seal            # the sealer reproduces the spec's vector
nix build $F#checks.x86_64-linux.provision       # the provisioning demo with fixed inputs
nix build $F#qemu                                # QEMU alone, with its riscv64 tcg suite (test-zkl)
nix develop $F#linux                             # cross kernel build environment
```

Everything is cross-compiled from x86_64-linux; the first build takes a
while (QEMU with its tcg tests, a kernel and OpenSSL).  `flake.lock` pins
a commit of each `zkl` branch and of the spec.  To build a local tree
instead, override its input with a committed ref, e.g.
`--override-input qemu-src 'git+file:///path/to/qemu?ref=zkl&shallow=1'`.

`nix run` boots the guest twice.  The first boot has every Machine and
runs the kernel selftest `zkl_test`, `/bin/openssl-tests` (`kle_test`,
OpenSSL's AES KATs through the default provider and through the kle
provider, `openssl enc` cross-checks) and `/bin/tls-tests` (TLS 1.2 and
1.3 over loopback between `openssl s_server` and `kle-https`, then a
record with one bit flipped, each way).  The second boot has only the ECB
Machines (`x-zkl-ctr=false,x-zkl-gcm=false`) and runs the OpenSSL and TLS
tests again: AES-CTR and the default provider's AES-GCM go over ECB, and
the kle provider has no AES-GCM.

`nix run .#https` gives the guest a network and fetches
https://openssl-conference.org/ with `kle-https`, through the default
provider and with `--kle`, then once more each way with one bit of the
server's first record flipped (`--tamper`).  It checks the lockers as the
unit reports them: with `--kle` the record keys are in two AES-GCM lockers
of the kle provider, encrypt-only and decrypt-only, in _Success_ after the
response, and the decrypt-only one in _Failure_ after the flip, so the
Machine checked the tag; through the default provider no locker is in
_Failure_, since GHASH runs in software.  With `localhost` as the host
the page comes from `openssl s_server` in the guest, so the demo needs no
network.  The firmware and kernel boot is held back unless
`KLE_VERBOSE=1`.

`nix run .#provision [-- message]` has the host play the key server.  It
draws a CSK, an AES-256 key and an IV (or takes `KLE_CSK`, `KLE_KEY` and
`KLE_IV`), seals the key into a decrypt-only SCC with the spec's own
model (`src/kat/scc-kat.py`, run by `kle-seal`), encrypts the message (by
default `Hello, OpenSSL 2026!`) with `openssl enc -aes-256-cbc`, and
forgets the key.  QEMU gets the CSK (`x-zkl-csk`), and the guest gets
`scc` and `message.enc` (the IV, then the ciphertext) in `/etc/kle-demo`,
where `/bin/scc-demo` runs as a console session: it shows both files
with `xxd`, decodes the SCC's MDH and decrypts with nothing else:

```sh
tail -c +17 message.enc | openssl enc -d -aes-256-cbc -provider kle -skeyuri kle:scc \
  -iv $(head -c 16 message.enc | xxd -p)
```

The URI `kle:scc` names the SCC file for the kle provider's store, which
loads it as an AES key of the kle provider: the key brings its provider
along, so no `-skeymgmt`, `-skeyopt` or `-propquery` is needed.  The unit
unseals it when the cipher is set up, and the message is checked against
the sender's sha256.  Then what the SCC does not allow: encrypting with
it fails, as its MDH says decrypt only, and so does an import with one
bit of the SCC flipped.  A second boot, a unit with a random CSK of its
own, cannot import it at all.  The SCC names no Locality, so it imports
on any unit with that CSK.  The sealer alone is
`nix run .#seal -- --csk HEX --key HEX [--policy enc|dec|both] [--usage HEX] [--hex]`.

QEMU CPU: `-cpu max,x-zkl=true[,x-zkl-csk-random=true|,x-zkl-csk=<64 hex>][,x-zkl-ctr=false][,x-zkl-gcm=false][,x-zkl-status=false]`.
Without `x-zkl-csk-random` (a CSK drawn at power-on) or `x-zkl-csk` (the
CSK given, byte 0 first; `mklcsk` is illegal with either) the CSK must be
programmed by M-mode through `mklcsk`; the other flags leave out the AES
CTR Machines, the AES-GCM Machines and the per-locker status CSRs.

Linux: `kle.status=N` selects what a context switch saves and restores
when the hart has Ssklstatus: `0` every locker, `1` only the Dirty ones,
`2` also leaves the saved lockers Off at a switch-in, to import each on
its first use, and `3` (the default) imports at the switch-in those the
task used in two time slices in a row.  What the switches moved is in
`/sys/kernel/debug/riscv_kle/stats` (a write resets it), and
`zkl_test --bench N idle|use|change|first|all` holds N lockers through
1 ms sleeps for two seconds.

## Using KLE from OpenSSL

```c
/* A key that never exists outside the KLE unit; keep only its SCC. */
size_t len = 32;                        /* bytes: AES-256 */
OSSL_PARAM p[] = { OSSL_PARAM_size_t("key-length", &len), OSSL_PARAM_END };
EVP_SKEY *k = EVP_SKEY_generate(libctx, "AES", "provider=kle", p);
EVP_SKEY_export(k, OSSL_SKEYMGMT_SELECT_SECRET_KEY, cb, arg); /* "kle-scc" */
EVP_CipherInit_SKEY(ctx, EVP_CIPHER_fetch(libctx, "AES-256-CTR", "provider=kle"),
                    k, iv, 16, 1, NULL);
```

`EVP_SKEY_import` takes `raw-bytes` (provisioned, then forgotten) or
`kle-scc`; `kle-binding` is `device` (default) or `process`.  Raw keys
used with the default provider on a KLE hart go into lockers
automatically (ECB, CBC, CTR, GCM); `OPENSSL_riscvcap=rv64gcv` turns that
off.  When such a key finds no locker, at key setup or at any later use,
the default provider continues in software AES; the kle provider fails.
Every instruction names its locker through `KLNL`, so the library needs
no switch of immediates.  The two providers share one per-thread locker
table in libcrypto; a forked child's table is emptied by an atfork
handler.  AES-CTR with a raw key runs on the CTR Machine if the unit has
one, else as counter blocks, built in vector registers, on the ECB
Machine; EVP_SKEY keys are ECB keys, so their CTR always goes over ECB.

AES-GCM, and with it TLS, takes lockers two ways.  The default provider
runs GCM's AES on the CTR Machine (else ECB counter blocks) with GHASH in
software, so H is in memory, as is the raw key for the fallback.  The kle
provider runs all of GCM on the AES-GCM Machine, when the unit has one:
nothing but the SCC is in memory, a key is encrypt-only or decrypt-only as
its context, decryption tags must be 16 bytes, and text updates must be
whole blocks but the last one.  libssl uses the kle provider's through a
property query:

```c
OSSL_PROVIDER_load(NULL, "default");
OSSL_PROVIDER_load(NULL, "kle");
SSL_CTX *ctx = SSL_CTX_new_ex(NULL, "?provider=kle", TLS_client_method());
```

`demos/kle/kle-https [--kle] [--tamper] [host]` does that with `--kle`,
and lists the lockers of its thread before the connection, then those
that changed after the handshake, the response and `SSL_free` (`--all`:
every locker each time).

## Provisional allocations (the spec leaves them TBD)

| Item | Value |
|---|---|
| Opcodes | as Zkl-ISA-unpriv.adoc: MISC-MEM funct3 3 (`kl.setst`/`kl.mgmt`/`kl.setnl(i)`) and 4 (`kl.exec` group with `kl.mvin`/`kl.mvout`, `kl.size`, `kl.getmd*`/`kl.getnl`), LOAD funct3 7 (`kl.load`), STORE funct3 5 (`kl.store`) |
| `misa.L`, `KLS` | bit 11; `mstatus`/`sstatus`[26:25] |
| CSRs | `klstart` 0x800, `klnamedlocker` 0x801, ID CSRs 0xCC0-0xCC3, `skllocality0/1` 0x5E0/0x5E1, `mklcsk0-3` 0xBC0-0xBC3, `mkllocality0/1` 0xBC4/5, `mklphysbootscrt0/1` 0xBC6/7, `sllockerstatus` 0x5E2, `mllockerstatus` 0xBC8 (direct, not Smcsrind) |
| Causes | 24 fatal-error, 25 missing-CSK, 26 locker-Off (forwarded by OpenSBI's default redirect), 27 unsupported-Metadata, 28 privilege-violation, 29 out-of-memory, 30 RBG-unavailable, 31 clock-unavailable (24, 29, 30 and 31 are never raised); tval 0; none delegable, as the spec requires |
| hwprobe | `RISCV_HWPROBE_KEY_IMA_EXT_1` bit 6 (Zkl) |
| ISA string | `smklstatus`, `ssklstatus` in `riscv,isa`, as the spec's extension table names them |
| ChipFamScrt / DevScrt | `"QEMU-ZKL-CHIPFAM"` / random per QEMU process |

## Scope

Implemented: AES128/192/256_ECB, AES128/192/256_CTR and AES128/192/256_GCM
Machines (SCProtection Level A); `kl.mgmt` (all paths incl. nested PI/SCC
states and Error-State transfer), `kl.setst` and pseudo-instructions,
`kl.exec` A-C, `kl.mvin`/`kl.mvout` (GPR and vector variants),
`kl.load`/`kl.store`, `kl.getmd*`, `kl.size`/`kl.avail`, `KLNL` (wherever
a locker is named but `kl.clearall`), `kl.getnl`/`kl.setnl`/`kl.setnli`;
SCC sealing with Localities; KeyType 1 with the all-ones SKID; `misa.L`,
KLS, `mklcsk`, Locality CSRs, Smklstatus and Ssklstatus (`mllockerstatus`,
`sllockerstatus` and the KLE locker-Off exception), KLE exceptions,
UsagePolicy; QEMU migrates the unit's state (VMState).

Not implemented (so not conforming): Zklio (the KLIOBUF, `kl.input`/
`kl.output` and the substitutions), Zklexpire, `kl.restrict*`,
`kl.clone`/`rename`/`swap`, `kl.derive`, H-extension parts (with
`vsllockerstatus`), Smstateen, Debug mode, M-mode writes to the
identification CSRs, other Machines (GCM with Set IV among them),
SCProtection Levels B and C, RV32.

## License

This repository is under the MIT License ([LICENSE](LICENSE)).  The
QEMU, Linux and OpenSSL trees keep their own.
