#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
    path::PathBuf,
    process::{Command, Stdio},
    sync::Mutex,
    thread,
    time::Duration,
};

#[cfg(target_os = "windows")]
use std::path::Path;

use serde::Serialize;
use tauri::{
    image::Image,
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, State, WindowEvent,
};
use tauri_plugin_deep_link::DeepLinkExt;
use tauri_plugin_opener::OpenerExt;
use url::Url;

const GUIDE_EVENT: &str = "iris-guide-opened";
const REJECTED_LINK_EVENT: &str = "iris-deep-link-rejected";
const MAX_COMMAND_OUTPUT: usize = 512;

/// A handoff from the website. `branch` and `step` are what make it a handoff
/// rather than a bookmark: without them the desktop app reopens the guide at
/// step one, on whichever branch it happened to use last, which for a mobile
/// guide is frequently the wrong phone entirely.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GuideDeepLink {
    slug: String,
    version: u32,
    branch: Option<String>,
    step: Option<u32>,
}

#[derive(Default)]
struct PendingGuide(Mutex<Option<GuideDeepLink>>);

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolVersion {
    tool: String,
    available: bool,
    version: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GitHead {
    repository_path: String,
    head: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ForegroundApp {
    platform: &'static str,
    process_id: u32,
    display_name: Option<String>,
    bundle_id: Option<String>,
    executable_path: Option<String>,
}

fn main() {
    tauri::Builder::default()
        // Tauri requires the single-instance plugin to be registered first
        // when it is forwarding desktop deep links.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let _ = show_main_window(app);
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_opener::init())
        .manage(PendingGuide::default())
        .invoke_handler(tauri::generate_handler![
            hide_iris,
            show_iris,
            quit_iris,
            resize_iris,
            glide_iris,
            open_external,
            check_tool_version,
            git_head,
            foreground_app_identity,
            take_pending_guide
        ])
        .setup(|app| {
            setup_tray(app)?;

            if let Some(window) = app.get_webview_window("main") {
                window.set_always_on_top(true)?;
                window.set_ignore_cursor_events(false)?;
                place_window(&window, "bottom-right")?;
                window.show()?;
            }

            let app_handle = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() {
                    receive_deep_link(&app_handle, &url);
                }
            });

            if let Some(urls) = app.deep_link().get_current()? {
                for url in urls {
                    receive_deep_link(app.handle(), &url);
                }
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("failed to run Iris");
}

fn setup_tray(app: &mut tauri::App) -> tauri::Result<()> {
    let show_item = MenuItem::with_id(app, "show", "Show Iris", true, None::<&str>)?;
    let hide_item = MenuItem::with_id(app, "hide", "Hide Iris", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit Iris", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show_item, &hide_item, &quit_item])?;

    TrayIconBuilder::with_id("iris-tray")
        .icon(iris_tray_icon())
        .icon_as_template(true)
        .tooltip("Iris")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                let _ = show_main_window(app);
            }
            "hide" => {
                let _ = hide_main_window(app);
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let _ = show_main_window(tray.app_handle());
            }
        })
        .build(app)?;

    Ok(())
}

fn iris_tray_icon() -> Image<'static> {
    const SIZE: u32 = 32;
    let mut rgba = vec![0_u8; (SIZE * SIZE * 4) as usize];

    for y in 0..SIZE {
        for x in 0..SIZE {
            let dx = x as f32 - 15.5;
            let dy = y as f32 - 15.5;
            let eye = (dx / 13.0).powi(2) + (dy / 8.0).powi(2);
            let pupil = dx.powi(2) + dy.powi(2);
            let visible = (0.72..=1.15).contains(&eye) || pupil <= 13.0;

            if visible {
                let offset = ((y * SIZE + x) * 4) as usize;
                rgba[offset..offset + 4].copy_from_slice(&[255, 255, 255, 255]);
            }
        }
    }

    Image::new_owned(rgba, SIZE, SIZE)
}

