# nvimos-poc-backend, one-shot v1: state, decisions, style

Snapshot of the first pass (2026-11-10), written to pick the work up again later. The protocol
reference is README.md; the plan and step list is PLAN.md. This file holds what those two don't:
why things are the way they are, how the work was done, what is missing, and what was learned.

## What it is

A Lua plugin (`lua/nvimos`) that makes a running Neovim the source of truth for an external GUI
(`~/es/nvimos-poc-frontend`, Flutter on Windows). It:

- streams typed, ordered events for editor state over msgpack-RPC (notification method `nvimos`);
- runs every git, file and agent action the GUI offers, so the GUI itself never touches git or
  the disk.

It stands in for a C patch to Neovim (`nvim_attach_ui_stream`), which is planned in parallel and
not started.

Sources of the requirements, all in `~/es/nvimos-meta/poc-nvim-backend/`:

- `nvim-patch.md`: the original backend prompt;
- `flutter.md`: the review app;
- `flutter-project-man.md`: the Tasks mode ("Folio"), which added the `files.*` and `jobs.*`
  functions.

## State (v1 done)

- All 13 steps of PLAN.md are done and committed, one commit per feature or fix (21 commits,
  `git log --oneline`).
- Tests: `make test` (`nvim -l test/run.lua [filter]`), 12 files `test_00`..`test_11`, all
  passing. Each test starts a fresh `nvim --embed --headless --clean` and talks to it through our
  own msgpack-RPC client (`test/rpc.lua`), some tests over real TCP on a free port.
- Used for real on 2026-11-10: the user's nvim-qt with their full config, in `~/es/nvimos-meta`,
  with the frontend connected and showing the real backlog.
- About 3000 lines of Lua including tests.

## Decisions (with the user's answers from the setup wizard)

