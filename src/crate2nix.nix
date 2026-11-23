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
    "lockFile"
    "outputHashes"
    "select"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      args ? { },
      cargoRoot ? null,
      dynamicCargoDeps ? true,
      lockFile ? null,
      outputHashes ? { },
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

      # a separate lockFile keeps cargoDeps from depending on all of src,
      # which would otherwise re-vendor the dependencies on every change
      lockFile' = if lockFile != null then lockFile else finalAttrs.src + "/${cargoRootPrefix}Cargo.lock";

      # crate2nix falls back to matching crate-hashes.json entries on
      # `<name>@<version>` when the package ID does not match
      crateHashes = lib.mapAttrs' (
        key: hash:
        let
          parts = builtins.match "(.+)-([0-9]+\\.[0-9]+\\.[0-9]+.*)" key;
        in
        if parts == null then
          throw "drowse.crate2nix: outputHashes key '${key}' is not of the form <name>-<version>"
        else
          lib.nameValuePair "#${builtins.elemAt parts 0}@${builtins.elemAt parts 1}" hash
      ) outputHashes;
    in
    {
      cargoDeps =
        if dynamicCargoDeps then
          super.callPackage {
            name = "cargo-vendor-dir";
            src = writeText "cargo-deps.nix" /* nix */ ''
              { rustPlatform, outputHashes }:
              rustPlatform.importCargoLock {
                # the store path has no context here, so importCargoLock's
                # Cargo.lock symlink to it would dangle in the vendor dir
                lockFileContents = builtins.readFile "${lockFile'}";
                inherit outputHashes;
              }
            '';
            args = { inherit outputHashes; };
          }
        else
          rustPlatform.importCargoLock {
            lockFile = lockFile';
            inherit outputHashes;
          };

      nativeBuildInputs = nativeBuildInputs ++ [
        crate2nix
        rustPlatform.cargoSetupHook
      ];

      passAsFile =
        passAsFile
        ++ [
          "crate2nixArgs"
          "crate2nixSelect"
        ]
        ++ lib.optional (outputHashes != { }) "crate2nixHashes";
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

      # crate2nix would otherwise try to prefetch git dependencies, which
      # fails inside of the sandbox
      preBuild = ''
        ${preBuild}
        ${lib.optionalString (cargoRoot != null) ''cd "$cargoRoot"''}
        ${lib.optionalString (outputHashes != { }) ''cp "$crate2nixHashesPath" crate-hashes.json''}
        crate2nix generate
      '';
    }
    // lib.optionalAttrs (outputHashes != { }) {
      crate2nixHashes = builtins.toJSON crateHashes;
    };
}