fn parse_guide_deep_link(url: &Url) -> Result<GuideDeepLink, &'static str> {
    if url.scheme() != "iris"
        || url.host_str() != Some("guide")
        || url.port().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err("unsupported Iris link");
    }

    let segments: Vec<_> = url
        .path_segments()
        .ok_or("missing guide slug")?
        .filter(|segment| !segment.is_empty())
        .collect();

    if segments.len() != 1 {
        return Err("Iris guide links require exactly one slug");
    }

    let slug = segments[0];
    if !valid_slug(slug) {
        return Err("invalid Iris guide slug");
    }

    // Every parameter is named, known, and allowed at most once. Anything else
    // is rejected outright rather than ignored, so a crafted link cannot smuggle
    // in a field a later version of the app might start reading.
    let mut version = None;
    let mut branch = None;
    let mut step = None;
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "version" => {
                if version.is_some() {
                    return Err("Iris guide links accept only one version parameter");
                }
                let parsed = value
                    .parse::<u32>()
                    .map_err(|_| "invalid Iris guide version")?;
                if parsed == 0 {
                    return Err("invalid Iris guide version");
                }
                version = Some(parsed);
            }
            "branch" => {
                if branch.is_some() {
                    return Err("Iris guide links accept only one branch parameter");
                }
                if !valid_branch_key(&value) {
                    return Err("invalid Iris guide branch");
                }
                branch = Some(value.into_owned());
            }
            "step" => {
                if step.is_some() {
                    return Err("Iris guide links accept only one step parameter");
                }
                // The web panel can be many steps ahead, but nothing sane is
                // past a hundred; the UI clamps to the real count anyway.
                let parsed = value.parse::<u32>().map_err(|_| "invalid Iris guide step")?;
                if parsed > 500 {
                    return Err("invalid Iris guide step");
                }
                step = Some(parsed);
            }
            _ => return Err("unsupported Iris guide parameter"),
        }
    }

    Ok(GuideDeepLink {
        slug: slug.to_owned(),
        version: version.ok_or("missing Iris guide version")?,
        branch,
        step,
    })
}

/// `computer:phone` exactly as the guide library writes it, so the desktop app
/// selects the same branch the reader was already following.
fn valid_branch_key(value: &str) -> bool {
    let Some((platform, target)) = value.split_once(':') else {
        return false;
    };
    matches!(platform, "macos" | "windows") && matches!(target, "ios" | "android" | "desktop")
}

fn valid_slug(slug: &str) -> bool {
    let bytes = slug.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
}

fn receive_deep_link(app: &AppHandle, url: &Url) {
    match parse_guide_deep_link(url) {
        Ok(guide) => {
            if let Ok(mut pending) = app.state::<PendingGuide>().0.lock() {
                *pending = Some(guide.clone());
            }
            if let Ok(window) = main_window(app) {
                let _ = place_window(&window, "bottom-right");
            }
            let _ = show_main_window(app);
            let _ = app.emit(GUIDE_EVENT, guide);
        }
        Err(reason) => {
            let _ = app.emit(REJECTED_LINK_EVENT, reason);
        }
    }
}

fn main_window(app: &AppHandle) -> Result<tauri::WebviewWindow, String> {
    app.get_webview_window("main")
        .ok_or_else(|| "Iris's main window is unavailable".to_owned())
}

fn window_anchor_position(
    window: &tauri::WebviewWindow,
    anchor: &str,
) -> Result<tauri::PhysicalPosition<i32>, String> {
    let monitor = window
        .current_monitor()
        .map_err(|error| error.to_string())?
        .or(window
            .primary_monitor()
            .map_err(|error| error.to_string())?)
        .ok_or_else(|| "Iris could not identify the current display".to_owned())?;
    let work_area = monitor.work_area();
    let size = window.outer_size().map_err(|error| error.to_string())?;
    let margin = (18.0 * monitor.scale_factor()).round() as i32;

    let left = work_area.position.x + margin;
    let top = work_area.position.y + margin;
    let right = work_area.position.x + work_area.size.width as i32 - size.width as i32 - margin;
    let bottom = work_area.position.y + work_area.size.height as i32 - size.height as i32 - margin;

    let position = match anchor {
        "top-left" => tauri::PhysicalPosition::new(left, top),
        "top-right" => tauri::PhysicalPosition::new(right, top),
        "bottom-left" => tauri::PhysicalPosition::new(left, bottom),
        "bottom-right" => tauri::PhysicalPosition::new(right, bottom),
        _ => return Err("unknown Iris window anchor".to_owned()),
    };
    Ok(position)
}

