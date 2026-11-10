local h = require('helpers')

local function lines(n)
  local out = {}
  for i = 1, n do
    out[i] = 'line ' .. i
  end
  return out
end

return {
  {
    'windows: snapshot has the current window and cursor',
    function()
      local n = h.nvim()
      local r = n:attach({ 'windows' })
      local s = r.snapshot.windows
      h.eq({ 1, 0 }, s.current.cursor)
      h.eq(1, #s.windows)
      h.eq(false, s.current.float)
    end,
  },
  {
    'windows: cursor moves are sent, throttled, with the latest position',
    function()
      local n = h.nvim()
      local buf = n:request('nvim_get_current_buf')
      n:request('nvim_buf_set_lines', buf, 0, -1, false, lines(50))
      n:attach({ 'windows' })
      for row = 2, 20 do
        n:request('nvim_win_set_cursor', 0, { row, 0 })
      end
      n:request('nvim_command', 'normal! 3l')
      local ev = n:wait_for(function(e)
        return e.reason == 'cursor_moved' and e.cursor[1] == 20 and e.cursor[2] == 3
      end)
      h.ok(ev, vim.inspect(n:events('windows')))
      local count = 0
      for _, e in ipairs(n:events('windows')) do
        count = count + (e.reason == 'cursor_moved' and 1 or 0)
      end
      h.ok(count < 19, 'not throttled: ' .. count)
    end,
  },
  {
    'windows: split and close send win_new, focus and win_closed',
    function()
      local n = h.nvim()
      n:attach({ 'windows' })
      n:request('nvim_command', 'vsplit')
      local win = n:request('nvim_get_current_win')
      n:request('nvim_command', 'close')
      n:settle()
      local seen = {}
      for _, e in ipairs(n:events('windows')) do
        seen[e.reason] = seen[e.reason] or e
      end
      h.ok(seen.win_new, 'win_new')
      h.eq(win, seen.focus and seen.focus.win, 'focus on new window')
      h.eq(win, seen.win_closed and seen.win_closed.win, 'win_closed')
      h.no_gaps(n:events('windows'), 0)
    end,
  },
  {
    'windows: buffers domain alone sends no window events',
    function()
      local n = h.nvim()
      local buf = n:request('nvim_get_current_buf')
      n:request('nvim_buf_set_lines', buf, 0, -1, false, lines(10))
      n:attach({ 'buffers' })
      n:request('nvim_win_set_cursor', 0, { 5, 0 })
      n:request('nvim_command', 'vsplit')
      n:settle(100)
      h.eq({}, n:events('windows'))
    end,
  },
}
