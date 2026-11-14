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

        ci = pkgs.mkShell {
          packages = [
            zig
            pkgs.python3
          ];
          shellHook = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';
        };
      in
      {
        packages.test-pdks = testPdks;

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
              refPkgs.vacask
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
