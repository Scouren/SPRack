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
    # The audited corpus (tests/, see conformance-suite-audit.tsv) and the
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

        # The layout SPRACK_TEST_PDKS expects: each checkout's model paths only.
        testPdks = pkgs.runCommand "sprack-test-pdks" { } ''
          mkdir -p $out/sky130_fd_pr $out/ihp/ihp-sg13g2/libs.tech $out/asap7 $out/freepdk45/FreePDK45/ncsu_basekit
          ln -s ${inputs.sky130_fd_pr}/models ${inputs.sky130_fd_pr}/cells $out/sky130_fd_pr/
          ln -s ${inputs.ihp}/ihp-sg13g2/libs.tech/ngspice $out/ihp/ihp-sg13g2/libs.tech/
          ln -s ${inputs.asap7}/models $out/asap7/
          ln -s ${inputs.freepdk45}/FreePDK45/ncsu_basekit/models $out/freepdk45/FreePDK45/ncsu_basekit/
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
          ];
          shellHook = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';
        };
      in
      {
        packages = bundles // {
          test-pdks = testPdks;
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
              pkgs.xyce
              vacask
              refPkgs.openvaf-r
            ];
            SPRACK_TEST_PDKS = testPdks;
            SPRACK_SUITE = conformance;
            inherit (ci) shellHook;
          };
        };
      }
    );
}
