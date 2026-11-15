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

-- libuv recursive fs events exist on Windows and macOS only. On Linux a watch sees
-- one directory, so each subdirectory needs its own. `skip(rel)` drops a subdirectory
-- (and anything under it) from that walk, so a git dir does not watch objects/.
local RECURSE = vim.uv.os_uname().sysname ~= 'Linux'

local function arm(dir, cb, recursive)
  local w = vim.uv.new_fs_event()
  local ok = w:start(dir, { recursive = recursive }, cb)
  if ok then
    watchers[#watchers + 1] = w
    return true
  end
  w:close()
  return false
end

local function watch_dir(dir, filter, why, prefix, skip)
  local function hint(name)
    name = name:gsub('\\', '/')
    if filter(name) then
      M.hint(why, (prefix or '') .. name)
    end
  end
  if RECURSE and arm(dir, function(err, name)
    if not err and name then
      hint(name)
    end
  end, true) then
    return
  end
  local seen = {}
  local function watch_one(path, rel)
    path = vim.fs.normalize(path)
    if seen[path] then
      return
    end
    seen[path] = true
    arm(path, function(err, name)
      if err or not name then
        return
      end
      name = name:gsub('\\', '/')
      local relname = rel == '' and name or (rel .. '/' .. name)
      local st = vim.uv.fs_stat(path .. '/' .. name)
      if st and st.type == 'directory' and not (skip and skip(relname)) then
        watch_one(path .. '/' .. name, relname)
      end
      hint(relname)
    end, false)
  end
  local function walk(path, rel)
    for name, typ in vim.fs.dir(path) do
      if typ == 'directory' then
        local relname = rel == '' and name or (rel .. '/' .. name)
        if not (skip and skip(relname)) then
          watch_one(path .. '/' .. name, relname)
          walk(path .. '/' .. name, relname)
        end
      end
    end
  end
  watch_one(dir, '')
  walk(dir, '')
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
  local function skip_git(rel)
    return rel == 'objects' or rel:match('^objects/') or rel == 'logs' or rel:match('^logs/')
  end
  watch_dir(info.git_dir, relevant, 'fs', nil, skip_git)
  if info.common_dir ~= info.git_dir then
    watch_dir(info.common_dir, relevant, 'fs', nil, skip_git)
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