fn nearest_window_anchor(window: &tauri::WebviewWindow) -> Result<&'static str, String> {
    let monitor = window
        .current_monitor()
        .map_err(|error| error.to_string())?
        .or(window
            .primary_monitor()
            .map_err(|error| error.to_string())?)
        .ok_or_else(|| "Iris could not identify the current display".to_owned())?;
    let work_area = monitor.work_area();
    let position = window.outer_position().map_err(|error| error.to_string())?;
    let size = window.outer_size().map_err(|error| error.to_string())?;
    let window_center_x = position.x as i64 + i64::from(size.width) / 2;
    let window_center_y = position.y as i64 + i64::from(size.height) / 2;
    let display_center_x = work_area.position.x as i64 + i64::from(work_area.size.width) / 2;
    let display_center_y = work_area.position.y as i64 + i64::from(work_area.size.height) / 2;

    Ok(
        match (
            window_center_x < display_center_x,
            window_center_y < display_center_y,
        ) {
            (true, true) => "top-left",
            (false, true) => "top-right",
            (true, false) => "bottom-left",
            (false, false) => "bottom-right",
        },
    )
}

fn place_window(window: &tauri::WebviewWindow, anchor: &str) -> Result<(), String> {
    let position = window_anchor_position(window, anchor)?;
    window
        .set_position(position)
        .map_err(|error| error.to_string())
}

fn show_main_window(app: &AppHandle) -> Result<(), String> {
    let window = main_window(app)?;
    window.show().map_err(|error| error.to_string())?;
    window
        .set_always_on_top(true)
        .map_err(|error| error.to_string())?;
    window.set_focus().map_err(|error| error.to_string())
}

fn hide_main_window(app: &AppHandle) -> Result<(), String> {
    main_window(app)?.hide().map_err(|error| error.to_string())
}

#[tauri::command]
fn hide_iris(app: AppHandle) -> Result<(), String> {
    hide_main_window(&app)
}

#[tauri::command]
fn show_iris(app: AppHandle) -> Result<(), String> {
    show_main_window(&app)
}

#[tauri::command]
fn quit_iris(app: AppHandle) {
    app.exit(0);
}

fn iris_window_size(preset: &str) -> Result<(f64, f64), &'static str> {
    match preset {
        "collapsed" => Ok((292.0, 48.0)),
        "compact" => Ok((320.0, 156.0)),
        "step" => Ok((336.0, 210.0)),
        "command" => Ok((336.0, 268.0)),
        "menu" => Ok((336.0, 288.0)),
        _ => Err("unknown Iris window preset"),
    }
}

#[tauri::command]
fn resize_iris(app: AppHandle, preset: String) -> Result<(), String> {
    let (width, height) = iris_window_size(&preset).map_err(str::to_owned)?;
    let window = main_window(&app)?;
    let anchor = nearest_window_anchor(&window).unwrap_or("bottom-right");

    window
        .set_size(tauri::LogicalSize::new(width, height))
        .map_err(|error| error.to_string())?;
    place_window(&window, anchor)
}

