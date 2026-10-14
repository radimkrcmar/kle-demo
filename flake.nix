{
  description = "Zkl (KLE crypto lockers) prototype: QEMU + Linux + OpenSSL, AES (ECB, CTR, GCM)";

  inputs = {
    nixpkgs.url = "nixpkgs";
    # The zkl branches of the forks, and the specification.  To build a
    # local tree instead, override its input with a committed ref:
    #   --override-input qemu-src 'git+file:///path/to/qemu?ref=zkl&shallow=1'
    qemu-src = { url = "github:radimkrcmar/qemu/zkl"; flake = false; };
    linux-src = { url = "github:radimkrcmar/linux/zkl"; flake = false; };
    openssl-src = { url = "github:radimkrcmar/openssl/zkl"; flake = false; };
    spec-src = { url = "github:riscv/riscv-high-assurance-cryptography"; flake = false; };
  };

  outputs = { self, nixpkgs, qemu-src, linux-src, openssl-src, spec-src }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      cross = pkgs.pkgsCross.riscv64;
      crossStatic = cross.pkgsStatic;
      lib = pkgs.lib;

      # The unit with a CSK QEMU draws at boot; the provisioning demo gives
      # its own with x-zkl-csk instead.
      qemuBase = "max,x-zkl=true";
      qemuCpu = qemuBase + ",x-zkl-csk-random=true";

      # QEMU meson wrap-git subprojects (subprojects/*.wrap), with the
      # packagefiles overlays that meson would apply after downloading.
      qemuSubprojects = {
        keycodemapdb = pkgs.fetchgit {
          url = "https://gitlab.com/qemu-project/keycodemapdb.git";
          rev = "f5772a62ec52591ff6870b7e8ef32482371f22c6";
          hash = "sha256-EQrnBAXQhllbVCHpOsgREzYGncMUPEIoWFGnjo+hrH4=";
        };
        berkeley-softfloat-3 = pkgs.fetchgit {
          url = "https://gitlab.com/qemu-project/berkeley-softfloat-3.git";
          rev = "b64af41c3276f97f0e181920400ee056b9c88037";
          hash = "sha256-Yflpx+mjU8mD5biClNpdmon24EHg4aWBZszbOur5VEA=";
        };
        berkeley-testfloat-3 = pkgs.fetchgit {
          url = "https://gitlab.com/qemu-project/berkeley-testfloat-3.git";
          rev = "e7af9751d9f9fd3b47911f51a5cfd08af256a9ab";
          hash = "sha256-inQAeYlmuiRtZm37xK9ypBltCJ+ycyvIeIYZK8a+RYU=";
        };
      };

      qemu = pkgs.stdenv.mkDerivation {
        pname = "qemu-zkl";
        version = "11.1.50-zkl";
        src = qemu-src;
        nativeBuildInputs = with pkgs; [
          (python3.withPackages (ps: with ps; [ qemu-qmp setuptools wheel pip pycotap meson ]))
          ninja pkg-config flex bison perl
        ];
        # libslirp: -netdev user, for the guest's HTTPS demo.
        buildInputs = with pkgs; [ glib zlib dtc pixman libslirp ];
        dontUseNinjaBuild = true;
        dontUseNinjaInstall = true;
        postPatch = lib.concatStrings (lib.mapAttrsToList (name: src: ''
          rm -rf subprojects/${name}
          cp -r ${src} subprojects/${name}
          chmod -R u+w subprojects/${name}
          if [ -d subprojects/packagefiles/${name} ]; then
            cp -r subprojects/packagefiles/${name}/. subprojects/${name}/
          fi
        '') qemuSubprojects) + ''
          patchShebangs scripts tests/tcg tests/docker
        '';
        configureFlags = [
          "--target-list=riscv64-softmmu"
          "--disable-docs" "--disable-werror" "--disable-download"
          "--disable-rust" "--disable-user" "--disable-tools"
          "--disable-guest-agent" "--disable-capstone" "--disable-containers"
          "--cross-cc-riscv64=${cross.stdenv.cc}/bin/riscv64-unknown-linux-gnu-gcc"
        ];
        # The riscv64 bare-metal suite, including test-zkl.
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          meson test --print-errorlogs --suite tcg-riscv64-softmmu
          runHook postCheck
        '';
        preConfigure = "mkdir -p build && cd build";
        configureScript = "../configure";
        enableParallelBuilding = true;
        hardeningDisable = [ "all" ];
      };

      kernel = pkgs.stdenv.mkDerivation {
        pname = "linux-zkl";
        version = "7.3-zkl";
        src = linux-src;
        # pkgs.openssl: the let-bound openssl (the riscv64 build) shadows `with`.
        nativeBuildInputs = with pkgs; [ bc bison flex perl python3 pkgs.openssl elfutils cpio kmod ]
          ++ [ cross.stdenv.cc ];
        hardeningDisable = [ "all" ];
        makeFlags = [ "ARCH=riscv" "CROSS_COMPILE=riscv64-unknown-linux-gnu-" "O=build" ];
        postPatch = "patchShebangs scripts";
        configurePhase = ''
          make $makeFlags defconfig
          scripts/config --file build/.config -e RISCV_ISA_ZKL -e RISCV_ISA_V
          make $makeFlags olddefconfig
          grep -q CONFIG_RISCV_ISA_ZKL=y build/.config
        '';
        buildPhase = "make $makeFlags -j$NIX_BUILD_CORES Image";
        installPhase = ''
          install -D build/arch/riscv/boot/Image $out/Image
          install -D build/.config $out/config
        '';
      };

      selftest = crossStatic.stdenv.mkDerivation {
        pname = "zkl-selftest";
        version = "0";
        src = "${linux-src}/tools/testing/selftests/riscv/zkl";
        buildPhase = "$CC -static -O2 -march=rv64gcv -o zkl_test zkl_test.c -lpthread";
        installPhase = "install -D zkl_test $out/bin/zkl_test";
      };

      busybox = crossStatic.busybox;

      # QEMU's test-zkl vectors are generated from the pinned spec's KAT models.
      vectorsCheck = pkgs.runCommand "zkl-vectors-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        python3 -B ${qemu-src}/tests/tcg/riscv64/zkl-gen-vectors.py ${spec-src} > zkl-vectors.h
        diff -u ${qemu-src}/tests/tcg/riscv64/zkl-vectors.h zkl-vectors.h
        cp zkl-vectors.h $out
      '';

      # OpenSSL with the kle provider; the test programs and the AES test
      # data are kept to run in the guest.
      openssl = cross.stdenv.mkDerivation {
        pname = "openssl-zkl";
        version = "4.2.0-dev-zkl";
        src = openssl-src;
        nativeBuildInputs = [ pkgs.perl ];
        postPatch = "patchShebangs Configure config util test/*.pl";
        configurePhase = ''
          ./Configure linux64-riscv64 enable-kle no-docs \
            --prefix=$out --libdir=lib --openssldir=$out/etc/ssl
        '';
        enableParallelBuilding = true;
        installPhase = ''
          make install_sw install_ssldirs
          mkdir -p $out/libexec/tests $out/share/tests
          cp test/kle_test test/evp_test $out/libexec/tests/
          cp -L test/libtestutil* $out/lib/ 2>/dev/null || true
          cp test/recipes/30-test_evp_data/evpciph_aes_common.txt $out/share/tests/
          # The HTTPS demo, against the internal crypto/riscv_kle.h.
          $CC -O2 -Wall -Iinclude -o $out/bin/kle-https demos/kle/kle-https.c \
            -L$out/lib -Wl,-rpath,$out/lib -lssl -lcrypto
        '';
      };

      # A CA and a localhost server certificate for the guest's TLS tests.
      # Not OpenSSL's demos/guide ones: they name localhost only in the
      # subject CN, which OpenSSL no longer matches as a host name.
      testCerts = pkgs.runCommand "kle-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
        mkdir $out && cd $out
        openssl req -x509 -new -newkey rsa:2048 -nodes -keyout ca.key \
          -subj /CN=kle-test-ca -days 36500 -out ca.pem
        openssl req -new -newkey rsa:2048 -nodes -keyout server.key \
          -subj /CN=localhost -out server.csr
        printf 'subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n' > ext
        openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -days 36500 \
          -extfile ext -out server.pem
        rm ca.key server.csr ext
      '';

      # Seal an AES key into an SCC on the host, with the specification's own
      # model (src/kat/scc-kat.py), as zkl-gen-vectors.py does for QEMU's
      # test vectors: kle-seal --csk HEX --key HEX [--policy enc|dec|both]
      # [--usage HEX] [--hex].  The SCC names no Locality, so it depends on
      # the CSK, the MDH and the key alone.
      kleSealPy = pkgs.writeText "kle-seal.py" ''
        """Seal an AES key into an SCC under a CSK, off the device, with the Zkl
        specification's model of <<KLE-SCC-AEAD>> (src/kat/scc-kat.py).

        Usage: kle-seal --csk HEX --key HEX [--policy enc|dec|both] [--usage HEX] [--hex]
        The SCC (MDH, SIV, sealed key) goes to stdout, a decode of its MDH to stderr.
        """
        import argparse
        import contextlib
        import importlib.util
        import os
        import sys

        KAT = "${spec-src}/src/kat"
        sys.path.insert(0, KAT)


        def load(name):
            """Import a src/kat model; it runs its own KAT suite and exits with its verdict."""
            spec = importlib.util.spec_from_file_location(name.replace("-", "_"),
                                                          os.path.join(KAT, name + ".py"))
            mod = importlib.util.module_from_spec(spec)
            with open(os.devnull, "w") as devnull, contextlib.redirect_stdout(devnull):
                try:
                    spec.loader.exec_module(mod)
                except SystemExit as e:
                    if e.code:
                        sys.exit(f"{name}.py self-test failed")
            return mod


        scc = load("scc-kat")
        from common import b2v, v2b, mdh_pack  # noqa: E402

        MACHINE = {16: 0x000, 24: 0x010, 32: 0x020}       # AES128/192/256_ECB
        NAME = {0x000: "AES128_ECB", 0x010: "AES192_ECB", 0x020: "AES256_ECB"}
        POLICY = {"enc": 1, "dec": 2, "both": 3}
        POLICY_NAME = {1: "encrypt only", 2: "decrypt only", 3: "encrypt and decrypt"}


        def main():
            p = argparse.ArgumentParser(description=__doc__)
            p.add_argument("--csk", required=True, type=bytes.fromhex, help="32 bytes, hex")
            p.add_argument("--key", required=True, type=bytes.fromhex, help="16, 24 or 32 bytes, hex")
            p.add_argument("--policy", choices=POLICY, default="dec", help="MachinePolicy (dec)")
            p.add_argument("--usage", type=lambda s: int(s, 16), default=0xe,
                           help="UsagePolicy, hex: set bits deny U, VS, S, M (e: U-mode only)")
            p.add_argument("--hex", action="store_true", help="write the SCC in hex")
            a = p.parse_args()
            if len(a.csk) != 32:
                p.error("the CSK is 32 bytes")
            if len(a.key) not in MACHINE:
                p.error("the key is 16, 24 or 32 bytes")
            if not 0 <= a.usage < 32:
                p.error("UsagePolicy is 5 bits")
            mdh = mdh_pack(Machine=MACHINE[len(a.key)], MachinePolicy=POLICY[a.policy],
                           State=1, UsagePolicy=a.usage)
            content = a.key + bytes(-len(a.key) % 16)
            blocks = [b2v(content[i:i + 16]) for i in range(0, len(content), 16)]
            csk = b2v(a.csk)
            siv, ct = scc.SCC_Encrypt([mdh], 0, 0, blocks, csk)
            ok, pt = scc.SCC_Decrypt([mdh], 0, 0, siv, ct, csk)
            assert ok and pt == blocks
            out = v2b(mdh, 16) + v2b(siv, 16) + b"".join(v2b(c, 16) for c in ct)
            modes = [m for i, m in enumerate(["U", "VS", "S", "M"]) if not a.usage >> i & 1]
            print(f"SCC, {len(out)} bytes; MDH {v2b(mdh, 16).hex()}: {NAME[MACHINE[len(a.key)]]}, "
                  f"{POLICY_NAME[POLICY[a.policy]]}, Ready, KeyType 0 (key by value), "
                  f"UsagePolicy {a.usage:#x} ({', '.join(modes) or 'no'}-mode use), "
                  "Locality 0 (no HW binding: sealed under the CSK alone)", file=sys.stderr)
            if a.hex:
                print(out.hex())
            else:
                sys.stdout.buffer.write(out)


        main()
      '';
      kleSeal = pkgs.writeShellScriptBin "kle-seal" ''
        exec ${pkgs.python3}/bin/python3 -B ${kleSealPy} "$@"
      '';

      # kle-seal reproduces the model's own regression vector (scc-kat.py
      # REGRESSION[()]): CSK 00..1f, key 80..9f, AES256_ECB encrypt-only in
      # Ready, UsagePolicy 0, no Locality -> MDH, SIV, first Content block.
      sealCheck = pkgs.runCommand "kle-seal-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        want=$(python3 -B - <<'EOF'
        import contextlib, importlib.util, os, sys
        kat = "${spec-src}/src/kat"
        spec = importlib.util.spec_from_file_location("scc_kat", os.path.join(kat, "scc-kat.py"))
        mod = importlib.util.module_from_spec(spec)
        with open(os.devnull, "w") as devnull, contextlib.redirect_stdout(devnull):
            try:
                spec.loader.exec_module(mod)
            except SystemExit as e:
                if e.code:
                    sys.exit("scc-kat.py self-test failed")
        print("".join(mod.REGRESSION[()]))
        EOF
        )
        csk=$(printf '%02x' $(seq 0 31)); key=$(printf '%02x' $(seq 128 159))
        got=$(${kleSeal}/bin/kle-seal --csk $csk --key $key --policy enc --usage 0 --hex)
        echo "model: $want"; echo "seal:  $got"
        case $got in "$want"*) ;; *) echo "kle-seal differs from the model"; exit 1 ;; esac
        echo "$got" > $out
      '';

      # The guest side of the provisioning demo: /etc/kle-demo holds an SCC
      # the host sealed, message.enc (the IV, then the message encrypted with
      # the sealed key) and the message's sha256.  openssl enc reads the SCC
      # and message.enc alone: it loads the SCC from the URI kle:scc, which
      # the kle provider's store serves as a key of that provider, the unit
      # unseals it when the cipher is set up, and the message comes out.
      # kle.expect=fail on the command line (a boot under another CSK) turns
      # the demo around: the import must fail.  The demo reads as a console
      # session: each command at a prompt, and what it printed.
      sccDemo = pkgs.writeScript "scc-demo" ''
        #!/bin/sh
        O=${openssl}
        export PATH=$O/bin:$PATH LD_LIBRARY_PATH=$O/lib OPENSSL_MODULES=$O/lib/ossl-modules
        cd /etc/kle-demo

        # run CMD: show CMD at a prompt, run it, and show what it printed,
        # which stays in /tmp/out and /tmp/err.
        run() {
          printf '$ %s\n' "$1"
          eval "$1" > /tmp/out 2> /tmp/err
          local r=$?
          cat /tmp/out /tmp/err
          return $r
        }
        n=0 rc=0
        check() {
          s=$?
          n=$((n + 1))
          if [ $s = 0 ]; then echo "ok $n - $1"; else echo "not ok $n - $1"; rc=1; fi
        }
        # The guest's view of a failure: the kle provider's error.
        refused() { grep -q "Error setting an opaque key" /tmp/err; }

        # The MDH, the first 16 bytes, in the clear.
        set -- $(od -An -tu1 -N16 -v scc)
        machine=$(($1 | ($2 & 15) << 8)) policy=$(($2 >> 4 & 3)) state=$(($3 >> 2 & 63))
        keytype=$(($4 >> 4 & 3)) usage=$(($9 & 31)) locality=$((($9 >> 5 | ''${10} << 3) & 511))
        case $machine in 0) m=AES128_ECB ;; 16) m=AES192_ECB ;; 32) m=AES256_ECB ;;
                         *) m="Machine $machine" ;; esac
        case $policy in 1) p="encrypt only" ;; 2) p="decrypt only" ;; 3) p="encrypt and decrypt" ;;
                        *) p="no use" ;; esac
        case $state in 1) s=Ready ;; *) s="State $state" ;; esac
        modes=; for i in 0 1 2 3; do
          [ $((usage >> i & 1)) = 1 ] ||
            modes="$modes''${modes:+, }$(printf '%s\n' U VS S M | sed -n $((i + 1))p)"
        done
        echo "# scc: the AES-256 key, sealed by the key server: the MDH (in the clear), the SIV, the key"
        run 'xxd scc'
        echo "# MDH: $m, $p, $s, KeyType $keytype, UsagePolicy $(printf %#x $usage) (''${modes:-no}-mode use)," \
          "Locality $locality$([ $locality = 0 ] && echo ' (no HW binding)')"
        echo "# message.enc: the IV, then the message encrypted with the key (AES-256-CBC)"
        run 'xxd message.enc'

        echo "# openssl, and no key: the kle provider loads the SCC from the URI kle:scc"
        run 'tail -c +17 message.enc | openssl enc -d -aes-256-cbc -provider kle -skeyuri kle:scc \
            -iv $(head -c 16 message.enc | xxd -p)'
        d=$?
        if grep -q kle.expect=fail /proc/cmdline; then
          [ $d != 0 ] && refused
          check "another device, with its own CSK: the SCC does not import, nothing decrypts"
          exit $rc
        fi
        [ $d = 0 ] && mv /tmp/out /tmp/message &&
          (cd /tmp && sha256sum -c /etc/kle-demo/message.sha256 > /dev/null 2>&1)
        check "the message decrypts with the SCC, and matches the sender's sha256"

        echo "# encrypting with the same SCC, whose MDH says decrypt only"
        ! run 'echo Hello | openssl enc -e -aes-256-cbc -provider kle -skeyuri kle:scc \
            -iv $(head -c 16 message.enc | xxd -p)' && refused
        check "the SCC says decrypt only: encrypting with it fails"

        # One bit of the SIV (bytes 16-31) flipped.
        cp scc flipped.scc
        b=$(od -An -tu1 -j20 -N1 scc)
        printf "\\$(printf %o $((b ^ 16)))" | dd of=flipped.scc bs=1 seek=20 conv=notrunc 2> /dev/null
        echo "# flipped.scc: scc with one bit of its SIV flipped"
        ! run 'tail -c +17 message.enc | openssl enc -d -aes-256-cbc -provider kle -skeyuri kle:flipped.scc \
            -iv $(head -c 16 message.enc | xxd -p)' && refused
        check "one bit flipped: the SCC fails authentication, nothing decrypts"
        exit $rc
      '';

      opensslTests = pkgs.writeScript "openssl-tests" ''
        #!/bin/sh
        set -e
        O=${openssl}
        export LD_LIBRARY_PATH=$O/lib OPENSSL_MODULES=$O/lib/ossl-modules
        T=$O/libexec/tests
        D=$O/share/tests/evpciph_aes_common.txt

        # The second boot of kle-test has only the ECB Machines.
        export KLE_EXPECT_CTR=1 KLE_EXPECT_GCM=1
        grep -q kle.ctr=off /proc/cmdline && KLE_EXPECT_CTR=0
        grep -q kle.gcm=off /proc/cmdline && KLE_EXPECT_GCM=0
        echo "AES-CTR on the $([ $KLE_EXPECT_CTR = 1 ] && echo CTR || echo ECB) Machine," \
          "the kle provider's AES-GCM $([ $KLE_EXPECT_GCM = 1 ] && echo "on the GCM Machine" || echo absent)"

        # Run a test quietly; show its summary, fail with it.
        run() {
          if "$@" > /tmp/log 2>&1; then
            grep -E "Completed|^ok [0-9]|^not ok" /tmp/log | tail -3
          else
            cat /tmp/log; echo "FAILED: $*"; return 1
          fi
        }

        echo "--- kle_test (kle provider, EVP_SKEY, default provider)"
        run $T/kle_test

        echo "--- evp_test AES KATs, default provider (lockers used transparently)"
        run $T/evp_test $D

        echo "--- evp_test AES KATs, kle provider only (its ECB, CBC, CTR stanzas)"
        awk 'BEGIN { RS = ""; ORS = "\n\n" }
             tolower($0) ~ /cipher = aes-(128|192|256)-(ecb|cbc|ctr)/' $D > /tmp/kle-kat.txt
        echo "$(grep -c '^Cipher =' /tmp/kle-kat.txt) stanzas"
        run $T/evp_test -provider kle -propquery provider=kle /tmp/kle-kat.txt

        # The GCM Machine checks only 16-byte tags, and takes text in whole
        # blocks but the last update: -chunk 16 instead of fragments.
        if [ $KLE_EXPECT_GCM = 1 ]; then
          echo "--- evp_test AES-GCM KATs, kle provider only (16-byte tags)"
          awk 'BEGIN { RS = ""; ORS = "\n\n" }
               { n = split($0, L, "\n"); t = 0
                 for (i = 1; i <= n; i++) if (L[i] ~ /^Tag = / && length(L[i]) == 38) t = 1 }
               t && tolower($0) ~ /cipher = aes-(128|192|256)-gcm/' $D > /tmp/kle-gcm.txt
          echo "$(grep -c '^Cipher =' /tmp/kle-gcm.txt) stanzas"
          run $T/evp_test -provider kle -propquery provider=kle -chunk 16 /tmp/kle-gcm.txt
        fi

        echo "--- openssl enc: kle provider vs default without Zkl"
        IV=f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff
        $O/bin/openssl rand -out /tmp/pt 100003
        for c in aes-256-ctr aes-128-cbc aes-192-ecb; do
          case $c in
            *-128-*) K=000102030405060708090a0b0c0d0e0f ;;
            *-192-*) K=000102030405060708090a0b0c0d0e0f1011121314151617 ;;
            *) K=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f ;;
          esac
          case $c in *-ecb) ivopt= ;; *) ivopt="-iv $IV" ;; esac
          $O/bin/openssl enc -$c -K $K $ivopt -provider kle -provider default \
            -propquery provider=kle -in /tmp/pt -out /tmp/ct.kle
          OPENSSL_riscvcap=rv64gcv $O/bin/openssl enc -$c -K $K $ivopt \
            -in /tmp/pt -out /tmp/ct.ref
          cmp /tmp/ct.kle /tmp/ct.ref
          $O/bin/openssl enc -d -$c -K $K $ivopt -provider kle \
            -propquery provider=kle -in /tmp/ct.kle -out /tmp/back
          cmp /tmp/back /tmp/pt
          echo "ok $c"
        done
      '';

      # TLS over loopback: openssl s_server and kle-https, both on lockers.
      tlsTests = pkgs.writeScript "tls-tests" ''
        #!/bin/sh
        set -e
        O=${openssl}
        C=${testCerts}
        export LD_LIBRARY_PATH=$O/lib OPENSSL_MODULES=$O/lib/ossl-modules

        mkdir -p /tmp/www && cd /tmp/www
        head -c 100003 /dev/urandom > page
        $O/bin/openssl s_server -quiet -accept 127.0.0.1:4433 -WWW \
          -cert $C/server.pem -key $C/server.key > /tmp/s_server.log 2>&1 &
        trap "kill $!" EXIT
        n=0
        until grep -q ':1151 00000000:0000 0A' /proc/net/tcp; do
          n=$((n + 1)); [ $n -lt 100 ] || { cat /tmp/s_server.log; exit 1; }
          sleep 0.1
        done

        # Where the record keys go: GCM's AES on the CTR Machine (else ECB)
        # in the default provider, all of GCM on the GCM Machine with --kle
        # (else the default provider's again); CBC on the ECB Machine.
        gcm=AES128_CTR
        grep -q kle.ctr=off /proc/cmdline && gcm=AES128_ECB
        kle=AES128_GCM
        grep -q kle.gcm=off /proc/cmdline && kle=$gcm

        # Lockers in a census of the report matching a pattern.
        lockers() {
          sed -n "/^lockers $1:/,/^[^ ]/p" /tmp/report | grep -cE "$2" || true
        }
        # fetch NAME RECORD-LOCKERS [kle-https options]: the page must come
        # back intact; the record keys must be in RECORD-LOCKERS (a census
        # pattern; "" for software) during the connection and gone after.
        fetch() {
          name=$1 rec=$2
          shift 2
          if /bin/kle-https --CAfile $C/ca.pem --port 4433 --path /page --body \
               "$@" localhost > /tmp/got 2> /tmp/report && cmp -s /tmp/got page
          then :; else
            cat /tmp/report; echo "FAILED: $name"; return 1
          fi
          want=0; [ -z "$rec" ] || want=2
          got=$(lockers "after the handshake" "$rec")
          [ -n "$rec" ] || got=$(lockers "after the handshake" 'AES128|_GCM')
          left=$(lockers "after SSL_free" 'AES128|_GCM')
          if [ "$got" != $want ] || [ "$left" != 0 ]; then
            cat /tmp/report
            echo "FAILED: $name: $got record lockers (want $want), $left left"
            return 1
          fi
          echo "ok $name: $(grep -m1 '^TLSv' /tmp/report)"
        }
        # tamper NAME FAILURES [kle-https options]: with one bit of the
        # server's first record after the handshake flipped, the read must
        # fail, and FAILURES lockers be in Failure: 1, the kle provider's
        # decrypt-only GCM locker, whose Machine checked the tag, or 0, the
        # tag checked in software.
        tamper() {
          name=$1 want=$2
          shift 2
          if /bin/kle-https --CAfile $C/ca.pem --port 4433 --path /page --tamper \
               "$@" localhost > /dev/null 2> /tmp/report; then
            cat /tmp/report; echo "FAILED: $name: read the page with a bit flipped"
            return 1
          fi
          got=$(lockers "after the failed read" '_GCM +Failure +dec +kle provider')
          all=$(lockers "after the failed read" Failure)
          if ! grep -q "bad record mac" /tmp/report || [ "$got" != $want ] ||
             [ "$all" != $want ]; then
            cat /tmp/report
            echo "FAILED: $name: $all lockers in Failure, $got the kle provider's (want $want)"
            return 1
          fi
          echo "ok $name, a bit flipped: bad record mac, $([ $want = 1 ] &&
            echo "the GCM locker in Failure" || echo "no locker in Failure")"
        }

        # The record keys are AES-128, the DRBG's AES-256; with AES-256 only
        # the kle provider's GCM Machine stands out, and nothing is left.
        fetch "TLS 1.3 GCM" $gcm --tls1.3 --suite TLS_AES_128_GCM_SHA256
        fetch "TLS 1.3 GCM, kle" $kle --kle --tls1.3 --suite TLS_AES_128_GCM_SHA256
        fetch "TLS 1.3 AES-256-GCM" "" --tls1.3 --suite TLS_AES_256_GCM_SHA384
        fetch "TLS 1.3 AES-256-GCM, kle" "$([ $kle = AES128_GCM ] && echo AES256_GCM)" \
          --kle --tls1.3 --suite TLS_AES_256_GCM_SHA384
        fetch "TLS 1.2 GCM" $gcm --tls1.2 --suite ECDHE-RSA-AES128-GCM-SHA256
        fetch "TLS 1.2 GCM, kle" $kle --kle --tls1.2 --suite ECDHE-RSA-AES128-GCM-SHA256
        fetch "TLS 1.2 CBC" AES128_ECB --tls1.2 --suite ECDHE-RSA-AES128-SHA

        f=0; [ $kle = AES128_GCM ] && f=1
        tamper "TLS 1.3 GCM" 0 --tls1.3 --suite TLS_AES_128_GCM_SHA256
        tamper "TLS 1.3 GCM, kle" $f --kle --tls1.3 --suite TLS_AES_128_GCM_SHA256
        tamper "TLS 1.2 GCM" 0 --tls1.2 --suite ECDHE-RSA-AES128-GCM-SHA256
        tamper "TLS 1.2 GCM, kle" $f --kle --tls1.2 --suite ECDHE-RSA-AES128-GCM-SHA256
      '';

      # The HTTPS demo, which needs the network (nix run .#https), so is not
      # in the test boots.  It reads the page through the default provider
      # and with --kle, then has each read a record with one bit flipped,
      # and checks kle-https's censuses: each locker's Machine, State and
      # policy as the unit reports them (kl.getmd), and which provider's
      # locker table holds it.  With localhost as the host the page comes
      # from openssl s_server in the guest, as in tls-tests, so the demo
      # needs no network.
      tlsDemo = pkgs.writeScript "tls-demo" ''
        #!/bin/sh
        O=${openssl}
        export LD_LIBRARY_PATH=$O/lib OPENSSL_MODULES=$O/lib/ossl-modules
        export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
        host=$(sed -n 's/.*kle\.host=\([^ ]*\).*/\1/p' /proc/cmdline)
        host=''${host:-openssl-conference.org}
        echo "$(date -u)"
        opts=
        if [ "$host" = localhost ]; then
          C=${testCerts}
          mkdir -p /tmp/www && cd /tmp/www
          { echo '<!doctype html>'
            echo '<html><head><title>KLE demo page, served by openssl s_server in the guest</title></head>'
            echo '<body><p>'; seq -s ' ' 1 3000; echo '</p></body></html>'; } > page
          $O/bin/openssl s_server -quiet -accept 127.0.0.1:4433 -WWW \
            -cert $C/server.pem -key $C/server.key > /tmp/s_server.log 2>&1 &
          trap "kill $!" EXIT
          n=0
          until grep -q ':1151 00000000:0000 0A' /proc/net/tcp; do
            n=$((n + 1)); [ $n -lt 100 ] || { cat /tmp/s_server.log; exit 1; }
            sleep 0.1
          done
          opts="--CAfile $C/ca.pem --port 4433 --path /page"
        elif [ ! -e /sys/class/net/eth0 ]; then
          echo "no network: run it with nix run .#https"; exit 1
        fi

        # get NAME [kle-https options]: the report to /tmp/NAME and the
        # console, the body to /tmp/NAME.html; kle-https's status.
        get() {
          name=$1
          shift
          echo "--- kle-https $* $host"
          /bin/kle-https "$@" $opts --body "$host" > /tmp/$name.html 2> /tmp/$name
          s=$?
          cat /tmp/$name
          grep -o '<title>[^<]*</title>' /tmp/$name.html | head -1
          return $s
        }
        get dflt; dflt=$?
        get kle --kle; kle=$?
        get dflt-bit --tamper; dflt_bit=$?
        get kle-bit --kle --tamper; kle_bit=$?

        # Lockers in a census of a report that match a pattern.
        lockers() {
          sed -n "/^lockers $2:/,/^[^ ]/p" /tmp/$1 | grep -cE "$3"
        }
        # check DESCRIPTION, after the command that decides it.
        n=0 rc=0
        check() {
          s=$?
          n=$((n + 1))
          if [ $s = 0 ]; then echo "ok $n - $1"; else echo "not ok $n - $1"; rc=1; fi
        }
        echo "--- does the kle provider protect the connection to $host?"
        [ $dflt = 0 ] && grep -q "from the default provider" /tmp/dflt &&
          [ $(lockers dflt "after the handshake" _GCM) = 0 ] &&
          [ $(lockers dflt "after the handshake" '_CTR +Operate +enc +default provider') = 2 ]
        check "default provider: AES-GCM's AES in 2 CTR lockers, GHASH in software, no GCM locker"
        [ $kle = 0 ] && grep -q "from the kle provider" /tmp/kle &&
          [ $(lockers kle "after the handshake" _GCM) = 2 ] &&
          [ $(lockers kle "after the handshake" '_GCM .* enc +kle provider') = 1 ] &&
          [ $(lockers kle "after the handshake" '_GCM .* dec +kle provider') = 1 ]
        check "--kle: all of AES-GCM in 2 GCM lockers of the kle provider, encrypt-only and decrypt-only"
        [ $(lockers kle "after the response" '_GCM +Success +(enc|dec) +kle provider') = 2 ]
        check "--kle: both in Success after the response: the Machine made the request's tag and checked the server's"
        [ $kle_bit != 0 ] && grep -q "bad record mac" /tmp/kle-bit &&
          [ $(lockers kle-bit "after the failed read" '_GCM +Failure +dec +kle provider') = 1 ]
        check "--kle, one bit of a server record flipped: bad record mac, and the decrypt-only locker in Failure"
        [ $dflt_bit != 0 ] && grep -q "bad record mac" /tmp/dflt-bit &&
          [ $(lockers dflt-bit "after the failed read" Failure) = 0 ]
        check "default provider, the same bit flipped: bad record mac, and no locker in Failure"
        [ $(lockers kle "after SSL_free" _GCM) = 0 ]
        check "--kle: no GCM locker left after SSL_free"
        exit $rc
      '';

      testList = pkgs.writeText "kle-tests" ''
        /bin/zkl_test
        /bin/openssl-tests
        /bin/tls-tests
      '';

      initScript = pkgs.writeScript "init" ''
        #!/bin/busybox sh
        /bin/busybox --install -s /bin
        mkdir -p /proc /sys /dev /tmp
        mount -t proc proc /proc
        mount -t sysfs sys /sys
        mount -t devtmpfs dev /dev
        mkdir -p /tmp && mount -t tmpfs tmp /tmp
        ip link set lo up
        # QEMU's user network (slirp), when the VM has one.
        if [ -e /sys/class/net/eth0 ]; then
          ip link set eth0 up
          ip addr add 10.0.2.15/24 dev eth0
          ip route add default via 10.0.2.2
          echo "nameserver 10.0.2.3" > /etc/resolv.conf
        fi
        echo "isa: $(grep -m1 '^isa' /proc/cpuinfo)"
        if grep -q kle.shell /proc/cmdline; then
          exec setsid cttyhack sh
        fi
        # kle.only=PROG[,PROG...] runs those instead of the test list.
        only=$(sed -n 's/.*kle\.only=\([^ ]*\).*/\1/p' /proc/cmdline)
        rc=0
        for t in $(if [ -n "$only" ]; then echo "$only" | tr , ' '
                   else cat /etc/kle-tests; fi); do
          echo "=== $t"
          sh -c "$t" || { echo "=== FAILED: $t"; rc=1; }
        done
        if [ $rc = 0 ]; then echo "KLE-RESULT: PASS"; else echo "KLE-RESULT: FAIL"; fi
        poweroff -f
      '';

      initrd = pkgs.makeInitrd {
        name = "kle-initrd";
        compressor = "gzip";
        contents = [
          { object = initScript; symlink = "/init"; }
          { object = "${busybox}/bin/busybox"; symlink = "/bin/busybox"; }
          { object = "${selftest}/bin/zkl_test"; symlink = "/bin/zkl_test"; }
          { object = opensslTests; symlink = "/bin/openssl-tests"; }
          { object = tlsTests; symlink = "/bin/tls-tests"; }
          { object = tlsDemo; symlink = "/bin/tls-demo"; }
          { object = sccDemo; symlink = "/bin/scc-demo"; }
          { object = "${openssl}/bin/kle-https"; symlink = "/bin/kle-https"; }
          { object = testList; symlink = "/etc/kle-tests"; }
          { object = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; symlink = "/etc/ssl/certs/ca-bundle.crt"; }
          { object = pkgs.writeText "hosts" "127.0.0.1 localhost\n"; symlink = "/etc/hosts"; }
          { object = pkgs.writeText "nsswitch.conf" "hosts: files dns\n"; symlink = "/etc/nsswitch.conf"; }
        ];
      };

      # qemuCmdWith CPU INITRD EXTRA: the whole -cpu string, an initrd and
      # the kernel command line after console=ttyS0; qemuCmd adds to the
      # default CPU and takes the flake's initrd.
      qemuCmdWith = cpu: initrdPath: extra: "${qemu}/bin/qemu-system-riscv64 -M virt -cpu ${cpu}"
        + " -smp 4 -m 2G -nographic -no-reboot -kernel ${kernel}/Image"
        + " -initrd ${initrdPath} -append \"console=ttyS0 ${extra}\"";
      qemuCmd = cpu: extra: qemuCmdWith "${qemuCpu}${cpu}" "${initrd}/initrd" extra;
      netArgs = " -netdev user,id=n0 -device virtio-net-device,netdev=n0";
      # passed [quiet]: copy the console to our stderr and look for the
      # verdict.  Not `tee /dev/stderr`: reopening stderr truncates it when
      # it is a file.  Quiet holds the firmware and kernel boot back until
      # the first test line, and shows it only if the guest never gets
      # there; KLE_VERBOSE=1 shows everything.
      passed = ''
        passed() {
          local line ok=1 hold=''${1:+1}
          local -a held=()
          [ -z "''${KLE_VERBOSE:-}" ] || hold=
          while IFS= read -r line || [ -n "$line" ]; do
            case $line in "=== "*|"--- "*) hold= ;; esac
            if [ -n "$hold" ]; then
              held+=("$line")
            else
              printf '%s\n' "$line" >&2
            fi
            case $line in *"KLE-RESULT: PASS"*) ok=0 ;; esac
          done
          [ $ok = 0 ] || [ -z "$hold" ] || printf '%s\n' "''${held[@]}" >&2
          return $ok
        }
      '';

      vm = pkgs.writeShellScriptBin "kle-vm" ''
        exec ${qemuCmd "" "kle.shell"}${netArgs} "$@"
      '';
      # Read an HTTPS page from the guest, and check that the kle provider
      # protects the connection: nix run .#https [-- host|localhost], the
      # boot held back unless KLE_VERBOSE=1.
      https = pkgs.writeShellScriptBin "kle-https-vm" ''
        ${passed}
        host=''${1:-openssl-conference.org}
        ${qemuCmd "" "quiet kle.only=/bin/tls-demo kle.host=$host"}${netArgs} < /dev/null | passed quiet
      '';
      # The provisioning demo: nix run .#provision [-- message].  On the
      # host, the key server's side: a CSK, an AES-256 key and an IV (random,
      # or KLE_CSK, KLE_KEY and KLE_IV), the key sealed into a decrypt-only SCC
      # by the specification's model, the message encrypted with the key by
      # openssl enc; then QEMU boots with that CSK (x-zkl-csk) and scc-demo
      # decrypts the message with the SCC, and a second boot, a unit with a
      # CSK of its own, shows that the SCC imports nowhere else.
      provision = pkgs.writeShellScriptBin "kle-provision" ''
        set -e
        export PATH=${lib.makeBinPath [ kleSeal pkgs.openssl pkgs.cpio pkgs.gzip pkgs.coreutils pkgs.findutils ]}:$PATH
        ${passed}
        msg=''${*:-"Hello, OpenSSL 2026!"}
        CSK=''${KLE_CSK:-$(openssl rand -hex 32)}
        KEY=''${KLE_KEY:-$(openssl rand -hex 32)}
        IV=''${KLE_IV:-$(openssl rand -hex 16)}
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        cd "$tmp"
        mkdir -p etc/kle-demo

        echo "=== the key server: the host, holding the CSK"
        echo "CSK (QEMU gets it as x-zkl-csk):     $CSK"
        echo "AES-256 key (stays here, sealed):    $KEY"
        echo "IV:                                  $IV"
        echo "message: $msg"
        printf '%s\n' "$msg" > message
        kle-seal --csk $CSK --key $KEY --policy dec > etc/kle-demo/scc
        # message.enc: the IV, then the ciphertext.
        { printf "$(printf %s "$IV" | sed 's/../\\x&/g')"
          openssl enc -aes-256-cbc -K $KEY -iv $IV -in message; } > etc/kle-demo/message.enc
        sha256sum message > etc/kle-demo/message.sha256
        unset KEY
        echo "the guest gets scc and message.enc (and the message's sha256); the key server forgets the key"

        # The flake's initrd plus /etc/kle-demo: later cpio entries win.
        { cat ${initrd}/initrd
          find etc -mindepth 1 | cpio -o -H newc --owner=0:0 --quiet | gzip; } > initrd

        echo "=== boot 1: a unit with that CSK (-cpu ${qemuBase},x-zkl-csk=...)"
        ${qemuCmdWith "${qemuBase},x-zkl-csk=$CSK" "$tmp/initrd" "quiet kle.only=/bin/scc-demo"} \
          < /dev/null | passed quiet
        echo "=== boot 2: another device, a CSK of its own (-cpu ${qemuCpu})"
        ${qemuCmdWith qemuCpu "$tmp/initrd" "quiet kle.only=/bin/scc-demo kle.expect=fail"} \
          < /dev/null | passed quiet
      '';
      # The demo with fixed inputs (the model's regression vector CSK and key).
      provisionCheck = pkgs.runCommand "kle-provision-test" { } ''
        KLE_CSK=$(printf '%02x' $(seq 0 31)) KLE_KEY=$(printf '%02x' $(seq 128 159)) \
          KLE_IV=000102030405060708090a0b0c0d0e0f \
          ${provision}/bin/kle-provision "A fixed message for the check." > $out 2>&1
      '';
      # All tests, then the OpenSSL and TLS ones again on a unit with only
      # the ECB Machines: AES-CTR and the default provider's AES-GCM over
      # ECB, and no AES-GCM in the kle provider.
      vmTest = pkgs.writeShellScriptBin "kle-test" ''
        ${passed}
        ${qemuCmd "" "quiet"} "$@" < /dev/null | passed &&
        ${qemuCmd ",x-zkl-ctr=false,x-zkl-gcm=false" "quiet kle.only=/bin/openssl-tests,/bin/tls-tests kle.ctr=off kle.gcm=off"} "$@" \
          < /dev/null | passed
      '';
    in
    {
      packages.${system} = {
        inherit qemu kernel selftest initrd vm openssl https provision;
        seal = kleSeal;
        test = vmTest;
        default = vmTest;
      };

      apps.${system} = {
        vm = { type = "app"; program = "${vm}/bin/kle-vm"; };
        https = { type = "app"; program = "${https}/bin/kle-https-vm"; };
        provision = { type = "app"; program = "${provision}/bin/kle-provision"; };
        seal = { type = "app"; program = "${kleSeal}/bin/kle-seal"; };
        test = { type = "app"; program = "${vmTest}/bin/kle-test"; };
        default = self.apps.${system}.test;
      };

      checks.${system} = {
        vm-test = pkgs.runCommand "kle-vm-test" { } ''
          ${vmTest}/bin/kle-test > $out 2>&1
        '';
        vectors = vectorsCheck;
        seal = sealCheck;
        provision = provisionCheck;
      };

      devShells.${system} = {
        linux = pkgs.mkShell {
          inputsFrom = [ kernel ];
          shellHook = ''export ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu-'';
        };
        qemu = pkgs.mkShell { inputsFrom = [ qemu ]; packages = [ cross.stdenv.cc ]; };
      };
    };
}
