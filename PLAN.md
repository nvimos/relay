# Plan: nvimos-poc-backend

A Lua plugin that turns Neovim into the source of truth for an external GUI: typed, ordered events
for editor state, plus RPC functions for every git action the GUI offers. The GUI is
`~/es/nvimos-poc-frontend` (Flutter, Windows). Original requirements:
`~/es/nvimos-meta/poc-nvim-backend/nvim-patch.md`. The C patch from that prompt is planned in parallel,
at the end of this file.

## Decisions

| Topic            | Choice                                                                         |
|------------------|--------------------------------------------------------------------------------|
| Form             | Lua plugin first; C patch planned in parallel                                  |
| Loading          | lazy.nvim spec `{ dir = '~/es/nvimos-poc-backend' }` in the user's config      |
| Connection       | TCP: `nvim --listen 127.0.0.1:6666`, or `:NvimosServe` starts it in a running Neovim (`serverstart`) |
| Domains (v1)     | buffers, windows (current buffer, cursor), git, diagnostics                    |
| Git              | every git command the GUI needs runs inside Neovim, through this plugin        |
| Git plugin       | gitsigns: its `User GitSignsUpdate` event is a git-changed hint                |
| Modes            | both from the start: two-branch review and working tree vs HEAD               |
| Repo layout      | one checkout; agent work is on branches                                        |
| Branch file open | read-only buffer with the branch's version, at the line (default, still open)  |

## Protocol v1

The client calls the plugin through `nvim_exec_lua`, e.g.
`nvim_exec_lua("return require('nvimos').attach(...)", [{domains = [...]}])`.

Events are RPC notifications, method `nvimos`, one map argument:

    { v = 1, domain = 'buffers', seq = 42, reason = 'lines_changed', buf = 3, ... }

- `v`: API version. New fields may appear in v1; removing or renaming one means v2.
- `seq`: per domain, strictly increasing by 1. A gap means the client resyncs that domain.
- Unsubscribed domains install no autocommands and attach nothing: zero cost when no client is
  attached.

### Functions

| Function                     | Returns                                                       |
|------------------------------|---------------------------------------------------------------|
| `attach({domains})`          | `{v, chan, seq = {d = n}, snapshot = {d = ...}}`              |
| `detach()`                   | nothing; stops events for this channel                        |
| `resync(domain)`             | `{seq, snapshot}`; events with a lower or equal seq are stale |
| `get_text(buf)`              | `{buf, tick, seq, lines}`: full text, only on request          |
| `open(path, lnum, col)`      | `{buf, win}`: edit the working-tree file at that position      |
| `show(rev, path, lnum)`      | `{buf, win}`: read-only buffer `nvimos://<rev>/<path>`         |
| `git.*`                      | see Git below                                                 |

The calling channel comes from `nvim_get_chan_info(0)`. A failed `rpcnotify` drops the client.

### Domains

- **buffers**: `added`, `deleted`, `unloaded`, `loaded`, `renamed`, `written`, `option_set`
  (filetype, buftype, modifiable, readonly, fileformat, buflisted; `modified` through
  `BufModifiedSet`), and content deltas for file buffers (`buftype` empty) via `nvim_buf_attach`:
  `lines_inserted`, `lines_deleted`, `lines_changed` with `{tick, first, old_last, new_last, lines}`
  (zero-based, end exclusive), `reloaded`. Snapshot: info for every buffer, no text.
- **windows**: `focus` (WinEnter/BufEnter), `cursor_moved` (CursorMoved/I, trailing 30 ms),
  `win_new`, `win_closed`. Snapshot: current window, all windows with buffer and cursor.
- **git**: `changed` hint with `why` (fs, write, gitsigns, shell) when HEAD, index, refs or a file in
  the work tree change; `repo` when the cwd moves to another repo. A recursive `fs_event` on the git
  dir (ignoring `objects/`, `logs/`, `*.lock`), debounced 150 ms. Snapshot: `{cwd, root, git_dir,
  head}`. The client re-queries with `git.*` after a hint.
- **diagnostics**: `changed` per buffer from `DiagnosticChanged`, with the full list for that buffer
  (lnum, col, end, severity, message, source). Snapshot: all buffers' diagnostics.

### Git

Run with `vim.system` in the repo root. Read calls return parsed data, not raw text.

