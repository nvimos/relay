local h = require('helpers')

local function changed(n, pred)
  return n:wait_for(function(ev)
    return ev.domain == 'git' and ev.reason == 'changed' and (not pred or pred(ev))
  end, 4000)
end

return {
  {
    'git hints: snapshot has root, git dir and head',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      local s = n:attach({ 'git' }).snapshot.git
      h.eq(d:lower(), s.root:lower())
      h.eq('main', s.head)
      h.ok(s.git_dir:find('%.git$'), s.git_dir)
    end,
  },
  {
    'git hints: a checkout outside Neovim sends changed with the new head',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      n:attach({ 'git' })
      h.git(d, 'checkout', '-q', '-b', 'feature')
      local ev = changed(n, function(e)
        return e.head == 'feature'
      end)
      h.ok(ev, vim.inspect(n:events('git')))
      h.ok(vim.tbl_contains(ev.why, 'fs'), vim.inspect(ev.why))
    end,
  },
  {
    'git hints: staging outside Neovim sends changed for the index',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      n:attach({ 'git' })
      h.write(d .. '/a.txt', { 'x' })
      h.git(d, 'add', 'a.txt')
      local ev = changed(n, function(e)
        return vim.tbl_contains(e.paths, 'index')
      end)
      h.ok(ev, vim.inspect(n:events('git')))
    end,
  },
  {
    'git hints: writing a buffer sends changed with why=write and the path',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit a.txt')
      n:attach({ 'git' })
      n:request('nvim_buf_set_lines', 0, 0, 1, false, { 'ONE' })
      n:request('nvim_command', 'write')
      local ev = changed(n, function(e)
        return vim.tbl_contains(e.why, 'write')
      end)
      h.ok(ev, vim.inspect(n:events('git')))
      h.ok(ev.paths[1]:find('a.txt$'), vim.inspect(ev.paths))
    end,
  },
  {
    'git hints: many changes in a burst become few events',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      n:attach({ 'git' })
      for i = 1, 5 do
        h.git(d, 'branch', 'b' .. i)
      end
      h.ok(changed(n), 'changed')
      n:settle(300)
      h.ok(#n:events('git') <= 3, 'not debounced: ' .. #n:events('git'))
    end,
  },
  {
    'git hints: :cd to another repo sends repo',
    function()
      local d1, d2 = h.repo(), h.repo()
      local n = h.nvim({ cwd = d1 })
      n:attach({ 'git' })
      n:request('nvim_command', 'cd ' .. d2)
      local ev = n:wait_for(function(e)
        return e.reason == 'repo'
      end)
      h.ok(ev and ev.root:lower() == d2:lower(), vim.inspect(n:events('git')))
    end,
  },
}
