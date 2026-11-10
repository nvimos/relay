-- windows domain: which window and buffer have focus, where the cursor is, windows opening and
-- closing. Cursor moves are throttled: at most one cursor_moved per THROTTLE_MS, with the latest
-- position.
local core = require('nvimos')
local api = vim.api

local M = {}

local THROTTLE_MS = 30

local group, timer
local last_focus

function M.state(win)
  win = win or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local cur = api.nvim_win_get_cursor(win)
  return {
    win = win,
    buf = buf,
    tab = api.nvim_win_get_tabpage(win),
    name = api.nvim_buf_get_name(buf),
    cursor = { cur[1], cur[2] }, -- row 1-based, col 0-based (bytes)
    topline = vim.fn.line('w0', win),
    botline = vim.fn.line('w$', win),
    float = api.nvim_win_get_config(win).relative ~= '',
  }
end

local function emit(reason, ev)
  core.emit('windows', reason, ev)
end

local function focus()
  local s = M.state()
  local key = s.win .. ':' .. s.buf
  if key ~= last_focus then
    last_focus = key
    emit('focus', s)
  end
end

local function cursor_soon()
  if timer:is_active() then
    return
  end
  timer:start(THROTTLE_MS, 0, vim.schedule_wrap(function()
    if core.active('windows') then
      emit('cursor_moved', M.state())
    end
  end))
end

function M.install()
  last_focus = nil
  timer = vim.uv.new_timer()
  group = api.nvim_create_augroup('nvimos_windows', { clear = true })
  local function au(events, fn)
    api.nvim_create_autocmd(events, {
      group = group,
      callback = function(a)
        fn(a)
      end,
    })
  end
  au({ 'WinEnter', 'BufEnter', 'BufWinEnter' }, focus)
  au({ 'CursorMoved', 'CursorMovedI', 'WinScrolled' }, cursor_soon)
  au('WinNew', function()
    emit('win_new', M.state())
  end)
  au('WinClosed', function(a)
    emit('win_closed', { win = tonumber(a.match) })
  end)
end

function M.uninstall()
  api.nvim_del_augroup_by_id(group)
  timer:stop()
  timer:close()
  timer = nil
end

function M.snapshot()
  local list = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    list[#list + 1] = M.state(win)
  end
  return { current = M.state(), windows = list }
end

return M
