local h = require('helpers')

return {
  {
    'dirs: set changes the cwd, and the repo follows it',
    function()
      local d = h.repo()
      local n = h.nvim()
      local cwd = n:lua("return require('nvimos.dirs').set(...)", d)
      h.eq(d:lower(), cwd:lower())
      local root = n:lua("return require('nvimos.repo').info().root")
      h.eq(d:lower(), root:lower())
    end,
  },
  {
    'dirs: set of a missing dir is an error',
    function()
      local n = h.nvim()
      local ok, err = pcall(n.lua, n, "return require('nvimos.dirs').set(...)", 'Z:/no/such/dir')
      h.ok(not ok and tostring(err):find('not a directory'), tostring(err))
    end,
  },
  {
    'dirs: list falls back to the dirs of recent files',
    function()
      local d = h.repo()
      local n = h.nvim()
      n:request('nvim_set_vvar', 'oldfiles', { d .. '/a.txt', d .. '/b.txt', 'term://x' })
      local r = n:lua("return require('nvimos.dirs').list()")
      h.eq('oldfiles', r.source)
      h.eq({ d:lower() }, vim.tbl_map(string.lower, r.dirs))
    end,
  },
  {
    'dirs: list uses genja-startdirs ranked() when it is there',
    function()
      local n = h.nvim()
      n:lua("package.loaded['genja-startdirs'] = { ranked = function() return { '~', 'C:\\\\x' } end }")
      local r = n:lua("return require('nvimos.dirs').list()")
      h.eq('startdirs', r.source)
      h.eq(2, #r.dirs)
      h.eq('C:/x', r.dirs[2])
    end,
  },
  {
    'dirs: plugin_root is the dir with lua/nvimos',
    function()
      local n = h.nvim()
      local root = n:lua("return require('nvimos.dirs').plugin_root()")
      h.eq(vim.fs.normalize(h.root):lower(), root:lower())
    end,
  },
  {
    'nav: open splits when the current buffer has unsaved changes',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit b.txt')
      n:request('nvim_buf_set_lines', 0, 0, 0, false, { 'unsaved' })
      local wins = #n:request('nvim_tabpage_list_wins', 0)
      n:lua("return require('nvimos').open(...)", 'a.txt', 2)
      h.eq(wins + 1, #n:request('nvim_tabpage_list_wins', 0))
      h.ok(n:request('nvim_buf_get_name', 0):find('a.txt$'), 'a.txt is current')
    end,
  },
}
