//! xdg-desktop-portal backend for kiorg.
//!
//! Implements `org.freedesktop.impl.portal.FileChooser` via zbus.
//! When a portal request arrives, this daemon spawns `kiorg --pick-mode <tmpfile> [flags]`,
//! waits for it to exit, then reads the result file and returns paths over D-Bus.
//!
//! Install:
//!   - Binary  → /usr/lib/xdg-desktop-portal-kiorg (or ~/bin, on PATH)
//!   - Portal  → /usr/share/xdg-desktop-portal/portals/kiorg.portal
//!   - Service → /usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.kiorg.service
//!   - Systemd → ~/.config/systemd/user/xdg-desktop-portal-kiorg.service  (optional)

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;

use tracing::{error, info};
use zbus::connection::Builder;
use zbus::interface;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

// ── D-Bus response codes ────────────────────────────────────────────────────

const RESPONSE_SUCCESS: u32 = 0;
const RESPONSE_CANCELLED: u32 = 1;
const RESPONSE_OTHER: u32 = 2;

// ── Helper: locate the kiorg binary ─────────────────────────────────────────

fn kiorg_binary() -> PathBuf {
    // Honour an explicit override first
    if let Ok(p) = std::env::var("KIORG_BINARY") {
        return PathBuf::from(p);
    }
    // If we're running from a Cargo target directory, prefer the sibling
    // debug/release build so `cargo run -p kiorg-portal` just works.
    if let Ok(exe) = std::env::current_exe() {
        // exe is e.g. .../target/debug/xdg-desktop-portal-kiorg
        // kiorg sits at    .../target/debug/kiorg
        let sibling = exe.parent().map(|p| p.join("kiorg"));
        if let Some(path) = sibling {
            if path.is_file() {
                return path;
            }
        }
    }
    // Walk PATH
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in path_var.split(':') {
            let candidate = PathBuf::from(dir).join("kiorg");
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    PathBuf::from("kiorg")
}

// ── Portal interface implementation ─────────────────────────────────────────

struct FileChooserPortal;

#[interface(name = "org.freedesktop.impl.portal.FileChooser")]
impl FileChooserPortal {
    /// OpenFile portal method.
    ///
    /// `options` keys we handle:
    ///   - `multiple`       (bool)  – allow multi-select
    ///   - `directory`      (bool)  – select directories
    ///   - `current_folder` (Vec<u8>) – initial directory (null-terminated UTF-8)
    async fn open_file(
        &self,
        _handle: OwnedObjectPath,
        _app_id: &str,
        _parent_window: &str,
        _title: &str,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        let multiple = bool_opt(&options, "multiple");
        let directory = bool_opt(&options, "directory");
        let initial_dir = current_folder_opt(&options);

        run_kiorg_picker(multiple, directory, false, initial_dir).await
    }

    /// SaveFile portal method.
    async fn save_file(
        &self,
        _handle: OwnedObjectPath,
        _app_id: &str,
        _parent_window: &str,
        _title: &str,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        let initial_dir = current_folder_opt(&options);
        run_kiorg_picker(false, false, true, initial_dir).await
    }

    /// SaveFiles portal method (multi-file save).
    async fn save_files(
        &self,
        _handle: OwnedObjectPath,
        _app_id: &str,
        _parent_window: &str,
        _title: &str,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        let initial_dir = current_folder_opt(&options);
        run_kiorg_picker(true, false, true, initial_dir).await
    }
}

// ── Core logic: spawn kiorg in picker mode and collect result ────────────────

async fn run_kiorg_picker(
    multiple: bool,
    directory_only: bool,
    save_mode: bool,
    initial_dir: Option<PathBuf>,
) -> (u32, HashMap<String, OwnedValue>) {
    // Temp file kiorg will write selected paths into
    let tmp = match tempfile::NamedTempFile::new() {
        Ok(f) => f,
        Err(e) => {
            error!("Failed to create temp file: {e}");
            return (RESPONSE_OTHER, HashMap::new());
        }
    };
    let result_path = tmp.path().to_path_buf();
    // Keep the NamedTempFile alive until we're done reading
    let _tmp_guard = tmp;

    let kiorg = kiorg_binary();
    let mut cmd = tokio::process::Command::new(&kiorg);
    cmd.arg("--pick-mode").arg(&result_path);
    if multiple {
        cmd.arg("--pick-multiple");
    }
    if directory_only {
        cmd.arg("--pick-directory");
    }
    if save_mode {
        cmd.arg("--pick-save");
    }
    if let Some(dir) = initial_dir {
        cmd.arg(dir);
    }
    cmd.stdin(Stdio::null());

    info!("Spawning kiorg picker: {:?}", cmd);

    let status = match cmd.status().await {
        Ok(s) => s,
        Err(e) => {
            error!("Failed to spawn kiorg: {e}");
            return (RESPONSE_OTHER, HashMap::new());
        }
    };

    if !status.success() {
        // Non-zero exit = user cancelled
        return (RESPONSE_CANCELLED, HashMap::new());
    }

    // Read selected paths (newline-separated)
    let content = match tokio::fs::read_to_string(&result_path).await {
        Ok(c) => c,
        Err(e) => {
            error!("Failed to read picker result: {e}");
            return (RESPONSE_OTHER, HashMap::new());
        }
    };

    let uris: Vec<String> = content
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            // Convert path to file:// URI
            let path = PathBuf::from(l);
            format!("file://{}", path.to_string_lossy())
        })
        .collect();

    if uris.is_empty() {
        return (RESPONSE_CANCELLED, HashMap::new());
    }

    let mut results: HashMap<String, OwnedValue> = HashMap::new();
    // Build an Array<String> → Value → OwnedValue
    let arr = zbus::zvariant::Array::from(uris);
    let uris_value: OwnedValue = Value::Array(arr)
        .try_into()
        .unwrap_or_else(|_| OwnedValue::from(0u8));
    results.insert("uris".to_string(), uris_value);

    (RESPONSE_SUCCESS, results)
}

// ── Option helpers ────────────────────────────────────────────────────────────

fn bool_opt(options: &HashMap<String, OwnedValue>, key: &str) -> bool {
    options
        .get(key)
        .and_then(|v| bool::try_from(v).ok())
        .unwrap_or(false)
}

fn current_folder_opt(options: &HashMap<String, OwnedValue>) -> Option<PathBuf> {
    // current_folder is sent as Vec<u8> (null-terminated path)
    options.get("current_folder").and_then(|v| {
        // OwnedValue doesn't impl Clone; go through Value<'_>
        let val: Value<'_> = Value::try_from(v).ok()?;
        let bytes: Vec<u8> = if let Value::Array(arr) = val {
            arr.iter()
                .filter_map(|v| u8::try_from(v).ok())
                .collect()
        } else {
            return None;
        };
        let s = std::ffi::CStr::from_bytes_until_nul(&bytes)
            .ok()
            .and_then(|c| c.to_str().ok())
            .map(str::to_owned)
            .or_else(|| String::from_utf8(bytes.clone()).ok())?;
        let p = PathBuf::from(s);
        if p.is_dir() { Some(p) } else { None }
    })
}

// ── Entry point ───────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    info!("xdg-desktop-portal-kiorg starting");

    let _conn = Builder::session()?
        .name("org.freedesktop.impl.portal.desktop.kiorg")?
        .serve_at(
            "/org/freedesktop/portal/desktop",
            FileChooserPortal,
        )?
        .build()
        .await?;

    info!("D-Bus portal registered — waiting for requests");

    // Block forever
    std::future::pending::<()>().await;
    Ok(())
}
