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
          packages.default = pkgs.rustPlatform.buildRustPackage {
            pname = "kiorg";
            version = "1.5.2";
            src = ./.;
            cargoHash = "sha256-Cw100J7G7x2AsLobKjHk4tO9CHjcxOkApIYILZLMTL0=";

            cargoBuildFlags = [
              "-p"
              "kiorg"
              "-p"
              "kiorg-portal"
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
              install -Dm755 target/${pkgs.stdenv.hostPlatform.rust.rustcTargetSpec}/release/xdg-desktop-portal-kiorg $out/bin/xdg-desktop-portal-kiorg
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
              wrapProgram $out/bin/xdg-desktop-portal-kiorg \
                --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath (with pkgs; [ stdenv.cc.cc.lib ])}
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
      packages = forAllSystems (system: (mkPerSystem system).packages);
      devShells = forAllSystems (system: (mkPerSystem system).devShells);
    };
}
