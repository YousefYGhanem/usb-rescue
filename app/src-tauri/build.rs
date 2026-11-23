fn main() {
    // The script reads raw disks and mounts the copy, so the exe always asks for Administrator rights.
    let win = tauri_build::WindowsAttributes::new().app_manifest(include_str!("app.manifest"));
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(win)).expect("failed to run tauri-build");
    println!("cargo:rerun-if-changed=../../Recover-UsbDrive.ps1");
}
