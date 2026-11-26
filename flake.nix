{
  description = "SPRack";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    # zls master tracks Zig master; built with the same Zig as the shell.
    zls.url = "github:zigtools/zls";
    zls.inputs.nixpkgs.follows = "nixpkgs";
    # The audited corpus (tests/, see tools/corpus-baseline.tsv) and the
    # reference simulators vacask and openvaf-r.
    # git+https, not github: GitHub's tarball of one commit gave ESPice two NAR hashes.
    conformance.url = "git+https://github.com/Scouren/Conformance-Suite?ref=main&rev=4d565dd4e7ca6e7304a3619031df6c17846ae1f1";
    conformance.inputs.nixpkgs.follows = "nixpkgs";
    conformance.inputs.flake-utils.follows = "flake-utils";
    # VACASK upstream, newer than the conformance suite's fork: acsp, pss,
    # behavioural sources and {} lists. Built as packages.vacask below.
    vacask-src.url = "git+https://codeberg.org/arpadbuermen/VACASK?rev=b2c15511a1a7c6246cca6bcfd8d38bfb3c750d7a";
    vacask-src.flake = false;
    # PDK model libraries for the PDK tests in python/test_sprack.py.
    sky130_fd_pr.url = "github:google/skywater-pdk-libs-sky130_fd_pr";
    sky130_fd_pr.flake = false;
    ihp.url = "github:IHP-GmbH/IHP-Open-PDK";
    ihp.flake = false;
    asap7.url = "github:The-OpenROAD-Project/asap7_pdk_r1p7";
    asap7.flake = false;
    freepdk45.url = "github:baichen318/FreePDK45";
    freepdk45.flake = false;
    # fossi-foundation's fork is what open_pdks builds gf180mcu from; Google's is archived.
    gf180mcu_fd_pr.url = "github:fossi-foundation/globalfoundries-pdk-libs-gf180mcu_fd_pr/5e4be8726e2ae8be099c4131f697a353d6457874";
    gf180mcu_fd_pr.flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
      zls,
      conformance,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}.master;
        # The reference simulators come from the conformance suite's flake.
        refPkgs = conformance.packages.${system};
        # Xyce with plugin support (buildxyceplugin, ADMS's admsXml and the
        # shared libraries a plugin links to): nixpkgs builds it static and
        # without them, and so -plugin cannot load anything (#26, #52).
        # Docs and the regression run are left out to keep the build short.
        xyce =
          (pkgs.xyce.override {
            enableDocs = false;
            enableTests = false;
          }).overrideAttrs
            (o: {
              cmakeFlags = (o.cmakeFlags or [ ]) ++ [ "-DXyce_PLUGIN_SUPPORT=ON" ];
              nativeBuildInputs = o.nativeBuildInputs ++ [ pkgs.adms ];
              outputs = [ "out" ];
            });

        # The layout SPRACK_TEST_PDKS expects: each checkout's model paths only.
        testPdks = pkgs.runCommand "sprack-test-pdks" { } ''
          mkdir -p $out/sky130_fd_pr $out/ihp/ihp-sg13g2/libs.tech $out/asap7 $out/freepdk45/FreePDK45/ncsu_basekit $out/gf180mcu/models
          ln -s ${inputs.sky130_fd_pr}/models ${inputs.sky130_fd_pr}/cells $out/sky130_fd_pr/
          ln -s ${inputs.ihp}/ihp-sg13g2/libs.tech/ngspice $out/ihp/ihp-sg13g2/libs.tech/
          ln -s ${inputs.asap7}/models $out/asap7/
          ln -s ${inputs.freepdk45}/FreePDK45/ncsu_basekit/models $out/freepdk45/FreePDK45/ncsu_basekit/
          ln -s ${inputs.gf180mcu_fd_pr}/models/ngspice $out/gf180mcu/models/
        '';

        # The layout SPRACK_TEST_PDKS_INSTALLED expects: PDKs as their
        # installers leave them. sky130A is open_pdks' own build as ciel
        # (volare's successor) ships it: the ngspice models, the combined
        # layout (libs.tech/combined) and the cells they include. IHP's
        # install is its checkout plus libs.tech/ngspice/osdi, built as
        # ihp-sg13g2/libs.tech/verilog-a/openvaf-compile-va.sh does, so this
        # needs openvaf-r, which only x86_64-linux has.
        ciel =
          asset: hash:
          pkgs.fetchurl {
            url = "https://github.com/fossi-foundation/ciel-releases/releases/download/sky130-8afc8346a57fe1ab7934ba5a6056ea8b43078e71/${asset}.tar.zst";
            inherit hash;
          };
        testPdksInstalled =
          pkgs.runCommandCC "sprack-test-pdks-installed" { nativeBuildInputs = [ pkgs.zstd refPkgs.openvaf-r ]; }
            ''
              mkdir -p $out/sky130 $out/ihp/ihp-sg13g2/libs.tech/ngspice/osdi
              tar --zstd -xf ${ciel "common" "sha256-vopUg0H9kXevnkYa17T92Jr74D26aNxC0VUyH9w/hr8="} -C $out/sky130 sky130A/libs.tech/ngspice sky130A/libs.tech/combined
              tar --zstd -xf ${ciel "sky130_fd_pr" "sha256-DOTQNwGnUO4NaX0DU2yy4+yJyMf0yjfRp3NtVGh0+uY="} -C $out/sky130 sky130A/libs.ref/sky130_fd_pr/spice
              ln -s ${inputs.ihp}/ihp-sg13g2/libs.tech/ngspice/models $out/ihp/ihp-sg13g2/libs.tech/ngspice/
              cd ${inputs.ihp}/ihp-sg13g2/libs.tech/verilog-a
              for va in psp103/psp103 psp103/psp103_nqs r3_cmc/r3_cmc mosvar/mosvar cap_cmomi/cap_cmomi cap_cmomf/cap_cmomf; do
                openvaf-r -D__NGSPICE__ --target_cpu generic -o $out/ihp/ihp-sg13g2/libs.tech/ngspice/osdi/$(basename $va).osdi $va.va
                test -f $out/ihp/ihp-sg13g2/libs.tech/ngspice/osdi/$(basename $va).osdi
              done
            '';

        # BSIM-CMG 107.0.0, the version ASAP7's cards state, compiled from
        # the Xyce source nixpkgs builds Xyce from: the module a translation
        # to ngspice or VACASK is given (issue 53). openvaf-r: x86_64-linux.
        bsimcmgOsdi = pkgs.runCommandCC "bsimcmg-osdi" { nativeBuildInputs = [ refPkgs.openvaf-r pkgs.python3 ]; } ''
          mkdir $out
          sh ${./tools/bsimcmg-osdi.sh} ${builtins.head pkgs.xyce.srcs} $out/bsimcmg.osdi
        '';

        # The Python package to ship (zig build bundle): $out/python/sprack/
        # with __init__.py, pdks/*.json and the extension, for one Zig target.
        # Any system builds any target: Zig cross-compiles, and the Windows
        # import library for python3.dll comes from src/python3.def.
        mkBundle =
          target:
          pkgs.stdenvNoCC.mkDerivation {
            pname = "sprack-python-${target}";
            version = "0.1.0";
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./build.zig
                ./build.zig.zon
                ./src
                ./grammars
                (pkgs.lib.fileset.fileFilter (f: f.hasExt "py" || f.hasExt "json") ./python/sprack)
              ];
            };
            nativeBuildInputs = [ zig ];
            dontConfigure = true;
            dontInstall = true;
            # The binary is for elsewhere (another OS, or any Linux): no
            # patching, no stripping.
            dontFixup = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
              zig build bundle -Doptimize=ReleaseSafe -Dtarget=${target} --prefix $out
            '';
          };
        # glibc 2.28 (2018) and baseline CPUs, so a Linux bundle loads on any
        # distribution of the last years.
        bundleTargets = {
          x86_64-linux-gnu = "x86_64-linux-gnu.2.28";
          aarch64-linux-gnu = "aarch64-linux-gnu.2.28";
          x86_64-macos = "x86_64-macos";
          aarch64-macos = "aarch64-macos";
          x86_64-windows-gnu = "x86_64-windows-gnu";
        };
        hostTarget =
          {
            x86_64-linux = "x86_64-linux-gnu";
            aarch64-linux = "aarch64-linux-gnu";
            x86_64-darwin = "x86_64-macos";
            aarch64-darwin = "aarch64-macos";
          }
          .${system};
        # VACASK from upstream, its OSDI models compiled by the suite's
        # openvaf-r; install() stages them in lib/vacask/mod, where
        # `load "spice/resistor.osdi"` resolves.
        vacask = pkgs.stdenv.mkDerivation {
          pname = "vacask";
          version = "b2c1551";
          src = inputs.vacask-src;
          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            pkg-config
            python3
            bison
            flex
          ];
          buildInputs = with pkgs; [
            suitesparse
            boost
            tomlplusplus
            fftw
            # include/blaslapack.h declares BLAS with 32-bit ints.
            (openblas.override { blas64 = false; })
          ];
          # nixpkgs ships boost shared only, and suitesparse's klu.h directly
          # in include/; the source has no .git for the version banner.
          postPatch = ''
            substituteInPlace CMakeLists.txt \
              --replace-fail 'set(Boost_USE_STATIC_LIBS ON)' "" \
              --replace-fail 'set(Boost_NO_SYSTEM_PATHS TRUE)' "" \
              --replace-fail 'set(PROGRAM_VERSION "unknown")' 'set(PROGRAM_VERSION "b2c1551")'
            substituteInPlace include/solklu.h --replace-fail '<suitesparse/klu.h>' '<klu.h>'
          '';
          cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            "-DOPENVAF_DIR=${refPkgs.openvaf-r}/bin"
            "-DTOMLPP_DIR=${pkgs.tomlplusplus}"
            "-DSuiteSparse_DIR=${pkgs.suitesparse}"
          ];
          meta = {
            homepage = "https://codeberg.org/arpadbuermen/VACASK";
            license = pkgs.lib.licenses.agpl3Plus;
            platforms = [ "x86_64-linux" ];
            mainProgram = "vacask";
          };
        };

        bundles = pkgs.lib.mapAttrs'(n: t: pkgs.lib.nameValuePair "python-${n}" (mkBundle t)) bundleTargets;

        ci = pkgs.mkShell {
          packages = [
            zig
            pkgs.python3
            pkgs.python3Packages.pip # pip wheel . (pyproject.toml)
          ]
          # zig build coverage (issue 65); kcov is packaged for Linux only.
          ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.kcov;
          shellHook = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';
        };
      in
      {
        packages = bundles // {
          test-pdks = testPdks;
        }
        // nixpkgs.lib.optionalAttrs (refPkgs ? openvaf-r) {
          test-pdks-installed = testPdksInstalled;
          bsimcmg-osdi = bsimcmgOsdi;
        }
        // {
          # This system's own bundle.
          python = bundles."python-${hostTarget}";
        }
        # openvaf-r, hence vacask, is x86_64-linux only.
        // nixpkgs.lib.optionalAttrs (refPkgs ? openvaf-r) { inherit vacask; };

        devShells = {
          inherit ci;
          default = pkgs.mkShell {
            inputsFrom = [ ci ];
            packages = [ zls.packages.${system}.zls ];
            inherit (ci) shellHook;
          };
        }
        # vacask and openvaf-r are x86_64-linux only.
        // nixpkgs.lib.optionalAttrs (refPkgs ? vacask) {
          verify = pkgs.mkShell {
            inputsFrom = [ ci ];
            packages = [
              pkgs.ngspice
              xyce
              vacask
              refPkgs.openvaf-r
            ];
            SPRACK_TEST_PDKS = testPdks;
            SPRACK_TEST_PDKS_INSTALLED = testPdksInstalled;
            SPRACK_BSIMCMG_OSDI = "${bsimcmgOsdi}/bsimcmg.osdi";
            SPRACK_SUITE = conformance;
            inherit (ci) shellHook;
          };
        }
        # LTspice (unfree) runs under wine, which nixpkgs packages for
        # x86_64-linux only: `nix develop .#ltspice -c tools/ltspice-batch.sh
        # deck.net` leaves deck.log and deck.raw beside the deck. The first
        # run unpacks LTspice's library into $LTSPICE_STATE (about a minute).
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          ltspice =
            let
              unfree = import nixpkgs {
                inherit system;
                config.allowUnfreePredicate = p: nixpkgs.lib.getName p == "ltspice";
              };
            in
            pkgs.mkShell {
              inputsFrom = [ ci ];
              # wine64 is the wine the ltspice package itself runs on.
              packages = [
                pkgs.wine64
                pkgs.xvfb-run
              ];
              # The program itself, not the package's launcher: that one
              # returns at once and puts -ini first, which turns -b off.
              LTSPICE_EXE = "${unfree.ltspice}/libexec/ltspice/LTspice.exe";
              shellHook = ci.shellHook + ''
                export LTSPICE_STATE="''${XDG_CACHE_HOME:-$HOME/.cache}/sprack-ltspice"
              '';
            };
        };
      }
    );
}
