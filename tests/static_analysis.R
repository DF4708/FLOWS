# Custom static analyzer covering common R footguns
suppressMessages({})
files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
issues <- list()

add_issue <- function(file, line, kind, msg, snippet) {
  issues[[length(issues) + 1L]] <<- list(file = file, line = line, kind = kind, msg = msg, snippet = snippet)
}

for (f in files) {
  lines <- readLines(f, warn = FALSE)
  for (i in seq_along(lines)) {
    line <- lines[i]
    trimmed <- trimws(line)
    if (grepl("^#", trimmed)) next  # comments

    # 1. `%||%` used where NA could leak through (suspicious — only catches NULL)
    # Pattern: `something_text %||% something else` followed by usage assuming non-NA.
    # We can't catch all cases, but flag `is.na(x %||% NA_*` which is a weird tautology.
    if (grepl("\\bis\\.na\\([a-zA-Z_$.\\[\\]]+\\s*%\\|\\|%", line)) {
      add_issue(f, i, "is.na on %||%", "is.na(x %||% NA_*) is a tautology — use is.na(x) || is.null(x)", trimmed)
    }

    # 2. == NA / != NA (always NA, never works as expected)
    if (grepl("==\\s*NA\\b|!=\\s*NA\\b", line)) {
      add_issue(f, i, "== NA", "comparing with NA always yields NA — use is.na(x)", trimmed)
    }

    # 3. `length(x) == 0` immediately followed by use of `x[1]` — no, not actionable

    # 4. assignment with == instead of <- (typo)
    if (grepl("\\b[a-zA-Z_]+\\s*==\\s*function\\b", line)) {
      add_issue(f, i, "==function", "Likely typo: `name == function` should be `name <- function`", trimmed)
    }

    # 5. `cat(...)` left in non-debug code (looks like inline debug printing)
    # — only flag in compute/build/fetch functions, not in tests/scripts. Skip.

    # 6. `T` or `F` instead of TRUE/FALSE (R can be re-bound)
    # — only inline, not in strings; this is a noise pattern, skip aggressive check

    # 7. `lapply(... function(...) <single-arg call>)` — could be `lapply(..., fname)`
    # Hard to detect reliably without an AST; skip.

    # 8. Unbalanced braces would be caught by parse(). Skip.

    # 9. Reactive/observeEvent without ignoreNULL hint (Shiny-specific)
    # Not always wrong; skip.

    # 10. `rep(NA, n)` instead of `rep(NA_real_, n)` etc. — silent type coercion
    if (grepl("\\brep\\(NA\\b", line) && !grepl("rep\\(NA[_a-z]", line)) {
      # Skip if the line later builds a logical vector explicitly
      if (!grepl("logical|character|integer|numeric|complex", line)) {
        add_issue(f, i, "rep(NA)", "Use typed NA constant (NA_real_/NA_character_/etc.) for explicit type", trimmed)
      }
    }

    # 11. `for (x in 1:n)` — fails if n==0 (returns 1:0). Use seq_len(n).
    if (grepl("\\bfor\\s*\\(\\s*[a-zA-Z_]+\\s+in\\s+1:[a-zA-Z_]", line)) {
      add_issue(f, i, "1:n", "`1:n` evaluates to `c(1,0)` when n==0 — use seq_len(n)", trimmed)
    }

    # 12. `if (length(x) == 0)` immediately followed by `if (x == ...)` is fine
    # but `if (x == ...)` on a possibly-empty x throws. Skip; too noisy.

    # 13. unused assign-then-return: `x <- f(); return(x)` could be `f()`. Stylistic.

    # 14. Missing `drop = FALSE` in dataframe row indexing — common bug source
    # Pattern: `dat[i, ]` without `drop = FALSE`
    # but valid in many cases; check inside vapply/sapply/loops? Too noisy. Skip.

    # 15. `nzchar(NA)` / `nchar(NA)` — depends on keepNA option
    # Already audited via the is_nontrivial_string fix. Look for residuals.
    if (grepl("\\bnzchar\\s*\\(\\s*[a-zA-Z_$.\\[\\]]+\\s*\\)", line) &&
        !grepl("trimws|safe_string|as\\.character|coerce|paste", line) &&
        !grepl("!is\\.na", line) && !grepl("is\\.character", line)) {
      # Soft warning — only on lines where we can't tell if NA is excluded
      # Skip — too noisy
    }
  }
}

# Print summary
cat(sprintf("%d files scanned, %d issues found.\n\n", length(files), length(issues)))
if (length(issues) > 0) {
  for (it in issues) {
    cat(sprintf("[%s] %s:%d\n  %s\n  %s\n\n",
                it$kind, basename(it$file), it$line, it$msg, substr(it$snippet, 1, 100)))
  }
}
