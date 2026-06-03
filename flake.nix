{
  description = "zz development environments";

  inputs.nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0.1";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      eachSystem = f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config = {
                allowUnfree = true;
                android_sdk.accept_license = true;
              };
            }
          )
        );
    in
    {
      devShells = eachSystem (
        pkgs:
        let
          isAarch64Linux = pkgs.stdenv.hostPlatform.system == "aarch64-linux";

          androidSdk = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "35" ];
            buildToolsVersions = [
              "34.0.0"
              "35.0.0"
            ];
            includeEmulator = false;
            includeSystemImages = false;
            includeSources = false;
            includeNDK = false;
          };

          x86Linux = import nixpkgs {
            system = "x86_64-linux";
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };

          aapt2Wrapper = pkgs.writeShellScriptBin "aapt2" ''
            exec ${pkgs.qemu}/bin/qemu-x86_64 \
              ${x86Linux.glibc.out}/lib/ld-linux-x86-64.so.2 \
              --library-path ${x86Linux.glibc.out}/lib:${x86Linux.stdenv.cc.cc.lib}/lib \
              ${androidSdk.androidsdk}/libexec/android-sdk/build-tools/35.0.0/aapt2 "$@"
          '';
        in
        {
          default = pkgs.mkShell {
            packages =
              [
                pkgs.jdk17
                androidSdk.androidsdk
              ]
              ++ pkgs.lib.optionals isAarch64Linux [
                aapt2Wrapper
              ];

            ANDROID_HOME = "${androidSdk.androidsdk}/libexec/android-sdk";
            ANDROID_SDK_ROOT = "${androidSdk.androidsdk}/libexec/android-sdk";
            JAVA_HOME = pkgs.jdk17.home;

            shellHook = pkgs.lib.optionalString isAarch64Linux ''
              export GRADLE_OPTS="''${GRADLE_OPTS:-} -Dorg.gradle.project.android.aapt2FromMavenOverride=${aapt2Wrapper}/bin/aapt2"
            '';
          };
        }
      );
    };
}
