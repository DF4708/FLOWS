// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! FLOWS has no Python: not in the product, not as tooling, not as a line
//! inside a shell script. Rust and Swift do the work, shell glues them. This
//! walks the repository and fails on a Python source or notebook (a symlink
//! with that name included), on any executable or extension-less file whose
//! shebang runs Python, or on a script line that runs Python or installs
//! Python packages, so the rule cannot quietly lapse the way it did (a table
//! generator, two harness stub writers and the places conversion were Python
//! until 2026-09-21). A file or directory it cannot read fails the test too:
//! unread is not clean.

use std::io::Read as _;
use std::path::{Path, PathBuf};

/// Directories that hold build output, other checkouts or bulk data, never
/// the repository's own sources.
const SKIP_DIRS: &[&str] = &[
    ".git",
    ".claude",
    "target",
    "DerivedData",
    ".build",
    "build",
    "node_modules",
    "Generated",
];

/// File extensions that are Python.
const PYTHON_EXTENSIONS: &[&str] = &["py", "pyc", "pyi", "pyw", "pyx", "ipynb"];

/// Characters that end a word on a command line: shell punctuation, and the
/// parts of `${VAR:-python3}`, `PY=python3`, `setup-python@v5` and
/// `python3-pip` that would otherwise hide the name inside a longer word.
const SEPARATORS: &str = ";&|()`$\"'={}:@+-,<>[]";

/// Files whose every line runs commands.
fn is_script(path: &Path) -> bool {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
    matches!(ext, "sh" | "bash" | "zsh" | "command" | "yml" | "yaml") || name == "Makefile"
}

/// A word that names a Python interpreter, installer or runner, whatever
/// version follows it (`python3.12`, `pip3`, `pypy3`).
fn names_python(word: &str) -> bool {
    let base = word.rsplit('/').next().unwrap_or(word);
    let versioned = |name: &str| {
        base.strip_prefix(name).is_some_and(|rest| {
            rest.is_empty() || rest.starts_with(|c: char| c.is_ascii_digit() || c == '.')
        })
    };
    versioned("python")
        || versioned("pip")
        || versioned("pypy")
        || versioned("ipython")
        || matches!(
            base,
            "pipx"
                | "pytest"
                | "uv"
                | "uvx"
                | "poetry"
                | "pipenv"
                | "conda"
                | "mamba"
                | "micromamba"
                | "jupyter"
        )
}

/// The part of a line before its comment: a `#` outside quotes that starts
/// the line or follows whitespace, as in shell and YAML. `$#` and `${#x}` are
/// not comments.
fn before_comment(line: &str) -> &str {
    let mut quote: Option<char> = None;
    let mut after_space = true;
    for (i, c) in line.char_indices() {
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => {}
            None if c == '\'' || c == '"' => quote = Some(c),
            None if c == '#' && after_space => return &line[..i],
            None => {}
        }
        after_space = c.is_whitespace();
    }
    line
}

/// A line that runs Python or installs a Python package. Comments are prose
/// (they may say "no Python"), so only a shebang counts among them.
fn runs_python(line: &str) -> bool {
    let trimmed = line.trim_start();
    if let Some(interpreter) = trimmed.strip_prefix("#!") {
        // `#!/usr/bin/env -S uv run --script` and `#!/usr/bin/env pypy3`
        // run Python without saying so.
        return trimmed.contains("python") || words(interpreter).any(names_python);
    }
    words(before_comment(trimmed)).any(names_python)
}

fn words(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| c.is_whitespace() || SEPARATORS.contains(c))
}

/// Whether a shebang runs a shell (`#!/bin/bash`, `#!/usr/bin/env -S zsh -e`),
/// whose every line is then a command. Other interpreters (`swift`, say) are
/// not read line by line: their identifiers are not commands.
fn runs_a_shell(shebang: &str) -> bool {
    let mut words = shebang
        .trim_start_matches("#!")
        .split_whitespace()
        .map(|w| w.rsplit('/').next().unwrap_or(w));
    let mut program = words.next();
    if program == Some("env") {
        program = words.find(|w| !w.starts_with('-') && !w.contains('='));
    }
    matches!(program, Some("sh" | "bash" | "zsh" | "dash" | "ksh"))
}

