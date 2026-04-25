{
  description = "kiorg - A hacker's file manager with VIM inspired keybinds";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # pdfium prebuilt version bundled by pdfium-bind's build.rs
      pdfiumVersion = "7592";

      pdfiumTarballs = {
        "x86_64-linux" = {
          url = "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F${pdfiumVersion}/pdfium-linux-x64.tgz";
          hash = "sha256-gVS9544RX+zub1tJhKljVQLkwrTGFeXopLNc9nJpCOc=";
        };
        "aarch64-linux" = {
          url = "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F${pdfiumVersion}/pdfium-linux-arm64.tgz";
          hash = "sha256-F525D9WHvcwMYP+mq9sIJCSRXi8tM3nxeLhuBp+2+Wc=";
        };
        "x86_64-darwin" = {
          url = "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F${pdfiumVersion}/pdfium-mac-x64.tgz";
          hash = "sha256-6Wwr1KwJ6RZ+2yjLyPZpN8/JmbdFTtzRcsZm4cB9S8A=";
        };
        "aarch64-darwin" = {
          url = "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F${pdfiumVersion}/pdfium-mac-arm64.tgz";
          hash = "sha256-Vq9F0VzdJ7MjWGF5oRRhjZa4cTIjyJ3BXqYjiy9oi68=";
        };
      };

      mkPerSystem =
        system:
        let
          overlays = [ (import rust-overlay) ];
          pkgs = import nixpkgs { inherit system overlays; };

          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "rust-src"
              "rust-analyzer"
            ];
          };

          nativeBuildInputs = with pkgs; [
            rustToolchain
            pkg-config
            cmake
            clang
            llvmPackages.libclang
            makeWrapper
          ];

          buildInputs = with pkgs; [
            oniguruma
            bzip2
            fontconfig
            freetype
            wayland
            wayland-protocols
            libxkbcommon
            libx11
            vulkan-loader
            libGL
            openssl
            stdenv.cc.cc.lib
          ];

          pdfiumUnpacked = pkgs.runCommand "pdfium-unpacked" { } ''
            mkdir -p $out
            tar -xzf ${pkgs.fetchurl pdfiumTarballs.${system}} -C $out
          '';
        in
        {
          packages.xdg-desktop-portal-kiorg = pkgs.rustPlatform.buildRustPackage {
            pname = "xdg-desktop-portal-kiorg";
            version = "0.1.0";
            src = ./.;
            cargoHash = "sha256-Cw100J7G7x2AsLobKjHk4tO9CHjcxOkApIYILZLMTL0=";

            cargoBuildFlags = [
              "-p"
              "kiorg-portal"
            ];
            doCheck = false;

            nativeBuildInputs = with pkgs; [
              rustToolchain
              pkg-config
              makeWrapper
            ];

            buildInputs = with pkgs; [
              openssl
              stdenv.cc.cc.lib
            ];

            postInstall =
              let
                portalFile = pkgs.writeText "kiorg.portal" ''
                  [portal]
                  DBusName=org.freedesktop.impl.portal.desktop.kiorg
                  Interfaces=org.freedesktop.impl.portal.FileChooser
                  UseIn=kiorg
                '';
                dbusService = pkgs.writeTextFile {
                  name = "org.freedesktop.impl.portal.desktop.kiorg.service";
                  text = ''
                    [D-BUS Service]
                    Name=org.freedesktop.impl.portal.desktop.kiorg
                    Exec=@out@/libexec/xdg-desktop-portal-kiorg
                  '';
                };
                systemdUnit = pkgs.writeText "xdg-desktop-portal-kiorg.service" ''
                  [Unit]
                  Description=Kiorg portal backend (xdg-desktop-portal)
                  PartOf=graphical-session.target

                  [Service]
                  Type=dbus
                  BusName=org.freedesktop.impl.portal.desktop.kiorg
                  ExecStart=@out@/libexec/xdg-desktop-portal-kiorg
                  Restart=on-failure

                  [Install]
                  WantedBy=graphical-session.target
                '';
              in
              ''
                # xdg-desktop-portal expects the binary in libexec
                mkdir -p $out/libexec
                mv $out/bin/xdg-desktop-portal-kiorg $out/libexec/xdg-desktop-portal-kiorg
                rmdir $out/bin || true

                wrapProgram $out/libexec/xdg-desktop-portal-kiorg \
                  --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath (with pkgs; [ stdenv.cc.cc.lib ])}

                install -Dm644 ${portalFile} \
                  $out/share/xdg-desktop-portal/portals/kiorg.portal

                install -Dm644 ${dbusService} \
                  $out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.kiorg.service
                substituteInPlace \
                  $out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.kiorg.service \
                  --replace-fail @out@ $out

                install -Dm644 ${systemdUnit} \
                  $out/lib/systemd/user/xdg-desktop-portal-kiorg.service
                substituteInPlace \
                  $out/lib/systemd/user/xdg-desktop-portal-kiorg.service \
                  --replace-fail @out@ $out
              '';

            meta = {
              description = "xdg-desktop-portal backend for the kiorg file manager";
              homepage = "https://github.com/houqp/kiorg";
              license = pkgs.lib.licenses.mit;
              mainProgram = "xdg-desktop-portal-kiorg";
            };
          };

          packages.default = pkgs.rustPlatform.buildRustPackage {
            pname = "kiorg";
            version = "1.5.2";
            src = ./.;
            cargoHash = "sha256-Cw100J7G7x2AsLobKjHk4tO9CHjcxOkApIYILZLMTL0=";

            cargoBuildFlags = [
              "-p"
              "kiorg"
            ];
            cargoTestFlags = [
              "-p"
              "kiorg"
            ];

            inherit nativeBuildInputs buildInputs;

            RUSTONIG_SYSTEM_LIBONIG = "1";
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            PDFIUM_DYNAMIC_LIB_PATH = "${pdfiumUnpacked}/lib/libpdfium.so";
            PDFIUM_INCLUDE_PATH = "${pdfiumUnpacked}/include";

            # skip tests that fail in nix build sandbox
            checkFlags = [
              "--skip=test_fallback_to_current_dir_when_saved_path_nonexistent"
              "--skip=test_navigate_to_nonexistent_directory_removes_from_history"
              "--skip=test_ui_navigation_mouse_click_selects_and_previews"
            ];

            postInstall = ''
              wrapProgram $out/bin/kiorg \
                --prefix LD_LIBRARY_PATH : ${
                  pkgs.lib.makeLibraryPath (
                    with pkgs;
                    [
                      vulkan-loader
                      libGL
                      wayland
                      libxkbcommon
                      libx11
                      stdenv.cc.cc.lib
                    ]
                  )
                }
            '';

            meta = {
              description = "A hacker's file manager with VIM inspired keybinds";
              homepage = "https://github.com/houqp/kiorg";
              license = pkgs.lib.licenses.mit;
              mainProgram = "kiorg";
            };
          };

          devShells.default = pkgs.mkShell {
            inherit nativeBuildInputs buildInputs;

            RUSTONIG_SYSTEM_LIBONIG = "1";
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
              with pkgs;
              [
                vulkan-loader
                libGL
                wayland
                libxkbcommon
                libx11
                stdenv.cc.cc.lib
              ]
            );

            shellHook = ''
              echo "kiorg dev shell — rust $(rustc --version)"
            '';
          };
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          perSystem = mkPerSystem system;
        in
        {
          inherit (perSystem.packages) default xdg-desktop-portal-kiorg;
        }
      );
      devShells = forAllSystems (system: (mkPerSystem system).devShells);
    };
}