#[tauri::command]
async fn glide_iris(app: AppHandle, anchor: String) -> Result<(), String> {
    if !matches!(
        anchor.as_str(),
        "top-left" | "top-right" | "bottom-left" | "bottom-right"
    ) {
        return Err("unknown Iris window anchor".to_owned());
    }

    let window = main_window(&app)?;
    let start = window.outer_position().map_err(|error| error.to_string())?;
    let target = window_anchor_position(&window, &anchor)?;

    tauri::async_runtime::spawn_blocking(move || {
        const FRAMES: i32 = 24;
        for frame in 1..=FRAMES {
            let progress = f64::from(frame) / f64::from(FRAMES);
            let eased = 1.0 - (1.0 - progress).powi(3);
            let x = f64::from(start.x) + f64::from(target.x - start.x) * eased;
            let y = f64::from(start.y) + f64::from(target.y - start.y) * eased;
            window
                .set_position(tauri::PhysicalPosition::new(
                    x.round() as i32,
                    y.round() as i32,
                ))
                .map_err(|error| error.to_string())?;
            thread::sleep(Duration::from_millis(12));
        }
        Ok::<(), String>(())
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
fn take_pending_guide(state: State<'_, PendingGuide>) -> Result<Option<GuideDeepLink>, String> {
    state
        .0
        .lock()
        .map_err(|_| "Iris guide state is unavailable".to_owned())
        .map(|mut pending| pending.take())
}

#[tauri::command]
fn open_external(app: AppHandle, url: String) -> Result<(), String> {
    let parsed = Url::parse(&url).map_err(|_| "invalid external URL".to_owned())?;
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed
            .fragment()
            .is_some_and(|fragment| fragment.len() > 512)
    {
        return Err("external URL is not allowed".to_owned());
    }

    let host = parsed
        .host_str()
        .ok_or_else(|| "external URL requires a host".to_owned())?;
    let allowed_https = parsed.scheme() == "https" && allowed_external_host(host);
    let allowed_local = matches!(parsed.scheme(), "http" | "https")
        && matches!(
            host.to_ascii_lowercase().as_str(),
            "localhost" | "127.0.0.1"
        );
    if !allowed_https && !allowed_local {
        return Err("external host is not allowlisted".to_owned());
    }

    app.opener()
        .open_url(parsed.as_str(), None::<&str>)
        .map_err(|error| error.to_string())
}

/// Every host a published guide can send the reader to. A guide step whose host
/// is missing here opens nothing at all in the desktop app, so this list has to
/// keep pace with `lib/iris-guides.ts`.
fn allowed_external_host(host: &str) -> bool {
    matches!(
        host.to_ascii_lowercase().as_str(),
        "publikhq.com"
            | "www.publikhq.com"
            | "github.com"
            | "docs.github.com"
            | "git-scm.com"
            | "nodejs.org"
            | "www.python.org"
            | "python.org"
            | "rustup.rs"
            | "docker.com"
            | "www.docker.com"
            | "docs.docker.com"
            | "developer.apple.com"
            | "learn.microsoft.com"
            // Toolchains and assets the current guides link to.
            | "apps.apple.com"
            | "developer.android.com"
            | "huggingface.co"
            | "visualstudio.microsoft.com"
            | "cmake.org"
            | "www.cmake.org"
            // Astro's Windows route. Missing here, "Install BrowserOS" — step 2
            // of that branch — opened nothing at all in the desktop app, which
            // reads as a dead button rather than a blocked host.
            | "files.browseros.com"
            | "go.dev"
            // Halation sends the reader to fal for a key. Without the host
            // here the button opens nothing, which reads as the guide being
            // broken at the one step that cannot be skipped.
            | "fal.ai"
            | "www.fal.ai"
            | "www.nasm.us"
            | "nasm.us"
            // Dripwriter Origin installs from the Chrome Web Store and is
            // verified inside a Google Doc; Nutcracker is served from GitHub
            // Pages. Absent here, those guides' open buttons would do nothing.
            | "chromewebstore.google.com"
            | "docs.google.com"
            | "blueturboguy07.github.io"
    )
}

#[tauri::command]
async fn check_tool_version(tool: String) -> Result<ToolVersion, String> {
    tauri::async_runtime::spawn_blocking(move || check_tool_version_blocking(&tool))
        .await
        .map_err(|error| error.to_string())?
}

fn check_tool_version_blocking(tool: &str) -> Result<ToolVersion, String> {
    let (executable, args) =
        tool_spec(tool).ok_or_else(|| format!("tool '{tool}' is not allowlisted"))?;
    let fallback_paths = trusted_tool_fallback_paths(tool);
    let Some(executable_path) =
        select_tool_executable(tool, which::which(executable), &fallback_paths)?
    else {
        return Ok(unavailable_tool_version(tool));
    };
    let output = Command::new(&executable_path)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("could not inspect '{tool}': {error}"))?;

    let version = bounded_command_output(&output.stdout, &output.stderr);
    if !output.status.success() {
        #[cfg(target_os = "macos")]
        if is_missing_macos_git_developer_tools(tool, &version) {
            return Ok(unavailable_tool_version(tool));
        }
        return Err(if version.is_empty() {
            format!("'{tool}' version check failed")
        } else {
            format!("'{tool}' version check failed: {version}")
        });
    }
    if version.is_empty() {
        return Err(format!("'{tool}' returned an empty version"));
    }

    Ok(ToolVersion {
        tool: tool.to_owned(),
        available: true,
        version,
    })
}

fn unavailable_tool_version(tool: &str) -> ToolVersion {
    ToolVersion {
        tool: tool.to_owned(),
        available: false,
        version: String::new(),
    }
}

fn is_missing_macos_git_developer_tools(tool: &str, output: &str) -> bool {
    if tool != "git" {
        return false;
    }

    let normalized = output.to_ascii_lowercase();
    (normalized.contains("xcrun: error: invalid active developer path")
        && normalized.contains("missing xcrun at:"))
        || normalized.contains("xcode-select: note: no developer tools were found")
}

fn select_tool_executable(
    tool: &str,
    path_lookup: which::Result<PathBuf>,
    trusted_fallbacks: &[PathBuf],
) -> Result<Option<PathBuf>, String> {
    match path_lookup {
        Ok(path) => Ok(Some(path)),
        Err(which::Error::CannotFindBinaryPath) => Ok(trusted_fallbacks
            .iter()
            .find(|path| path.is_file())
            .cloned()),
        Err(error) => Err(format!("could not locate '{tool}': {error}")),
    }
}

#[cfg(target_os = "macos")]
fn trusted_tool_fallback_paths(tool: &str) -> Vec<PathBuf> {
    let candidates: &[&str] = match tool {
        "git" => &[
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ],
        "node" => &["/opt/homebrew/bin/node", "/usr/local/bin/node"],
        _ => &[],
    };
    candidates.iter().map(PathBuf::from).collect()
}

#[cfg(target_os = "windows")]
fn trusted_tool_fallback_paths(tool: &str) -> Vec<PathBuf> {
    let mut paths = Vec::new();

    for variable in ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"] {
        let Some(root) = std::env::var_os(variable) else {
            continue;
        };
        let root = PathBuf::from(root);
        match tool {
            "git" => {
                push_unique_path(&mut paths, root.join("Git").join("cmd").join("git.exe"));
                push_unique_path(&mut paths, root.join("Git").join("bin").join("git.exe"));
            }
            "node" => {
                push_unique_path(&mut paths, root.join("nodejs").join("node.exe"));
            }
            _ => {}
        }
    }

    if let Some(root) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) {
        match tool {
            "git" => push_unique_path(
                &mut paths,
                root.join("Programs")
                    .join("Git")
                    .join("cmd")
                    .join("git.exe"),
            ),
            "node" => push_unique_path(
                &mut paths,
                root.join("Programs").join("nodejs").join("node.exe"),
            ),
            _ => {}
        }
    }

    paths
}