| # | Question                         | Answer / choice                                                    |
|---|----------------------------------|--------------------------------------------------------------------|
| 1 | Modes                            | both: two-branch review (PR) and working tree with staging          |
| 2 | Repo layout                      | one checkout, agent work on branches (no worktrees)                 |
| 3 | Click on a line in branch review | still open; default is read-only `show()` of the branch's version   |
| 4 | Git plugin                       | gitsigns (its `User GitSignsUpdate` is one of the git hints)        |
| 5 | Where git runs                   | everything through Neovim (this plugin), never in the GUI           |
| 6 | GUI platform                     | native Windows app                                                  |
| 7 | (not needed)                     |                                                                     |
| 8 | Transport                        | TCP `nvim --listen 127.0.0.1:6666` or `:NvimosServe`. The user noted this is not ideal without the C patch |
| 9 | Loading                          | lazy.nvim `{ dir = '~/es/nvimos-poc-backend' }` (not added to the user's config yet) |
| 10 | Extra domain                    | diagnostics                                                         |
| 11 | C patch                         | planned in parallel, see PLAN.md                                    |
| 12 | Plans                           | PLAN.md in each repo                                                |

Design choices made along the way:

- **Pull, then push hints.** Domains for editor state (buffers, windows, diagnostics) send full
  data in events. Git sends only a `changed` hint (with `why` and `paths`); the client re-queries
  with `git.*`. Git state is too big and too derived to stream.
- **Per-domain `seq`, +1 each event.** A gap means the client calls `resync(domain)`. No global
  order across domains (that is one reason for the C patch).
- **Zero cost when nobody listens.** A domain installs its autocommands, buffer attaches and fs
  watchers only while at least one client subscribes; uninstalls on the last detach.
- **The client passes its channel id** (`nvim_get_api_info()[1]`) to `attach`/`detach`, because
  `nvim_get_chan_info(0)` inside `nvim_exec_lua` doesn't name the caller. A `ChanClose`
  autocommand drops clients whose channel went away; a failed `rpcnotify` does too.
- **`modified` by comparison.** Neovim has no `BufModifiedSet` event usable here, so `modified`
  is compared on the events that can change it and sent as `option_set` when it differs.
- **Content deltas through `nvim_buf_attach`**, only for file buffers (`buftype` empty):
  `lines_inserted / lines_deleted / lines_changed {tick, first, old_last, new_last, lines}`, zero
  based, end exclusive. `:edit!` shows up as `unloaded` + `loaded`; the client refetches with
  `get_text`.
- **Cursor** throttled (trailing 30 ms); **focus** is scheduled and deduplicated, so a buffer that
  is current only for a moment (plugins hopping through buffers) is not reported.
- **Git hints from many sources**, debounced 150 ms: a recursive `fs_event` on the git dir
  (ignoring `objects/`, `logs/`, `*.lock`), `BufWritePost`, `User GitSignsUpdate`,
  `ShellCmdPost` / `TermLeave`, `FocusGained`, `DirChanged` (→ `repo`). The planning dirs
  `backlog/`, `openspec/`, `legacy/` are watched too (`why = files`), so the Tasks mode sees agent
  edits.
- **Every git call uses `--no-optional-locks`.** Without it, `git status` rewrote the index, the
  watcher saw it, the client re-queried, and it looped.
- **Hunks through `git apply`**, not gitsigns, so they work on files with no buffer. A hunk is
  found by its `old_start` / `new_start`, and the patch is rebuilt from our own parsed diff
  (`diffparse.lua`).
- **Files go through buffers.** `files.read`: a loaded buffer wins over the disk.
  `files.set_lines`: edits `{first, last, lines, expect}` are applied in a buffer, then written.
  It refuses if the buffer has unsaved changes, or if `expect` (the lines the client thinks are
  there) doesn't match. So the GUI never clobbers what the user is typing.
- **Generic files API, parsing in the app.** The backend lists, reads, edits, moves and creates
  files; the app knows OpenSpec and Backlog.md. `files.cli` only runs `openspec` / `backlog`.
- **Jobs are allow-listed**: `claude`, `openspec`, `backlog`. `vim.system` async, stdin supported,
  `jobs` domain events `started` / `finished` with output. No streaming of output while running.
- **`show(rev, path, lnum)`** opens a read-only scratch buffer named `nvimos://<rev>/<path>`.
- **`checkout` refuses** with uncommitted changes or unsaved buffers.

## Layout

| File                          | Does                                                                |
|-------------------------------|---------------------------------------------------------------------|
| `lua/nvimos/init.lua`         | attach/detach/resync/get_text/status, register domains, emit, serve, open/show passthrough, ChanClose watcher |
| `lua/nvimos/domain/*.lua`     | buffers, windows, git, diagnostics, jobs: install/uninstall/snapshot per domain |
| `lua/nvimos/repo.lua`         | repo root (cached per cwd), head, paths, `git()` runner             |
| `lua/nvimos/diffparse.lua`    | unified diff → files/hunks/lines with old and new line numbers      |
| `lua/nvimos/git.lua`          | branches, log, diff, status, diff_file, stage/unstage/discard (file, hunk), checkout, commit |
| `lua/nvimos/files.lua`        | list, read, set_lines, move, create, cli                            |
| `lua/nvimos/jobs.lua`         | start, get, list, cancel                                            |
| `lua/nvimos/nav.lua`          | open, show                                                          |
| `plugin/nvimos.lua`           | `:NvimosServe [addr]`, `:NvimosStatus`; nothing else loads until called |
| `test/rpc.lua`, `helpers.lua` | own RPC client (ext types decoded), temp repos, free ports          |

## Style and conventions

- **Lua:** small modules, `local M = {}`, plain tables, no classes, no dependencies beyond Neovim
  (built and tested on v0.13.0-dev; uses `vim.system`, `vim.uv`, `vim.mpack`). `.luarc.json` knows the `vim` global.
- **Errors:** functions the GUI calls raise with a short human sentence; the client shows it as
  is. Read calls return parsed tables, never raw git text.
- **Tests:** one fresh Neovim per test; output one line per test (`  ok name` / `FAIL name`). Temp
  repos set `user.*` and `core.autocrlf=false`.
- **Makefile:** pwsh recipes, `make help` with `##@` sections (`test`, `serve`).
- **Commits:** one per feature, one per fix, prefixed by area (`core:`, `buffers:`, `git:`, `fix:`,
  `plan:`). Commit as you go without asking, on `main`, in the main checkout, never push. Messages
  end with the Claude co-author line.
- **Docs:** PLAN.md for decisions and steps, README.md for install and protocol; short sentences,
  tables for references.

## Lessons and gotchas

- **lazy.nvim resets the runtimepath** at startup (`performance.rtp.reset`), so
  `nvim --cmd 'set rtp^=…'` loses the plugin with the user's real config. Add it after the config:
  `-c 'set rtp^=… | runtime plugin/nvimos.lua'` (the frontend's `make nvim` does this now), or use
  the lazy spec.
- `nvim --server … --remote-expr` printed nothing against nvim-qt's server; probing with our own
  test client (`require('rpc').connect(host, port)`, `c:lua(code)`) works.
- `files.read` once ran `git rev-parse` per file and timed out on ~300 files; the root is now
  cached per cwd.
- Fixed ports in tests collided; ask the OS for a free port.
- The git dir watcher is one `fs_event` with `recursive = true`; libuv supports that on Windows and macOS, not on Linux (a Linux port needs one watcher per dir).

## Gaps and open items

- **The C patch** (`nvim_attach_ui_stream`): not started. Wanted for marks, signs and extmarks (no
  autocommands for them), one order across domains, and pushing to a client as it connects. Open:
  where the fork lives (e.g. `~/es/neovim`), and extmark hooks (`extmark.c` has no callback seam).
  Check first whether a `ChanOpen` autocommand already lets the plugin push on connect.
- **Not in the user's config.** `{ dir = '~/es/nvimos-poc-backend' }` is the agreed spec; the user
  hasn't added it.
- **Question 3 is still open:** branch review click shows a read-only copy; the alternative is
  checking the branch out.
- **Large diffs block Neovim** (`git.diff` is synchronous). If it shows, run it as a job and send a
  `git` `result` event.
- **Jobs don't stream output** while running; the GUI sees it only at `finished`.
- **No auth on the TCP port** (localhost only). Fine for a POC, not for anything shared.
- **Not covered:** extmarks, signs, marks, quickfix, terminal buffers' content, multiple tabpages
  beyond what windows reports.

## Ideas for v2

- Push the `snapshot` to a client right after it connects (`ChanOpen`), saving one round trip.
- Stream job output (`jobs` `output` events, throttled), for watching agents work.
- A `tasks.*` layer in Lua if parsing in Dart turns out slow; for now the app parses.
- Named pipe transport once the GUI can open one (Dart can't).
