{
  super,
  lib,
  crate2nix,
  path,
  rustPlatform,
  writeText,
}:

lib.extendMkDerivation {
  constructDrv = super.instantiate;

  excludeDrvArgNames = [
    "args"
    "dynamicCargoDeps"
    "select"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      args ? { },
      cargoRoot ? null,
      dynamicCargoDeps ? true,
      select ? "project: project.rootCrate.build",
      passAsFile ? [ ],
      nativeBuildInputs ? [ ],
      preBuild ? "",
      env ? { },
      ...
    }:
    let
      args' = super.mkArgs "crate2nixArgs" args;

      cargoRootPrefix = lib.optionalString (cargoRoot != null) "${cargoRoot}/";
    in
    {
      cargoDeps =
        if dynamicCargoDeps then
          super.callPackage {
            name = "cargo-vendor-dir";
            src = writeText "cargo-deps.nix" /* nix */ ''
              { rustPlatform }:
              rustPlatform.importCargoLock {
                lockFile = "${finalAttrs.src}/${cargoRootPrefix}Cargo.lock";
              }
            '';
          }
        else
          rustPlatform.importCargoLock {
            lockFile = finalAttrs.src + "/${cargoRootPrefix}Cargo.lock";
          };

      nativeBuildInputs = nativeBuildInputs ++ [
        crate2nix
        rustPlatform.cargoSetupHook
      ];

      passAsFile = passAsFile ++ [
        "crate2nixArgs"
        "crate2nixSelect"
      ];
      crate2nixArgs = args'.value;
      crate2nixSelect = select;

      # evaluated from within cargoRoot, see preBuild
      expr = /* nix */ ''
        let
          args = ${args'.load};
          project = import ./Cargo.nix args;
          select = import (builtins.getEnv "crate2nixSelectPath");
          drv = select project;
        in
        (drv.overrideAttrs or (attrs: drv // attrs)) {
          name = "${finalAttrs.passthru.outName}";
        }
      '';

      env = {
        NIX_PATH = "nixpkgs=${super.pathToString path}";
      }
      // env;

      preBuild = ''
        ${preBuild}
        ${lib.optionalString (cargoRoot != null) ''cd "$cargoRoot"''}
        crate2nix generate
      '';
    };
}