#[cfg(target_os = "windows")]
fn push_unique_path(paths: &mut Vec<PathBuf>, candidate: PathBuf) {
    if !paths.contains(&candidate) {
        paths.push(candidate);
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn trusted_tool_fallback_paths(_tool: &str) -> Vec<PathBuf> {
    Vec::new()
}

fn tool_spec(tool: &str) -> Option<(&'static str, &'static [&'static str])> {
    match tool {
        "git" => Some(("git", &["--version"])),
        "node" => Some(("node", &["--version"])),
        "npm" => Some(("npm", &["--version"])),
        "pnpm" => Some(("pnpm", &["--version"])),
        "bun" => Some(("bun", &["--version"])),
        "python" => Some(("python", &["--version"])),
        "python3" => Some(("python3", &["--version"])),
        "uv" => Some(("uv", &["--version"])),
        "cargo" => Some(("cargo", &["--version"])),
        "rustc" => Some(("rustc", &["--version"])),
        "docker" => Some(("docker", &["--version"])),
        "java" => Some(("java", &["--version"])),
        "adb" => Some(("adb", &["version"])),
        "xcodebuild" => Some(("xcodebuild", &["-version"])),
        _ => None,
    }
}

#[tauri::command]
async fn git_head(repository_path: String) -> Result<GitHead, String> {
    tauri::async_runtime::spawn_blocking(move || git_head_blocking(&repository_path))
        .await
        .map_err(|error| error.to_string())?
}

fn git_head_blocking(repository_path: &str) -> Result<GitHead, String> {
    let repository = allowed_repository_path(repository_path)?;
    let git = which::which("git").map_err(|_| "Git is not installed".to_owned())?;
    let output = Command::new(git)
        .args(["--no-optional-locks", "-C"])
        .arg(&repository)
        .args(["rev-parse", "--verify", "HEAD^{commit}"])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("could not inspect Git repository: {error}"))?;

    if !output.status.success() {
        return Err("path is not a readable Git repository".to_owned());
    }

    let head = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !matches!(head.len(), 40 | 64) || !head.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("Git returned an invalid commit identifier".to_owned());
    }

    Ok(GitHead {
        repository_path: repository.to_string_lossy().into_owned(),
        head,
    })
}

fn allowed_repository_path(repository_path: &str) -> Result<PathBuf, String> {
    if repository_path.is_empty() || repository_path.len() > 4096 {
        return Err("invalid repository path".to_owned());
    }

    let repository = std::fs::canonicalize(repository_path)
        .map_err(|_| "repository path does not exist".to_owned())?;
    let home = dirs::home_dir()
        .ok_or_else(|| "home directory is unavailable".to_owned())
        .and_then(|path| {
            std::fs::canonicalize(path).map_err(|_| "home directory is unavailable".to_owned())
        })?;

    if repository == home || !repository.starts_with(&home) || !repository.is_dir() {
        return Err("repository must be a directory inside the current user's home".to_owned());
    }

    let git_metadata = repository.join(".git");
    if !git_metadata.exists() {
        return Err("path is not a Git working tree".to_owned());
    }

    Ok(repository)
}

#[tauri::command]
fn foreground_app_identity() -> Result<ForegroundApp, String> {
    platform_foreground_app()
}

fn bounded_command_output(stdout: &[u8], stderr: &[u8]) -> String {
    let source = if stdout.is_empty() { stderr } else { stdout };
    String::from_utf8_lossy(source)
        .chars()
        .filter(|character| !character.is_control() || *character == '\n' || *character == '\t')
        .take(MAX_COMMAND_OUTPUT)
        .collect::<String>()
        .trim()
        .to_owned()
}

#[cfg(target_os = "macos")]
fn platform_foreground_app() -> Result<ForegroundApp, String> {
    use objc2_app_kit::NSWorkspace;

    let application = NSWorkspace::sharedWorkspace()
        .frontmostApplication()
        .ok_or_else(|| "no foreground application is available".to_owned())?;

    let process_id = application.processIdentifier();
    Ok(ForegroundApp {
        platform: "macos",
        process_id: u32::try_from(process_id).unwrap_or_default(),
        display_name: application.localizedName().map(|value| value.to_string()),
        bundle_id: application
            .bundleIdentifier()
            .map(|value| value.to_string()),
        executable_path: application
            .executableURL()
            .and_then(|url| url.path())
            .map(|value| value.to_string()),
    })
}

#[cfg(target_os = "windows")]
fn platform_foreground_app() -> Result<ForegroundApp, String> {
    use std::{ffi::OsString, os::windows::ffi::OsStringExt};
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
        },
        UI::WindowsAndMessaging::{
            GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
        },
    };

    unsafe {
        let window = GetForegroundWindow();
        if window.is_null() {
            return Err("no foreground application is available".to_owned());
        }

        let mut process_id = 0_u32;
        GetWindowThreadProcessId(window, &mut process_id);
        if process_id == 0 {
            return Err("could not identify the foreground process".to_owned());
        }

        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id);
        if process.is_null() {
            return Err("could not inspect the foreground process".to_owned());
        }

        let mut executable_buffer = vec![0_u16; 32_768];
        let mut executable_length = executable_buffer.len() as u32;
        let executable_ok = QueryFullProcessImageNameW(
            process,
            0,
            executable_buffer.as_mut_ptr(),
            &mut executable_length,
        );
        CloseHandle(process);

        let executable_path = if executable_ok != 0 {
            Some(
                PathBuf::from(OsString::from_wide(
                    &executable_buffer[..executable_length as usize],
                ))
                .to_string_lossy()
                .into_owned(),
            )
        } else {
            None
        };

        let title_length = GetWindowTextLengthW(window);
        let display_name = if title_length > 0 {
            let mut title = vec![0_u16; title_length as usize + 1];
            let copied = GetWindowTextW(window, title.as_mut_ptr(), title.len() as i32);
            (copied > 0).then(|| {
                OsString::from_wide(&title[..copied as usize])
                    .to_string_lossy()
                    .into_owned()
            })
        } else {
            executable_path
                .as_deref()
                .and_then(|path| Path::new(path).file_stem())
                .map(|name| name.to_string_lossy().into_owned())
        };

        Ok(ForegroundApp {
            platform: "windows",
            process_id,
            display_name,
            bundle_id: None,
            executable_path,
        })
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn platform_foreground_app() -> Result<ForegroundApp, String> {
    Err("Iris supports foreground-app inspection only on macOS and Windows".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_one_exact_versioned_guide_link() {
        let parsed =
            parse_guide_deep_link(&Url::parse("iris://guide/cue?version=7").unwrap()).unwrap();
        assert_eq!(parsed.slug, "cue");
        assert_eq!(parsed.version, 7);
        assert_eq!(parsed.branch, None);
        assert_eq!(parsed.step, None);
    }

    #[test]
    fn carries_the_reader_s_place_across_the_handoff() {
        let parsed = parse_guide_deep_link(
            &Url::parse("iris://guide/lunara?version=1&branch=macos:android&step=6").unwrap(),
        )
        .unwrap();
        assert_eq!(parsed.slug, "lunara");
        assert_eq!(parsed.branch.as_deref(), Some("macos:android"));
        assert_eq!(parsed.step, Some(6));

        // Step zero is the first step, not a missing one.
        let first =
            parse_guide_deep_link(&Url::parse("iris://guide/cue?version=3&step=0").unwrap())
                .unwrap();
        assert_eq!(first.step, Some(0));
    }

    #[test]
    fn rejects_broadened_or_ambiguous_guide_links() {
        for value in [
            "iris://guide/cue",
            "iris://guide/cue/extra?version=1",
            "iris://guide/Cue?version=1",
            "iris://guide/cue?version=0",
            "iris://guide/cue?version=1&version=2",
            "iris://guide/cue?version=1&platform=macos",
            "https://publikhq.com/cue?version=1",
            // A resume point still has to be one of the shapes the guide
            // library can actually produce.
            "iris://guide/cue?version=1&branch=linux:desktop",
            "iris://guide/cue?version=1&branch=macos",
            "iris://guide/cue?version=1&branch=macos:watch",
            "iris://guide/cue?version=1&branch=macos:desktop&branch=windows:desktop",
            "iris://guide/cue?version=1&step=-1",
            "iris://guide/cue?version=1&step=9000",
            "iris://guide/cue?version=1&step=2&step=3",
        ] {
            assert!(
                parse_guide_deep_link(&Url::parse(value).unwrap()).is_err(),
                "should have rejected {value}"
            );
        }
    }

    #[test]
    fn tool_checks_are_closed_to_known_version_commands() {
        assert_eq!(tool_spec("git"), Some(("git", &["--version"][..])));
        assert_eq!(
            tool_spec("xcodebuild"),
            Some(("xcodebuild", &["-version"][..]))
        );
        assert_eq!(tool_spec("sh"), None);
        assert_eq!(tool_spec("curl"), None);
        assert_eq!(tool_spec("git --version"), None);
    }

    #[test]
    fn missing_tool_is_data_but_lookup_failures_remain_errors() {
        let missing =
            select_tool_executable("node", Err(which::Error::CannotFindBinaryPath), &[]).unwrap();
        assert_eq!(missing, None);

        let lookup_error =
            select_tool_executable("node", Err(which::Error::CannotCanonicalize), &[]);
        assert!(lookup_error.is_err());

        let response = ToolVersion {
            tool: "node".to_owned(),
            available: false,
            version: String::new(),
        };
        let serialized = serde_json::to_value(response).unwrap();
        assert_eq!(serialized["available"], false);
        assert_eq!(serialized["version"], "");
    }

    #[test]
    fn only_known_macos_git_developer_tools_errors_mean_missing() {
        let missing_xcrun = "xcrun: error: invalid active developer path \
            (/Library/Developer/CommandLineTools), missing xcrun at: \
            /Library/Developer/CommandLineTools/usr/bin/xcrun";
        let no_developer_tools =
            "xcode-select: note: No developer tools were found, requesting install.";

        assert!(is_missing_macos_git_developer_tools("git", missing_xcrun));
        assert!(is_missing_macos_git_developer_tools(
            "git",
            no_developer_tools
        ));
        assert!(!is_missing_macos_git_developer_tools("node", missing_xcrun));
        assert!(!is_missing_macos_git_developer_tools(
            "git",
            "xcrun: error: SDK \"macosx\" cannot be located"
        ));
        assert!(!is_missing_macos_git_developer_tools(
            "git",
            "xcode-select: error: invalid developer directory"
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_fallbacks_are_fixed_and_limited_to_git_and_node() {
        assert_eq!(
            trusted_tool_fallback_paths("git"),
            vec![
                PathBuf::from("/opt/homebrew/bin/git"),
                PathBuf::from("/usr/local/bin/git"),
                PathBuf::from("/usr/bin/git"),
            ]
        );
        assert_eq!(
            trusted_tool_fallback_paths("node"),
            vec![
                PathBuf::from("/opt/homebrew/bin/node"),
                PathBuf::from("/usr/local/bin/node"),
            ]
        );
        assert!(trusted_tool_fallback_paths("sh").is_empty());
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_fallbacks_are_limited_to_git_and_node() {
        assert!(trusted_tool_fallback_paths("sh").is_empty());
        assert!(trusted_tool_fallback_paths("git")
            .iter()
            .all(|path| path.ends_with("git.exe")));
        assert!(trusted_tool_fallback_paths("node")
            .iter()
            .all(|path| path.ends_with("node.exe")));
    }

    #[test]
    fn external_hosts_are_explicitly_allowlisted() {
        assert!(allowed_external_host("publikhq.com"));
        assert!(allowed_external_host("github.com"));
        assert!(allowed_external_host("git-scm.com"));
        // Hosts the published guides link to.
        assert!(allowed_external_host("apps.apple.com"));
        assert!(allowed_external_host("developer.android.com"));
        assert!(allowed_external_host("huggingface.co"));
        assert!(allowed_external_host("visualstudio.microsoft.com"));
        assert!(allowed_external_host("cmake.org"));
        assert!(!allowed_external_host("www.git-scm.com"));
        assert!(!allowed_external_host("git-scm.com.attacker.example"));
        assert!(!allowed_external_host("publikhq.com.attacker.example"));
        assert!(!allowed_external_host("example.com"));
    }

    #[test]
    fn window_presets_are_small_and_exact() {
        assert_eq!(iris_window_size("collapsed"), Ok((292.0, 48.0)));
        assert_eq!(iris_window_size("compact"), Ok((320.0, 156.0)));
        assert_eq!(iris_window_size("step"), Ok((336.0, 210.0)));
        assert_eq!(iris_window_size("command"), Ok((336.0, 268.0)));
        assert_eq!(iris_window_size("menu"), Ok((336.0, 288.0)));

        for preset in ["collapsed", "compact", "step", "command", "menu"] {
            let (width, height) = iris_window_size(preset).unwrap();
            assert!((292.0..=336.0).contains(&width));
            assert!((48.0..=288.0).contains(&height));
        }
    }

    #[test]
    fn window_presets_reject_arbitrary_sizes() {
        assert!(iris_window_size("400").is_err());
        assert!(iris_window_size("fullscreen").is_err());
        assert!(iris_window_size("").is_err());
    }
}