/// Every line of a script, read lossily: one stray byte must not hide it.
fn scan_script(path: &Path, found: &mut Vec<String>) {
    match std::fs::read(path) {
        Ok(bytes) => {
            let text = String::from_utf8_lossy(&bytes);
            for (i, line) in text.lines().enumerate() {
                if runs_python(line) {
                    found.push(format!(
                        "{}:{}: runs Python: {}",
                        path.display(),
                        i + 1,
                        line.trim()
                    ));
                }
            }
        }
        Err(e) => found.push(format!("{}: unreadable script: {e}", path.display())),
    }
}

/// Whether a file that is not a script could still run as a program: it has
/// an execute bit, or it has no extension at all.
fn may_run(path: &Path, meta: &std::fs::Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        if meta.permissions().mode() & 0o111 != 0 {
            return true;
        }
    }
    #[cfg(not(unix))]
    let _ = meta;
    path.extension().is_none()
}

/// The file's first line, read from at most its first 512 bytes.
fn first_line(path: &Path) -> std::io::Result<String> {
    let mut head = Vec::with_capacity(512);
    std::fs::File::open(path)?
        .take(512)
        .read_to_end(&mut head)?;
    let line = head.split(|&b| b == b'\n').next().unwrap_or(&[]);
    Ok(String::from_utf8_lossy(line).into_owned())
}

fn walk(dir: &Path, found: &mut Vec<String>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => {
            found.push(format!("{}: unreadable directory: {e}", dir.display()));
            return;
        }
    };
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(e) => {
                found.push(format!("{}: unreadable entry: {e}", dir.display()));
                continue;
            }
        };
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let kind = match entry.file_type() {
            Ok(kind) => kind,
            Err(e) => {
                found.push(format!("{}: unreadable: {e}", path.display()));
                continue;
            }
        };
        if kind.is_dir() {
            if name == "__pycache__" {
                found.push(format!("{}: Python bytecode", path.display()));
            } else if !SKIP_DIRS.contains(&name.as_ref()) {
                walk(&path, found);
            }
            continue;
        }
        // Before the file test, so a symlink with a Python name counts too.
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        if PYTHON_EXTENSIONS.contains(&ext) {
            found.push(format!("{}: a Python file", path.display()));
            continue;
        }
        if !kind.is_file() {
            continue;
        }
        if is_script(&path) {
            scan_script(&path, found);
            continue;
        }
        let meta = match entry.metadata() {
            Ok(meta) => meta,
            Err(e) => {
                found.push(format!("{}: unreadable: {e}", path.display()));
                continue;
            }
        };
        if may_run(&path, &meta) {
            match first_line(&path) {
                Ok(line) if line.starts_with("#!") && runs_python(&line) => {
                    found.push(format!(
                        "{}:1: a Python program: {}",
                        path.display(),
                        line.trim()
                    ));
                }
                // A shell program without a script's extension.
                Ok(line) if line.starts_with("#!") && runs_a_shell(&line) => {
                    scan_script(&path, found);
                }
                Ok(_) => {}
                Err(e) => found.push(format!("{}: unreadable: {e}", path.display())),
            }
        }
    }
}

#[test]
fn the_repository_has_no_python() {
    let repo: PathBuf = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let repo = std::fs::canonicalize(&repo).unwrap_or(repo);
    assert!(
        repo.join("rust/Cargo.toml").is_file() && repo.join("apple").is_dir(),
        "not the repository root: {}",
        repo.display()
    );
    let mut found = Vec::new();
    walk(&repo, &mut found);
    assert!(
        found.is_empty(),
        "FLOWS has no Python (Rust and Swift do the work, shell glues them):\n{}",
        found.join("\n")
    );
}