| Function                                 | Does                                                |
|------------------------------------------|-----------------------------------------------------|
| `git.branches()`                         | local branches, current one, upstream               |
| `git.log(base, head)`                    | commits in `base..head`                             |
| `git.diff(base, head)`                   | files and hunks of `base...head`                    |
| `git.status()`                           | working tree vs HEAD: staged, unstaged, untracked   |
| `git.diff_worktree(path, staged)`        | hunks of one file, index or work tree               |
| `git.stage(path)` / `git.unstage(path)`  | whole file                                          |
| `git.stage_hunk(path, hunk)` / `unstage_hunk` | one hunk, as a patch through `git apply --cached` |
| `git.discard(path)` / `git.discard_hunk` | restore from the index; reloads the buffer if open  |
| `git.checkout(branch)`                   | refuses with uncommitted changes                    |
| `git.commit(message)`                    | commit the index                                    |

Hunks use `git apply`, not gitsigns, so they work for files without a buffer. Diffs of large
ranges may block Neovim; if that shows, move them to a job id plus a `git` `result` event.

### Files (for the Tasks mode)

The frontend's Tasks mode (`~/es/nvimos-meta/poc-nvim-backend/flutter-project-man.md`) reads and
writes the repo's OpenSpec and Backlog.md files through Neovim. The backend stays generic: it
lists, reads, edits and moves files; the app parses them.

| Function                          | Does                                                          |
|-----------------------------------|---------------------------------------------------------------|
| `files.list(dirs)`                | files under the given repo dirs, with size and mtime          |
| `files.read(paths)`               | contents of several files; from the buffer if one is loaded   |
| `files.set_lines(path, edits)`    | replace line ranges through a buffer, then write it           |
| `files.move(from, to)`            | move a file or folder (archive); renames loaded buffers       |
| `files.create(path, lines)`       | new file, refuses to overwrite                                |
| `files.cli(cmd)`                  | run `openspec` / `backlog` with args in the repo, return output |

The git domain's `changed` hint also fires for writes under `backlog/`, `openspec/` and `legacy/`
(fs watcher on those dirs), so the app refreshes when an agent edits them.

## Tests

- `nvim -l test/run.lua`: spawns `nvim --embed --headless --clean` with the plugin on the
  runtimepath, talks to it with a small msgpack-RPC client written in Lua (`vim.mpack`, no deps).
- One fresh Neovim per test. Output one line per test: `  ok <name>` / `FAIL <name>`.
- Covers: attach snapshot, no events for unsubscribed domains, deltas rebuild the text (client
  model compared with `nvim_buf_get_lines` after a series of edits), seq has no gaps, resync, option
  and rename events, `open`/`show`, git hints after an outside `git checkout` in a temp repo, git
  functions on a temp repo, detach.
- `Makefile` (pwsh, `make help`): `test`, `serve` (Neovim on 127.0.0.1:6666 with the plugin).

## Steps (one commit each)

1. Skeleton: `lua/nvimos/init.lua`, Makefile, test runner with the RPC client, one smoke test.
2. attach/detach, seq, client bookkeeping, zero-cost install/uninstall of hooks.
3. buffers domain: list, options, rename, write.
4. buffers domain: content deltas, `get_text`, resync.
5. windows domain.
6. `open`, `show`, `:NvimosServe`.
7. git domain: hints from fs_event, writes, gitsigns.
8. git read functions: branches, log, diff, status.
9. git write functions: stage/unstage/discard file and hunk, checkout, commit.
10. diagnostics domain.
11. files: list, read, set_lines, move, create, cli; planning-dir hints.
12. README: install with lazy.nvim, protocol reference.
13. jobs: start an agent (`claude -p`) or CLI without blocking; `jobs` domain events.

## C patch, planned in parallel

Same protocol, inside Neovim: `nvim_attach_ui_stream(opts)` and `nvim_ui_stream_resync(domain)`
in a new `src/nvim/ui_stream.c`, docs in `runtime/doc/api.txt`, tests in `test/functional/`.
It is worth it for:

- marks, signs and extmarks: no autocommands exist for them, so the plugin can't see changes;
- one place for event order across domains;
- pushing events to a client as it connects. To check first: the `ChanOpen` autocommand may let
  the plugin do this already.

Open: where the Neovim fork lives (e.g. `~/es/neovim`), and whether extmark hooks can stay inside
the one-file rule (extmarks change in `extmark.c`, which has no callback seam).
