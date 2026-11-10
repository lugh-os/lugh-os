//! Generates the C++ side of `src/bridge.rs` (cxx-qt), runs moc on
//! `cpp/native.h` and compiles `cpp/host.cpp`. With the `embed-qml` feature it
//! also compiles the QML tree into the binary (see `embed_qml`).

use std::path::{Path, PathBuf};
use std::process::Command;

use cxx_qt_build::CxxQtBuilder;

fn main() {
    let mut builder = CxxQtBuilder::new()
        .file("src/bridge.rs")
        .qt_module("Gui")
        .qt_module("Qml")
        .qt_module("Quick")
        .cpp_file("cpp/native.h")
        .cpp_file("cpp/host.cpp");
    println!("cargo::rerun-if-changed=cpp/host.h");

    // host.cpp calls lugh_embedded_qml_init() at start-up. That reference is
    // what keeps the resource objects in the link (objects of a static
    // library that nothing refers to are dropped, static initialisers and all).
    let embed = std::env::var_os("CARGO_FEATURE_EMBED_QML").is_some();
    let init = PathBuf::from(std::env::var_os("OUT_DIR").unwrap_or_default()).join("lugh_embed_init.cpp");
    let body = if embed {
        "int qInitResources_lugh_qml();\nint qInitResources_qmlcache_lugh_qml();\n\
         void lugh_embedded_qml_init() { qInitResources_lugh_qml(); qInitResources_qmlcache_lugh_qml(); }\n"
    } else {
        "void lugh_embedded_qml_init() {}\n"
    };
    std::fs::write(&init, body).unwrap_or_else(|e| panic!("build: {e}"));
    builder = builder.cpp_file(init);
    if embed {
        for generated in embed_qml() {
            builder = builder.cpp_file(generated);
        }
    }
    builder.build();
}

/// Files of the embedded tree as (resource path under `/lugh/qml`, source file).
fn qml_tree() -> Vec<(String, PathBuf)> {
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap_or_default());
    let mut files = vec![("main.qml".to_owned(), manifest.join("qml/main.qml"))];
    let roots = [
        ("Lugh/Shell", manifest.join("qml/Lugh/Shell")),
        ("Lugh/UI", manifest.join("../components/Lugh/UI")),
        ("fonts", manifest.join("../components/fonts")),
    ];
    for (prefix, dir) in roots {
        println!("cargo::rerun-if-changed={}", dir.display());
        collect(&dir, prefix, &mut files);
    }
    files.sort();
    files
}

fn collect(dir: &Path, prefix: &str, out: &mut Vec<(String, PathBuf)>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        panic!("embed-qml: cannot read {}", dir.display());
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        let alias = format!("{prefix}/{name}");
        if path.is_dir() {
            collect(&path, &alias, out);
        } else if ["qml", "js", "mjs", "png", "svg", "ttf", "otf"]
            .iter()
            .any(|ext| name.ends_with(&format!(".{ext}")))
            || name == "qmldir"
        {
            out.push((alias, path));
        }
    }
}

/// Embeds the tree as Qt resources under `qrc:/lugh/qml` and compiles every
/// `.qml`/`.js` to QML bytecode with qmlcachegen, so nothing is parsed or
/// compiled at start-up. Returns the generated C++ files.
fn embed_qml() -> Vec<PathBuf> {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap_or_default()).join("embed-qml");
    std::fs::create_dir_all(&out).unwrap_or_else(|e| panic!("embed-qml: {e}"));
    let files = qml_tree();

    let mut qrc = String::from("<RCC>\n<qresource prefix=\"/lugh/qml\">\n");
    for (alias, path) in &files {
        qrc.push_str(&format!("<file alias=\"{alias}\">{}</file>\n", path.display()));
    }
    qrc.push_str("</qresource>\n</RCC>\n");
    let qrc_path = out.join("lugh_qml.qrc");
    std::fs::write(&qrc_path, qrc).unwrap_or_else(|e| panic!("embed-qml: {e}"));

    let libexec = qt_dir("QT_INSTALL_LIBEXECS");
    let bins = qt_dir("QT_INSTALL_BINS");
    let tool = |name: &str| {
        [libexec.join(name), bins.join(name)]
            .into_iter()
            .find(|p| p.is_file())
            .unwrap_or_else(|| panic!("embed-qml: {name} not found (qt6-declarative-dev-tools)"))
    };
    let (qmlcachegen, rcc) = (tool("qmlcachegen"), tool("rcc"));

    let mut generated = Vec::new();
    let mut compiled = Vec::new(); // resource paths of the compiled units
    for (i, (alias, path)) in files.iter().enumerate() {
        if !(alias.ends_with(".qml") || alias.ends_with(".js") || alias.ends_with(".mjs")) {
            continue;
        }
        let cpp = out.join(format!("unit_{i}.cpp"));
        // Bytecode only: no C++ type compilation, which would need Qt's
        // private headers and every imported module's type info.
        run(Command::new(&qmlcachegen)
            .arg("--bare")
            .arg("--only-bytecode")
            .arg("--resource-path")
            .arg(format!("/lugh/qml/{alias}"))
            .arg("-o")
            .arg(&cpp)
            .arg(path));
        generated.push(cpp);
        compiled.push(format!("/lugh/qml/{alias}"));
    }
    // qmlcachegen recognises the loader by this file-name suffix.
    let loader = out.join("lugh_qmlcache_loader.cpp");
    // The loader takes the compiled resource paths as a response file.
    let list = out.join("lugh_qml_loader.rsp");
    std::fs::write(&list, compiled.join("\n")).unwrap_or_else(|e| panic!("embed-qml: {e}"));
    run(Command::new(&qmlcachegen)
        .arg("--resource-name")
        .arg("qmlcache_lugh_qml")
        .arg("-o")
        .arg(&loader)
        .arg(format!("@{}", list.display())));
    generated.push(loader);
    let resources = out.join("lugh_qml_rcc.cpp");
    run(Command::new(&rcc)
        .arg("--name")
        .arg("lugh_qml")
        .arg("-o")
        .arg(&resources)
        .arg(&qrc_path));
    generated.push(resources);
    generated
}

fn qt_dir(key: &str) -> PathBuf {
    let qmake = std::env::var("QMAKE").unwrap_or_else(|_| "qmake6".to_owned());
    let output = Command::new(&qmake)
        .args(["-query", key])
        .output()
        .unwrap_or_else(|e| panic!("embed-qml: cannot run {qmake}: {e}"));
    PathBuf::from(String::from_utf8_lossy(&output.stdout).trim())
}

fn run(command: &mut Command) {
    let status = command
        .status()
        .unwrap_or_else(|e| panic!("embed-qml: cannot run {command:?}: {e}"));
    assert!(status.success(), "embed-qml: {command:?} failed");
}
