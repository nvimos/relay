-- Show things in Neovim for the GUI: a working-tree file at a line, or a file as it is on some
-- revision, in a read-only buffer.
local repo = require('nvimos.repo')
local api = vim.api

local M = {}

local function same(a, b)
  return vim.fs.normalize(a):lower() == vim.fs.normalize(b):lower()
end

local function find_buf(path)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if name ~= '' and same(name, path) then
      return buf
    end
  end
end

-- Focus a window in this tab showing `buf`, or show it in the current window.
local function show_buf(buf)
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == buf then
      api.nvim_set_current_win(win)
      return win
    end
  end
  api.nvim_win_set_buf(0, buf)
  return api.nvim_get_current_win()
end

local function place(win, lnum, col)
  local buf = api.nvim_win_get_buf(win)
  local count = api.nvim_buf_line_count(buf)
  lnum = math.max(1, math.min(lnum or 1, count))
  api.nvim_win_set_cursor(win, { lnum, col or 0 })
  api.nvim_win_call(win, function()
    vim.cmd('normal! zz')
  end)
end

--- Edit a working-tree file (absolute, or relative to the repo root) at lnum (1-based), col (0-based).
function M.open(path, lnum, col)
  local ok, full = pcall(repo.path, path)
  if not ok then
    full = vim.fs.normalize(vim.fs.abspath(path))
  end
  local buf = find_buf(full)
  local win
  if buf then
    win = show_buf(buf)
  else
    vim.cmd.edit(vim.fn.fnameescape(full))
    win = api.nvim_get_current_win()
    buf = api.nvim_get_current_buf()
  end
  place(win, lnum, col)
  return { buf = buf, win = win }
end

--- Show `path` (relative to the repo root) as it is on `rev`, in a read-only buffer named
--- nvimos://<rev>/<path>, at lnum. Reuses the buffer if it exists.
function M.show(rev, path, lnum, col)
  path = vim.fs.normalize(path):gsub('^/', '')
  local name = ('nvimos://%s/%s'):format(rev, path)
  local buf
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(b) == name then
      buf = b
    end
  end
  if not buf then
    local text = repo.git({ 'show', rev .. ':' .. path })
    local lines = vim.split(text, '\n', { plain = true })
    if lines[#lines] == '' then
      lines[#lines] = nil
    end
    buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, name)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    local ft = vim.filetype.match({ filename = path, buf = buf })
    if ft then
      vim.bo[buf].filetype = ft
    end
  end
  local win = show_buf(buf)
  place(win, lnum, col)
  return { buf = buf, win = win }
end

return M
