-- Files of the repo for the GUI's Tasks mode (OpenSpec, Backlog.md). Generic on purpose: the app
-- parses; this lists, reads, edits through buffers, moves and creates. Paths are relative to the
-- planning folder (the repo root, or the folder its `.nvimos` names; see tracking.lua), with forward
-- slashes.
local repo = require('nvimos.tracking')
local api = vim.api

local M = {}

local function rel(root, full)
  full = vim.fs.normalize(full)
  if full:lower():sub(1, #root + 1) == (root .. '/'):lower() then
    return full:sub(#root + 2)
  end
  return full
end

local function loaded_buf(full)
  local want = vim.fs.normalize(full):lower()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.fs.normalize(api.nvim_buf_get_name(buf)):lower() == want then
      return buf
    end
  end
end

--- Every file under the given dirs (relative to the planning folder): { { path, size, mtime } }, sorted.
--- Missing dirs are skipped.
function M.list(dirs)
  local root = repo.root()
  local out = {}
  for _, dir in ipairs(dirs) do
    local base = vim.fs.joinpath(root, dir)
    if vim.fn.isdirectory(base) == 1 then
      for name, kind in vim.fs.dir(base, { depth = 20 }) do
        if kind == 'file' then
          local full = vim.fs.joinpath(base, name)
          local st = vim.uv.fs_stat(full)
          out[#out + 1] = {
            path = rel(root, full),
            size = st and st.size or 0,
            mtime = st and st.mtime.sec or 0,
          }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

--- Contents of files: { { path, exists, lines, buffer } }. A loaded buffer wins over the disk, so
--- unsaved edits in Neovim show up (buffer = true).
function M.read(paths)
  local out = {}
  for _, p in ipairs(paths) do
    local full = repo.path(p)
    local buf = loaded_buf(full)
    if buf then
      out[#out + 1] = { path = p, exists = true, buffer = true, lines = api.nvim_buf_get_lines(buf, 0, -1, false) }
    elseif vim.fn.filereadable(full) == 1 then
      out[#out + 1] = { path = p, exists = true, buffer = false, lines = vim.fn.readfile(full) }
    else
      out[#out + 1] = { path = p, exists = false, buffer = false, lines = {} }
    end
  end
  return out
end

--- Replace line ranges of a file through its buffer, then write it. edits: list of
--- { first, last, lines, expect? } (zero-based, end exclusive). expect: the lines the range must
--- hold now; otherwise the file changed since the client read it and nothing is written.
--- Refuses a buffer with unsaved changes. Returns the new line count.
function M.set_lines(path, edits)
  local full = repo.path(path)
  if vim.fn.filereadable(full) ~= 1 then
    error('nvimos: no such file ' .. path, 0)
  end
  local buf = loaded_buf(full)
  local created = false
  if buf and vim.bo[buf].modified then
    error('nvimos: ' .. path .. ' has unsaved changes in Neovim', 0)
  end
  if not buf then
    buf = vim.fn.bufadd(full)
    vim.fn.bufload(buf)
    created = true
  end
  local ok, err = pcall(function()
    local sorted = vim.deepcopy(edits)
    for _, e in ipairs(sorted) do
      if e.expect then
        local now = api.nvim_buf_get_lines(buf, e.first, e.last, false)
        if not vim.deep_equal(now, e.expect) then
          error('nvimos: ' .. path .. ' changed since it was read; refresh and try again', 0)
        end
      end
    end
    table.sort(sorted, function(a, b)
      return a.first > b.first
    end)
    for _, e in ipairs(sorted) do
      api.nvim_buf_set_lines(buf, e.first, e.last, false, e.lines)
    end
    api.nvim_buf_call(buf, function()
      vim.cmd('silent write')
    end)
  end)
  local count = api.nvim_buf_line_count(buf)
  if created then
    if not ok and vim.bo[buf].modified then
      api.nvim_buf_call(buf, function()
        vim.cmd('silent edit!')
      end)
    end
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  if not ok then
    error(err, 0)
  end
  return count
end

--- Move a file or folder (archiving a change). Loaded, unchanged buffers under it are wiped first;
--- unsaved ones make it refuse.
function M.move(from, to)
  local src, dst = repo.path(from), repo.path(to)
  if not vim.uv.fs_stat(src) then
    error('nvimos: no such file or folder ' .. from, 0)
  end
  if vim.uv.fs_stat(dst) then
    error('nvimos: ' .. to .. ' already exists', 0)
  end
  local prefix = src:lower()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = vim.fs.normalize(api.nvim_buf_get_name(buf)):lower()
    if name == prefix or name:sub(1, #prefix + 1) == prefix .. '/' then
      if vim.bo[buf].modified then
        error('nvimos: unsaved changes in ' .. api.nvim_buf_get_name(buf), 0)
      end
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.fn.mkdir(vim.fs.dirname(dst), 'p')
  local ok, err = vim.uv.fs_rename(src, dst)
  if not ok then
    error('nvimos: move failed: ' .. tostring(err), 0)
  end
  return true
end

--- Create a file; refuses to overwrite.
function M.create(path, lines)
  local full = repo.path(path)
  if vim.uv.fs_stat(full) then
    error('nvimos: ' .. path .. ' already exists', 0)
  end
  vim.fn.mkdir(vim.fs.dirname(full), 'p')
  vim.fn.writefile(lines, full)
  return true
end

local CLIS = { openspec = true, backlog = true }

--- Run the openspec or backlog CLI in the planning folder: { code, stdout, stderr }. code -1 when the
--- tool isn't installed.
function M.cli(cmd, args)
  if not CLIS[cmd] then
    error('nvimos: only ' .. table.concat(vim.tbl_keys(CLIS), ', ') .. ' can run', 0)
  end
  local exe = vim.fn.exepath(cmd)
  if exe == '' then
    return { code = -1, stdout = '', stderr = cmd .. ' is not installed' }
  end
  local argv = { exe }
  vim.list_extend(argv, args or {})
  local ok, r = pcall(function()
    return vim.system(argv, { cwd = repo.root(), text = true }):wait(30000)
  end)
  if not ok then
    return { code = -1, stdout = '', stderr = tostring(r) }
  end
  return { code = r.code, stdout = r.stdout or '', stderr = r.stderr or '' }
end

return M
