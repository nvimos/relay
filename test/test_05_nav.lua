local h = require('helpers')

return {
  {
    'nav: open edits a repo file at a line and centers it',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      local r = n:lua("return require('nvimos').open(...)", 'a.txt', 3, 1)
      h.ok(n:request('nvim_buf_get_name', r.buf):find('a.txt$'), 'name')
      h.eq({ 3, 1 }, n:request('nvim_win_get_cursor', 0))
    end,
  },
  {
    'nav: open reuses the window that shows the file, and clamps the line',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      local first = n:lua("return require('nvimos').open(...)", 'a.txt', 1)
      n:request('nvim_command', 'vsplit b.txt')
      local again = n:lua("return require('nvimos').open(...)", 'a.txt', 99)
      h.eq(first.buf, again.buf)
      h.eq(first.win, again.win)
      h.eq({ 5, 0 }, n:request('nvim_win_get_cursor', 0))
    end,
  },
  {
    'nav: show opens a read-only buffer with the file on a revision',
    function()
      local d = h.repo()
      h.write(d .. '/a.txt', { 'changed' })
      h.git(d, 'commit', '-q', '-am', 'second')
      local n = h.nvim({ cwd = d })
      local r = n:lua("return require('nvimos').show(...)", 'HEAD~1', 'a.txt', 2)
      h.eq({ 'one', 'two', 'three', 'four', 'five' }, n:request('nvim_buf_get_lines', r.buf, 0, -1, false))
      h.eq(false, n:request('nvim_get_option_value', 'modifiable', { buf = r.buf }))
      h.eq('nofile', n:request('nvim_get_option_value', 'buftype', { buf = r.buf }))
      h.eq({ 2, 0 }, n:request('nvim_win_get_cursor', 0))
      local again = n:lua("return require('nvimos').show(...)", 'HEAD~1', 'a.txt', 4)
      h.eq(r.buf, again.buf)
    end,
  },
  {
    'nav: show of a missing file is an error',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      local ok, err = pcall(n.lua, n, "return require('nvimos').show(...)", 'HEAD', 'nope.txt', 1)
      h.ok(not ok and tostring(err):find('git show'), tostring(err))
    end,
  },
  {
    'nav: :NvimosServe listens, and a TCP client can attach',
    function()
      local n = h.nvim()
      local port = h.free_port()
      n:request('nvim_command', 'NvimosServe 127.0.0.1:' .. port)
      local c = h.connect('127.0.0.1', port)
      h.eq(1, c:attach({ 'windows' }).v)
    end,
  },
}
