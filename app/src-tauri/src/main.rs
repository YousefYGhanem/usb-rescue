// USB Rescue desktop app: a window around Recover-UsbDrive.ps1, which does all the recovery work.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{BufRead, BufReader, Read, Write};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};

// The script is compiled into the exe, so the app is one portable file.
const SCRIPT: &str = include_str!("../../../Recover-UsbDrive.ps1");
const NO_WINDOW: u32 = 0x0800_0000;
const HELP_URL: &str = "https://github.com/YousefYGhanem/usb-rescue#troubleshooting";

/// Process id of the running rescue, if any.
#[derive(Default)]
struct Run(Mutex<Option<u32>>);

fn system32(exe: &str) -> PathBuf {
    // Full paths: this process runs as Administrator, so never let PATH pick the program.
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    Path::new(&root).join("System32").join(exe)
}

/// A PowerShell single-quoted string literal.
fn ps_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// Start the script with these arguments. It is piped in through stdin and never written to disk,
/// so nothing else on the PC can swap it before it runs as Administrator.
fn run_script(args: &[String]) -> std::io::Result<Child> {
    let loader = format!("& ([scriptblock]::Create([Console]::In.ReadToEnd())) {}", args.join(" "));
    let mut child = Command::new(system32(r"WindowsPowerShell\v1.0\powershell.exe"))
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", &loader])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(NO_WINDOW)
        .spawn()?;
    let mut stdin = child.stdin.take().expect("stdin is piped");
    stdin.write_all(SCRIPT.as_bytes())?;
    Ok(child) // stdin is dropped here, which ends the script text
}

/// Calls `f` for each output line. Lossy UTF-8, so a strange file name can't stop the reading.
fn each_line(r: impl Read, mut f: impl FnMut(String)) {
    let mut r = BufReader::new(r);
    let mut buf = Vec::new();
    while matches!(r.read_until(b'\n', &mut buf), Ok(n) if n > 0) {
        f(String::from_utf8_lossy(&buf).trim_end().to_string());
        buf.clear();
    }
}

fn kill(pid: u32) {
    // /T also stops robocopy, chkdsk or PhotoRec started by the script. It resumes on the next run.
    let _ = Command::new(system32("taskkill.exe"))
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .creation_flags(NO_WINDOW)
        .status();
}

#[tauri::command]
async fn list_drives() -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let out = run_script(&["-ListDrives".into()]).and_then(|c| c.wait_with_output()).map_err(|e| e.to_string())?;
        let text = String::from_utf8_lossy(&out.stdout);
        match text.lines().find_map(|l| l.strip_prefix("@@")) {
            Some(j) => serde_json::from_str(j).map_err(|e| e.to_string()),
            None => Err(format!("Could not list drives. {}", String::from_utf8_lossy(&out.stderr).trim())),
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
fn start_rescue(app: AppHandle, run: State<Run>, disk: u32, out_dir: String, carve: bool) -> Result<(), String> {
    let mut slot = run.0.lock().unwrap();
    if slot.is_some() {
        return Err("A rescue is already running.".into());
    }
    let mut args = vec!["-Events".into(), "-Yes".into(), format!("-DiskNumber {disk}"), format!("-OutDir {}", ps_quote(&out_dir))];
    if carve {
        args.push("-Carve".into());
    }
    let mut child = run_script(&args).map_err(|e| e.to_string())?;
    *slot = Some(child.id());

    let stderr = child.stderr.take().expect("stderr is piped");
    let a = app.clone();
    std::thread::spawn(move || each_line(stderr, |l| { let _ = a.emit("rescue-log", l); }));

    let stdout = child.stdout.take().expect("stdout is piped");
    std::thread::spawn(move || {
        each_line(stdout, |l| match l.strip_prefix("@@").and_then(|j| serde_json::from_str::<serde_json::Value>(j).ok()) {
            Some(v) => { let _ = app.emit("rescue-event", v); }
            None => { let _ = app.emit("rescue-log", l); }
        });
        let code = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
        app.state::<Run>().0.lock().unwrap().take();
        let _ = app.emit("rescue-exit", code);
    });
    Ok(())
}

#[tauri::command]
fn stop_rescue(run: State<Run>) {
    if let Some(pid) = *run.0.lock().unwrap() {
        kill(pid);
    }
}

/// Show a folder in Explorer, or open the help page.
#[tauri::command]
fn open_path(path: String) -> Result<(), String> {
    let target = if path == "help" { HELP_URL.to_string() } else if Path::new(&path).exists() { path } else { return Err("That folder no longer exists.".into()) };
    Command::new(system32(r"..\explorer.exe")).arg(target).spawn().map(|_| ()).map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Run::default())
        .invoke_handler(tauri::generate_handler![list_drives, start_rescue, stop_rescue, open_path])
        .on_window_event(|w, e| {
            // Closing the window stops the rescue too; the next run resumes where it stopped.
            if let tauri::WindowEvent::Destroyed = e {
                if let Some(pid) = *w.state::<Run>().0.lock().unwrap() {
                    kill(pid);
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running USB Rescue");
}
