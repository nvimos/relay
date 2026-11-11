-- git domain: hints that the repo's git state changed, so the client re-queries what it shows.
-- Sources: a file watcher on the git dir (HEAD, index, refs; also changes made outside Neovim),
-- buffer writes, gitsigns updates, shell commands, focus, and the cwd moving to another repo.
-- Hints are debounced; one `changed` event carries every reason seen in the window.
local core = require('nvimos')
local repo = require('nvimos.repo')
local tracking = require('nvimos.tracking')
local api = vim.api

local M = {}

local DEBOUNCE_MS = 150

local group, timer
local watchers = {}
local info -- repo.info() of the cwd, or nil outside a repo
local pending = {} -- reason -> true
local pending_paths = {} -- path -> true (for fs and write hints)

-- Files in the git dir that mean HEAD, the index or a ref changed.
local function relevant(name)
  name = name:gsub('\\', '/')
  if name:match('%.lock$') or name:match('^objects/') or name:match('^logs/') then
    return false
  end
  return name == 'HEAD'
    or name == 'index'
    or name == 'packed-refs'
    or name == 'MERGE_HEAD'
    or name == 'FETCH_HEAD'
    or name == 'ORIG_HEAD'
    or name:match('^refs/') ~= nil
end

local function snapshot_info()
  if not info then
    return { cwd = vim.fs.normalize(vim.fn.getcwd()), root = vim.NIL }
  end
  return {
    cwd = info.cwd,
    root = info.root,
    git_dir = info.git_dir,
    common_dir = info.common_dir,
    head = repo.head(info.git_dir) or vim.NIL,
  }
end

local function flush()
  if not core.active('git') or next(pending) == nil then
    return
  end
  local why = vim.tbl_keys(pending)
  table.sort(why)
  local paths = vim.tbl_keys(pending_paths)
  table.sort(paths)
  pending, pending_paths = {}, {}
  local ev = snapshot_info()
  ev.why = why
  ev.paths = paths
  core.emit('git', 'changed', ev)
end

--- Note a reason (and optionally a path); the event goes out DEBOUNCE_MS after the last one.
function M.hint(why, path)
  if not timer then
    return
  end
  pending[why] = true
  if path then
    pending_paths[path] = true
  end
  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(flush))
end

local function unwatch()
  for _, w in ipairs(watchers) do
    w:stop()
    if not w:is_closing() then
      w:close()
    end
  end
  watchers = {}
end

local function watch_dir(dir, filter, why, prefix)
  local w = vim.uv.new_fs_event()
  local ok = w:start(dir, { recursive = true }, function(err, name)
    if err or not name or not filter(name) then
      return
    end
    M.hint(why, (prefix or '') .. name:gsub('\\', '/'))
  end)
  if ok then
    watchers[#watchers + 1] = w
  else
    w:close()
  end
end

-- Planning dirs of the Tasks mode (in the planning folder, see tracking.lua): edits there (by an agent, a CLI, an editor) send why=files.
local PLANNING = { 'backlog', 'openspec', 'legacy' }

local function planning_file(name)
  return not name:match('%.swp$') and not name:match('~$') and not name:match('%.tmp$')
end

local function rewatch()
  unwatch()
  if not info then
    return
  end
  watch_dir(info.git_dir, relevant, 'fs')
  if info.common_dir ~= info.git_dir then
    watch_dir(info.common_dir, relevant, 'fs')
  end
  -- the planning folder: the repo root, or the folder its .nvimos names
  local ok, planning = pcall(tracking.root)
  for _, sub in ipairs(PLANNING) do
    local dir = (ok and planning or info.root) .. '/' .. sub
    if vim.fn.isdirectory(dir) == 1 then
      watch_dir(dir, planning_file, 'files', sub .. '/')
    end
  end
end

function M.install()
  info = repo.info()
  timer = vim.uv.new_timer()
  rewatch()
  group = api.nvim_create_augroup('nvimos_git', { clear = true })
  local function au(events, fn, pattern)
    api.nvim_create_autocmd(events, {
      group = group,
      pattern = pattern,
      callback = function(a)
        fn(a)
      end,
    })
  end
  au('BufWritePost', function(a)
    M.hint('write', vim.fs.normalize(api.nvim_buf_get_name(a.buf)))
  end)
  au('User', function()
    M.hint('gitsigns')
  end, 'GitSignsUpdate')
  au({ 'ShellCmdPost', 'TermLeave' }, function()
    M.hint('shell')
  end)
  au('FocusGained', function()
    M.hint('focus')
  end)
  au('DirChanged', function()
    local new = repo.info()
    local old_root = info and info.root
    info = new
    if (new and new.root) ~= old_root then
      rewatch()
      core.emit('git', 'repo', snapshot_info())
    end
  end)
end

function M.uninstall()
  api.nvim_del_augroup_by_id(group)
  unwatch()
  timer:stop()
  timer:close()
  timer = nil
  pending, pending_paths = {}, {}
end

function M.snapshot()
  return snapshot_info()
end

return M
