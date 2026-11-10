//! Launcher benchmark: index build and per-keystroke search latency.
//!
//! ```sh
//! cargo run --release -p lugh-shell-core --example bench_launcher
//! ```
//!
//! Generates 2,000 synthetic desktop files (written to a temp dir, so the
//! index time includes I/O and parsing), then indexes the host's real XDG
//! application dirs, and times 200 queries of 1–8 characters on each: once
//! "typed" (each keystroke a query, as in the launcher) and once "cold"
//! (every query from scratch).
#![allow(clippy::print_stdout)]

use std::time::{Duration, Instant};

use lugh_shell_core::launcher::{AppIndex, DesktopEntry, History, Launcher, Locale};

const N_ENTRIES: usize = 2_000;
const N_QUERIES: usize = 200;
const LIMIT: usize = 50;

/// Small deterministic PRNG (xorshift64*).
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[(self.next() % items.len() as u64) as usize]
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

const PREFIXES: &[&str] = &[
    "", "", "", "Gnome ", "KDE ", "Open", "Libre", "Q", "X", "Py", "Super", "Easy", "Simple",
    "Pro ", "Mini", "Kit", "Neo", "Hyper",
];
const NOUNS: &[&str] = &[
    "Writer",
    "Calc",
    "Draw",
    "Impress",
    "Terminal",
    "Files",
    "Browser",
    "Mail",
    "Music",
    "Video",
    "Player",
    "Editor",
    "Viewer",
    "Paint",
    "Studio",
    "Monitor",
    "Manager",
    "Settings",
    "Store",
    "Maps",
    "Weather",
    "Clock",
    "Camera",
    "Photos",
    "Notes",
    "Tasks",
    "Contacts",
    "Calendar",
    "Chat",
    "Torrent",
    "Backup",
    "Disks",
    "Fonts",
    "Archive",
    "Scanner",
    "Printer",
    "Office",
    "Code",
    "Shell",
    "Console",
    "Recorder",
    "Converter",
    "Reader",
    "Builder",
    "Designer",
];
const GENERIC: &[&str] = &[
    "Web Browser",
    "Text Editor",
    "File Manager",
    "Media Player",
    "Image Viewer",
    "Word Processor",
    "Spreadsheet",
    "Terminal Emulator",
    "System Monitor",
    "Email Client",
    "Music Player",
    "Video Editor",
    "PDF Viewer",
    "Archive Manager",
    "Disk Utility",
    "Screen Recorder",
];
const KEYWORDS: &[&str] = &[
    "internet",
    "web",
    "document",
    "office",
    "media",
    "audio",
    "video",
    "image",
    "photo",
    "system",
    "process",
    "network",
    "file",
    "folder",
    "text",
    "code",
    "development",
    "game",
    "education",
    "science",
    "graphics",
    "music",
    "chat",
    "backup",
    "security",
    "printer",
];

fn synth_desktop(rng: &mut Rng, i: usize) -> (String, String) {
    let name = format!(
        "{}{}{}",
        rng.pick(PREFIXES),
        rng.pick(NOUNS),
        if rng.below(3) == 0 {
            format!(" {}", rng.pick(NOUNS))
        } else {
            String::new()
        }
    );
    let id = format!("org.synth.App{i}");
    let kw: Vec<&str> = (0..rng.below(5)).map(|_| rng.pick(KEYWORDS)).collect();
    let text = format!(
        "[Desktop Entry]\nType=Application\nName={name}\nName[fr]={name} (fr)\nGenericName={}\nComment=Synthetic app number {i}\nKeywords={};\nExec=synth-app-{i} %U\nIcon=app-{i}\nCategories=Utility;\n\n[Desktop Action new]\nName=New Window\nExec=synth-app-{i} --new\n",
        rng.pick(GENERIC),
        kw.join(";"),
    );
    (id, text)
}

fn queries(rng: &mut Rng, index: &AppIndex) -> Vec<String> {
    let names: Vec<String> = index
        .entries()
        .iter()
        .map(|e| e.name.to_lowercase())
        .collect();
    (0..N_QUERIES)
        .map(|k| {
            let len = 1 + k % 8;
            if k % 4 == 3 || names.is_empty() {
                // random letters: mostly misses or weak fuzzy hits
                (0..len)
                    .map(|_| (b'a' + rng.below(26) as u8) as char)
                    .collect()
            } else {
                let n = &names[rng.below(names.len())];
                n.chars().take(len).collect()
            }
        })
        .collect()
}

struct Stats {
    p50: Duration,
    p95: Duration,
    max: Duration,
}

fn stats(mut t: Vec<Duration>) -> Stats {
    t.sort_unstable();
    let at = |q: f64| t[((t.len() - 1) as f64 * q).round() as usize];
    Stats {
        p50: at(0.5),
        p95: at(0.95),
        max: t[t.len() - 1],
    }
}