#[test]
fn the_python_check_sees_what_it_should() {
    for line in [
        "python3 - \"$REPO\" <<'PY'",
        "  python3 -u \"$ROOT/scripts/x\"",
        "x=$(python -c 'print(1)')",
        "pip3 install --user duckdb",
        "pip3.12 install duckdb",
        "/usr/bin/python3.12 tool",
        "#!/usr/bin/env python3",
        "#!/usr/bin/env -S python3 -u",
        "#!/usr/bin/env -S uv run --script",
        "#!/usr/bin/env pypy3",
        "run: python -m pytest",
        "run: pytest -q",
        "PY=python3",
        "\"${PYTHON:-python3}\" - \"$REPO\" <<'PY'",
        "\"${PYTHON-python3}\" gen",
        "brew install python@3.12",
        "apt-get install python3-pip",
        "      - uses: actions/setup-python@v5",
        "uv run gen",
        "uvx ruff",
        "poetry run x",
        "conda run x",
        "pypy3 x",
        "ipython",
        "cargo test && python3 x  # regenerate",
    ] {
        assert!(runs_python(line), "missed: {line}");
    }
    for line in [
        "# FLOWS has no Python; the old python3 step is gone",
        "cargo run -p flows-train  # replaces the old python3 trainer",
        "echo \"needs duckdb\"",
        "cargo test -p flows-bridge",
        "set -euo pipefail",
        "pythonic=1",
        "awk '{ print }'",
        "echo \"$#\" \"${#files}\"",
        "grep -n 'x' README.md",
        "#!/bin/bash",
        "#!/usr/bin/env swift",
    ] {
        assert!(!runs_python(line), "flagged: {line}");
    }
    for shebang in [
        "#!/bin/bash",
        "#!/bin/sh",
        "#!/usr/bin/env -S zsh -e",
        "#!/usr/bin/env FOO=1 bash",
    ] {
        assert!(runs_a_shell(shebang), "not a shell: {shebang}");
    }
    for shebang in [
        "#!/usr/bin/env swift",
        "#!/usr/bin/env python3",
        "#!/usr/bin/awk -f",
    ] {
        assert!(!runs_a_shell(shebang), "a shell: {shebang}");
    }
}

#[test]
fn the_walk_finds_python_hidden_from_the_line_check() {
    let dir = std::env::temp_dir().join(format!("flows-no-python-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("scripts")).expect("scratch directory");
    // An extension-less program with a Python shebang.
    std::fs::write(
        dir.join("scripts/regen"),
        "#!/usr/bin/env python3\nprint(1)\n",
    )
    .expect("write");
    // A script whose one stray byte is not UTF-8.
    std::fs::write(dir.join("scripts/build.sh"), b"# caf\xe9\npython3 x\n").expect("write");
    // A shell program without a script's extension (the stub-writer pattern).
    std::fs::write(
        dir.join("scripts/stubs"),
        "#!/bin/bash\nset -e\npython3 - \"$REPO\" <<'PY'\n",
    )
    .expect("write");
    // A clean script and a data file, which must not be flagged.
    std::fs::write(
        dir.join("scripts/ok.sh"),
        "#!/bin/bash\necho ok  # no python here\n",
    )
    .expect("write");
    std::fs::write(dir.join("notes.txt"), "python3 is not a program here\n").expect("write");
    #[cfg(unix)]
    std::os::unix::fs::symlink("/nonexistent/gen.py", dir.join("gen.py")).expect("symlink");
    let mut found = Vec::new();
    walk(&dir, &mut found);
    let _ = std::fs::remove_dir_all(&dir);
    let has = |needle: &str| found.iter().any(|f| f.contains(needle));
    assert!(has("scripts/regen:1: a Python program"), "{found:?}");
    assert!(has("scripts/build.sh:2: runs Python"), "{found:?}");
    assert!(has("scripts/stubs:3: runs Python"), "{found:?}");
    #[cfg(unix)]
    assert!(has("gen.py: a Python file"), "{found:?}");
    assert!(!has("ok.sh") && !has("notes.txt"), "{found:?}");
}
