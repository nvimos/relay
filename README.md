# nvimos-poc-backend

A Neovim plugin that makes Neovim the source of truth for a GUI: it streams typed, ordered events
for editor state over msgpack-RPC and runs every git and file action the GUI offers. The GUI is
`~/es/nvimos-poc-frontend` (Flutter, Windows). Plan and decisions: [PLAN.md](PLAN.md).

## Install

lazy.nvim:

```lua
{ dir = '~/es/nvimos-poc-backend' }
```

Then let the GUI connect, either at startup or later:

```
nvim --listen 127.0.0.1:6666
:NvimosServe                 " in a running Neovim; or :NvimosServe 127.0.0.1:7777
```

`:NvimosStatus` shows attached clients, active domains and sequence numbers.

## Protocol v1

Call functions with `nvim_exec_lua`, e.g. `return require('nvimos').attach(...)`. Neovim doesn't
tell Lua which channel called, so `attach`/`detach` take the client's channel id: the first item
of `nvim_get_api_info()`.

### Events

RPC notifications, method `nvimos`, one map argument:

```
{ v = 1, domain = 'buffers', seq = 42, reason = 'lines_changed', ... }
```

`seq` goes up by exactly one per domain. A gap means: call `resync(domain)`. Events with a seq at
or below a snapshot's seq are already in it. Domains no client subscribes to cost nothing.

| Domain        | Reasons and fields                                                                     |
|---------------|----------------------------------------------------------------------------------------|
| `buffers`     | `added`, `loaded` (buffer info), `unloaded`, `deleted`, `renamed`, `written`, `option_set` {buf, name, value}, `lines_inserted` / `lines_deleted` / `lines_changed` {buf, tick, first, old_last, new_last, lines}, `reloaded` |
| `windows`     | `focus`, `cursor_moved` (throttled 30 ms), `win_new` (window state), `win_closed` {win} |
| `git`         | `changed` {root, head, why = {fs, write, files, gitsigns, shell, focus}, paths}, `repo` (new root after :cd) |
| `diagnostics` | `changed` {buf, name, diagnostics = {lnum, col, end_lnum, end_col, severity, message, source, code}} |
| `jobs`        | `started`, `finished` {id, label, running, code, stdout, stderr} for commands started with `jobs.start` |

Content deltas: zero-based, end exclusive; lines `[first, old_last)` became `lines`. Only file
buffers (`buftype` empty) send them. After `loaded` or `reloaded`, fetch the text again.

### Functions

| Call                                        | Returns / does                                            |
|---------------------------------------------|-----------------------------------------------------------|
| `nvimos.attach({chan, domains})`            | `{v, chan, seq, snapshot}` per domain                     |
| `nvimos.detach({chan})`                     | stop events (also automatic when the channel closes)       |
| `nvimos.resync(domain)`                     | `{v, domain, seq, snapshot}`                              |
| `nvimos.get_text(buf)`                      | `{buf, tick, seq, watched, lines}`                        |
| `nvimos.open(path, lnum, col)`              | edit a work-tree file at a line (path relative to the repo root) |
| `nvimos.show(rev, path, lnum, col)`         | read-only buffer `nvimos://<rev>/<path>` at a line         |
| `nvimos.serve(addr)`                        | start listening (`:NvimosServe`)                           |
| `nvimos.git.branches()`                     | `{current, branches = {name, sha, upstream, current, date, subject}}` |
| `nvimos.git.log(base, head, max)`           | commits in `base..head`                                    |
| `nvimos.git.diff(base, head)`               | `{base, head, merge_base, files}` for `base...head`        |
| `nvimos.git.status()`                       | `{branch, files = {path, orig, index, worktree, staged, unstaged, untracked, conflicted}}` |
| `nvimos.git.diff_file(path, staged)`        | one file's hunks (untracked: all added)                    |
| `nvimos.git.stage / unstage / discard(path)` | whole file                                               |
| `nvimos.git.stage_hunk / unstage_hunk / discard_hunk(path, {old_start, new_start})` | one hunk |
| `nvimos.git.checkout(branch)`               | refuses with uncommitted changes or unsaved buffers        |
| `nvimos.git.commit(message)`                | new commit's sha                                           |
| `nvimos.files.list(dirs)`                   | `{path, size, mtime}` under repo dirs                      |
| `nvimos.files.read(paths)`                  | `{path, exists, buffer, lines}`; an open buffer wins       |
| `nvimos.files.set_lines(path, edits)`       | `{first, last, lines, expect?}` through a buffer, written   |
| `nvimos.files.move(from, to)`               | archive a file or folder                                   |
| `nvimos.files.create(path, lines)`          | new file, no overwrite                                     |
| `nvimos.files.cli(cmd, args)`               | `openspec` / `backlog` only: `{code, stdout, stderr}`      |
| `nvimos.jobs.start(cmd, args, {stdin, label})` | start `claude` / `openspec` / `backlog` without blocking Neovim; returns the job id |
| `nvimos.jobs.get(id)` / `list()` / `cancel(id)` | a job's state and output                                |

(`nvimos.git`, `nvimos.files` and `nvimos.jobs` are `require('nvimos.git')` and so on.)

A diff file is `{path, old_path, status, binary, additions, deletions, hunks}`; a hunk is
`{header, old_start, old_count, new_start, new_count, section, lines}`; a line is
`{kind = context|add|del, text, old, new, no_eol}`.

## Tests

```
make test            # or: nvim -l test/run.lua [name filter]
```

Each test spawns `nvim --embed --headless --clean` with the plugin and talks to it through a small
msgpack-RPC client in Lua (`test/rpc.lua`), some over real TCP.