fn report(label: &str, s: &Stats) {
    println!(
        "  {label:<34} p50 {:>8.1} µs   p95 {:>8.1} µs   max {:>8.1} µs",
        s.p50.as_secs_f64() * 1e6,
        s.p95.as_secs_f64() * 1e6,
        s.max.as_secs_f64() * 1e6
    );
}

fn bench_search(name: &str, index: AppIndex, rng: &mut Rng) {
    let qs = queries(rng, &index);
    let n = index.len();
    let mut launcher = Launcher::new(index, History::in_memory());
    // warm-up
    for q in &qs {
        launcher.search(q, LIMIT);
    }

    // Typed: every prefix of each query is one keystroke.
    let mut typed = Vec::new();
    let mut hits = 0usize;
    for q in &qs {
        let chars: Vec<char> = q.chars().collect();
        for k in 1..=chars.len() {
            let prefix: String = chars[..k].iter().collect();
            let t = Instant::now();
            let r = launcher.search(&prefix, LIMIT);
            typed.push(t.elapsed());
            hits += r.len();
        }
    }

    // Cold: each query from scratch (an unrelated query first resets the
    // narrowing cache; not timed).
    let mut cold = Vec::new();
    for q in &qs {
        launcher.search("\u{1}", LIMIT);
        let t = Instant::now();
        let r = launcher.search(q, LIMIT);
        cold.push(t.elapsed());
        std::hint::black_box(r);
    }

    println!(
        "{name}: {n} entries, {} queries of 1–8 chars (limit {LIMIT})",
        qs.len()
    );
    report(
        &format!("typed ({} keystrokes)", typed.len()),
        &stats(typed),
    );
    report("cold (no narrowing)", &stats(cold));
    println!(
        "  avg results per keystroke: {:.1}",
        hits as f64 / qs.len() as f64
    );
}

/// Times the index phases separately (single-threaded).
fn breakdown(apps: &std::path::Path) -> std::io::Result<()> {
    let t = Instant::now();
    let mut texts = Vec::new();
    for ent in std::fs::read_dir(apps)? {
        let p = ent?.path();
        if p.extension().is_some_and(|e| e == "desktop") {
            texts.push(std::fs::read_to_string(&p)?);
        }
    }
    let read = t.elapsed();
    let locale = Locale::parse("fr_FR.UTF-8");
    let t = Instant::now();
    let entries: Vec<DesktopEntry> = texts
        .iter()
        .enumerate()
        .filter_map(|(i, s)| DesktopEntry::parse(s, &format!("e{i}"), &locale).ok())
        .collect();
    let parse = t.elapsed();
    let n = entries.len();
    let t = Instant::now();
    let idx = AppIndex::from_entries(entries);
    let prep = t.elapsed();
    std::hint::black_box(idx);
    let ms = |d: Duration| d.as_secs_f64() * 1e3;
    println!(
        "  breakdown ({n} files, 1 thread): read {:.2} ms, parse {:.2} ms, prepare haystacks {:.2} ms",
        ms(read),
        ms(parse),
        ms(prep)
    );
    Ok(())
}

fn main() -> std::io::Result<()> {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);

    // Synthetic: 2,000 files on disk.
    let dir = tempfile::tempdir()?;
    let apps = dir.path().join("applications");
    std::fs::create_dir_all(apps.join("sub"))?;
    for i in 0..N_ENTRIES {
        let (id, text) = synth_desktop(&mut rng, i);
        let sub = if i % 10 == 0 { "sub/" } else { "" };
        std::fs::write(apps.join(format!("{sub}{id}.desktop")), text)?;
    }
    let mut builds = Vec::new();
    let mut index = None;
    for _ in 0..10 {
        let t = Instant::now();
        let idx = AppIndex::new(
            vec![apps.clone()],
            Locale::parse("fr_FR.UTF-8"),
            vec!["Lugh".into()],
        );
        builds.push(t.elapsed());
        index = Some(idx);
    }
    let index = index.unwrap_or_else(|| AppIndex::from_entries(Vec::new()));
    let b = stats(builds);
    println!(
        "Index build, synthetic ({} files, warm page cache, 10 runs):",
        index.len()
    );
    report("AppIndex::new (scan+parse+prepare)", &b);
    breakdown(&apps)?;
    bench_search("Search, synthetic", index, &mut rng);

    // Host: the real XDG dirs.
    let mut builds = Vec::new();
    let mut host = None;
    for _ in 0..10 {
        let t = Instant::now();
        let idx = AppIndex::from_env();
        builds.push(t.elapsed());
        host = Some(idx);
    }
    let host = host.unwrap_or_else(|| AppIndex::from_entries(Vec::new()));
    println!(
        "\nIndex build, host ({} visible entries from {} dirs, 10 runs):",
        host.len(),
        host.dirs().len(),
    );
    report("AppIndex::from_env", &stats(builds));
    if host.is_empty() {
        println!("  (no host entries; skipping host search)");
    } else {
        bench_search("Search, host", host, &mut rng);
    }
    Ok(())
}
