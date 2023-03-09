{
  description = "Flake providing The Hobania Project, a multiplayer voxel RPG written in Rust.";

  inputs.nci.url = "github:ceohobo1986/nix-cargo-integration";

  outputs = inputs: let
    lib = inputs.nci.inputs.nixpkgs.lib;
    ncl = inputs.nci.lib.nci-lib;

    git = let
      sourceInfo = inputs.self.sourceInfo;
      dateTimeFormat = import ./nix/dateTimeFormat.nix;
      dateTime = dateTimeFormat sourceInfo.lastModified;
      shortRev = sourceInfo.shortRev or "dirty";
    in {
      prettyRev = shortRev + "/" + dateTime;
      tag = "";
    };

    filteredSource = let
      pathsToIgnore = [
        "flake.nix"
        "flake.lock"
        "nix"
        "assets"
        "README.md"
        "CONTRIBUTING.md"
        "CHANGELOG.md"
        "CODE_OF_CONDUCT.md"
        "clippy.toml"
        ".cargo"
        ".github"
        ".gitlab"
      ];
      ignorePaths = path: type: let
        split = lib.splitString "/" path;
        actual = lib.drop 4 split;
        _path = lib.concatStringsSep "/" actual;
      in
        lib.all (n: ! (lib.hasPrefix n _path)) pathsToIgnore;
    in
      builtins.path {
        name = "thp-source";
        path = toString ./.;
        # filter out unnecessary paths
        filter = ignorePaths;
      };
    checkIfLfsIsSetup = pkgs: checkFile: ''
      checkFile="${checkFile}"
      result="$(${pkgs.file}/bin/file --mime-type $checkFile)"
      if [ "$result" = "$checkFile: image/jpeg" ]; then
        echo "Git LFS seems to be setup properly."
        true
      else
        echo "
          Git Large File Storage (git-lfs) has not been set up correctly.
          Most common reasons:
            - git-lfs was not installed before cloning this repository.
            - This repository was not cloned from the primary GitLab mirror.
            - The GitHub mirror does not support LFS.
          See the book at https://hobania.mitmotion.co.za/book for details.
          Run 'nix-shell -p git git-lfs --run \"git lfs install --local && git lfs fetch && git lfs checkout\"'
          or 'nix shell nixpkgs#git-lfs nixpkgs#git -c sh -c \"git lfs install --local && git lfs fetch && git lfs checkout\"'.
        "
        false
      fi
    '';
  in
    inputs.nci.lib.makeOutputs {
      root = ./.;
      config = common: {
        cCompiler.package = common.pkgs.clang;
        outputs.defaults = {
          package = "thp-voxygen";
          app = "thp-voxygen";
        };
        shell = {
          startup.checkLfsSetup.text = ''
            ${checkIfLfsIsSetup common.pkgs "$PWD/assets/voxygen/background/bg_main.jpg"}
            if [ $? -ne 0 ]; then
              exit 1
            fi
          '';
        };
      };
      pkgConfig = common: let
        inherit (common) pkgs;
        thp-common-ov = {
          # We don't add in any information here because otherwise anything
          # that depends on common will be recompiled. We will set these in
          # our wrapper instead.
          NIX_GIT_HASH = "";
          NIX_GIT_TAG = "";
        };
        assets = pkgs.runCommand "thp-assets" {} ''
          mkdir $out
          ln -sf ${./assets} $out/assets
          ${checkIfLfsIsSetup pkgs "$out/assets/voxygen/background/bg_main.jpg"}
        '';
        wrapWithAssets = _: old: let
          runtimeLibs = with pkgs; [
            xorg.libX11
            xorg.libXi
            xorg.libxcb
            xorg.libXcursor
            xorg.libXrandr
            libxkbcommon
            shaderc.lib
            udev
            alsa-lib
            vulkan-loader
          ];
          wrapped =
            common.internal.pkgsSet.utils.wrapDerivation old
            {nativeBuildInputs = [pkgs.makeWrapper];}
            ''
              rm -rf $out/bin
              mkdir $out/bin
              ln -sf ${old}/bin/* $out/bin/
              wrapProgram $out/bin/* \
                ${lib.optionalString (old.pname == "thp-voxygen") "--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs}"} \
                --set THP_ASSETS ${assets} \
                --set THP_GIT_VERSION "${git.prettyRev}" \
                --set THP_GIT_TAG "${git.tag}"
            '';
        in
          wrapped;
      in {
        thp-voxygen = let
          thp-voxygen-deps-ov = oldAttrs: {
            buildInputs = ncl.addBuildInputs oldAttrs (
              with pkgs; [
                alsa-lib
                libxkbcommon
                udev
                xorg.libxcb
              ]
            );
            nativeBuildInputs =
              ncl.addNativeBuildInputs oldAttrs (with pkgs; [python3 pkg-config]);

            SHADERC_LIB_DIR = "${pkgs.shaderc.lib}/lib";
            THP_ASSETS = "${assets}";

            doCheck = false;
            dontCheck = true;
          };
        in {
          features = {
            release = ["default-publish"];
            dev = ["default-publish"];
            test = ["default-publish"];
          };
          depsOverrides.fix-build.overrideAttrs = thp-voxygen-deps-ov;
          overrides = {
            fix-thp-common = thp-common-ov;
            add-deps-reqs.overrideAttrs = thp-voxygen-deps-ov;
            fix-build.overrideAttrs = prev: {
              src = filteredSource;

              THP_USERDATA_STRATEGY = "system";

              dontUseCmakeConfigure = true;

              preConfigure = ''
                ${prev.preConfigure or ""}
                substituteInPlace voxygen/src/audio/soundcache.rs \
                  --replace \
                  "../../../assets/voxygen/audio/null.ogg" \
                  "${./assets/voxygen/audio/null.ogg}"
              '';
            };
          };
          wrapper = wrapWithAssets;
        };
        thp-server-cli = let
          thp-server-cli-deps-ov = oldAttrs: {
            doCheck = false;
            dontCheck = true;
          };
        in {
          features = {
            release = ["default-publish"];
            dev = ["default-publish"];
            test = ["default-publish"];
          };
          depsOverrides.fix-build.overrideAttrs = thp-server-cli-deps-ov;
          overrides = {
            fix-thp-common = thp-common-ov;
            add-deps-reqs.overrideAttrs = thp-server-cli-deps-ov;
            fix-build = {
              src = filteredSource;
              VELOREN_USERDATA_STRATEGY = "system";
            };
          };
          wrapper = wrapWithAssets;
        };
      };
    };
}
