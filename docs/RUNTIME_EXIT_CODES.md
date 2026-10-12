# Runtime exit codes

These are the exit statuses that code **KernRift emits into your program** (or
the `kr` runner) can produce on its own, without your program calling `exit`.
A program's own `exit(n)` / `return n` from `main` is not listed here.

121, 122 and 123 always print one line on stderr first, so a status that
collides with a value your program uses itself can be told apart by that line.

| Code | Who exits | When | stderr |
|------|-----------|------|--------|
| 1 | emitted runtime traps | an emitted runtime check fails (for example a `--debug` bounds check) | depends on the trap |
| 120 | `kr` runner (Android/Termux) | the extracted slice could not be `execve`d from the app's data directory (SELinux); the `kr` shell wrapper (`packaging/kr.sh`) catches 120 and re-execs `./kr-exec` from its own context | none -- the wrapper handles it |
| 121 | Windows `main` prologue (spec C7) | `VirtualAlloc` failed for the parsed `argv` buffer | `krc runtime: argv allocation failed` |
| 122 | `exec_process_argv` on Windows (op 114) | the quoted child command line is longer than `CreateProcessA` accepts: more than 32767 bytes including its NUL (more than 32766 characters) | `krc runtime: child command line too long` |
| 123 | `exec_process_argv` on Windows (op 114) | `VirtualAlloc` failed for the child command line | `krc runtime: child command line allocation failed` |

`exec_process_argv` on Windows exits with the **child's** status once the child
finishes, so a child that itself exits 122 is indistinguishable by status
alone -- the stderr line is what tells them apart.

These numbers coincide with Win32 error codes (121 `ERROR_SEM_TIMEOUT`, 122
`ERROR_INSUFFICIENT_BUFFER`, 123 `ERROR_INVALID_NAME`, ...). They are **not**
Win32 errors; a tool that decodes a process exit status as one prints
misleading text. That is cosmetic.

## Windows `argv` (spec C7)

On Windows the emitted `main` prologue (IR backend) parses the command line
with the current MSVC CRT's (UCRT's) rules and fills `cli_argc` / `cli_argv`
exactly as the Linux loader would: argument count including `argv[0]`,
`argv[argc] = 0`, `cli_envp` left 0. The command line is copied; the
`GetCommandLineA` buffer is left as it was. Two cases keep the old behaviour --
`cli_argc = 0xFFFFFFFF` and `cli_argv` = the raw `GetCommandLineA` pointer:

- a `@naked fn main` (it has no `ExitProcess` epilogue, so the prologue may not
  clobber its callee-saved registers) -- unsupported for programs that read
  `cli_argc`;
- `--legacy` builds (a declared gap; the legacy backends are not changed).

`exec_process_argv` on Windows quotes each argument so that the child's parse
returns it unchanged. One thing cannot round-trip: a `"` inside `argv[0]`,
which UCRT's `argv[0]` rule has no escape for; it is passed through as is.
