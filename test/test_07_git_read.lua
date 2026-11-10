local h = require('helpers')

-- main: a.txt (5 lines), b.txt. feature: two commits changing a.txt, adding c.txt, removing b.txt.
local function pr_repo()
  local d = h.repo()
  h.git(d, 'checkout', '-q', '-b', 'feature')
  h.write(d .. '/a.txt', { 'one', 'TWO', 'three', 'four', 'five', 'six' })
  h.git(d, 'commit', '-q', '-am', 'edit a')
  h.write(d .. '/c.txt', { 'new file' })
  h.git(d, 'add', 'c.txt')
  h.git(d, 'rm', '-q', 'b.txt')
  h.git(d, 'commit', '-q', '-m', 'add c | drop b')
  h.git(d, 'checkout', '-q', 'main')
  return d
end

local function by_path(files)
  local out = {}
  for _, f in ipairs(files) do
    out[f.path] = f
  end
  return out
end

return {
  {
    'git read: branches lists local branches and the current one',
    function()
      local d = pr_repo()
      local n = h.nvim({ cwd = d })
      local r = n:lua("return require('nvimos.git').branches()")
      h.eq('main', r.current)
      local names = {}
      for _, b in ipairs(r.branches) do
        names[#names + 1] = b.name .. (b.current and '*' or '')
      end
      table.sort(names)
      h.eq({ 'feature', 'main*' }, names)
    end,
  },
  {
    'git read: log of base..head, newest first, subjects with | intact',
    function()
      local d = pr_repo()
      local n = h.nvim({ cwd = d })
      local r = n:lua("return require('nvimos.git').log(...)", 'main', 'feature')
      h.eq(2, #r)
      h.eq('add c | drop b', r[1].subject)
      h.eq('edit a', r[2].subject)
      h.eq('Test', r[1].author)
      h.ok(#r[1].sha == 40 and r[1].date > 0, vim.inspect(r[1]))
    end,
  },
  {
    'git read: diff base...head has files, statuses, counts and line numbers',
    function()
      local d = pr_repo()
      local n = h.nvim({ cwd = d })
      local r = n:lua("return require('nvimos.git').diff(...)", 'main', 'feature')
      local f = by_path(r.files)
      h.eq('modified', f['a.txt'].status)
      h.eq('added', f['c.txt'].status)
      h.eq('deleted', f['b.txt'].status)
      h.eq({ 2, 1 }, { f['a.txt'].additions, f['a.txt'].deletions })
      local hk = f['a.txt'].hunks[1]
      h.eq(1, hk.old_start)
      local two
      for _, l in ipairs(hk.lines) do
        if l.text == 'TWO' then
          two = l
        end
      end
      h.eq({ kind = 'add', text = 'TWO', new = 2 }, two)
      h.eq(40, #r.merge_base)
    end,
  },
  {
    'git read: diff detects renames',
    function()
      local d = h.repo()
      h.git(d, 'checkout', '-q', '-b', 'mv')
      h.git(d, 'mv', 'a.txt', 'z.txt')
      h.git(d, 'commit', '-q', '-m', 'rename')
      local n = h.nvim({ cwd = d })
      local r = n:lua("return require('nvimos.git').diff(...)", 'main', 'mv')
      h.eq(1, #r.files)
      h.eq({ 'renamed', 'a.txt', 'z.txt' }, { r.files[1].status, r.files[1].old_path, r.files[1].path })
    end,
  },
  {
    'git read: status splits staged, unstaged and untracked',
    function()
      local d = h.repo()
      h.write(d .. '/a.txt', { 'changed' })
      h.git(d, 'add', 'a.txt')
      h.write(d .. '/b.txt', { 'changed too' })
      h.write(d .. '/new dir/n.txt', { 'n' })
      local n = h.nvim({ cwd = d })
      local r = n:lua("return require('nvimos.git').status()")
      h.eq('main', r.branch)
      local f = by_path(r.files)
      h.eq({ true, false, false }, { f['a.txt'].staged, f['a.txt'].unstaged, f['a.txt'].untracked })
      h.eq({ false, true, false }, { f['b.txt'].staged, f['b.txt'].unstaged, f['b.txt'].untracked })
      h.eq(true, f['new dir/n.txt'].untracked)
    end,
  },
  {
    'git read: diff_file for unstaged, staged and untracked files',
    function()
      local d = h.repo()
      h.write(d .. '/a.txt', { 'one', 'two', 'THREE', 'four', 'five' })
      h.git(d, 'add', 'a.txt')
      h.write(d .. '/a.txt', { 'one', 'two', 'THREE', 'four', 'FIVE' })
      h.write(d .. '/u.txt', { 'u1', 'u2' })
      local n = h.nvim({ cwd = d })
      local staged = n:lua("return require('nvimos.git').diff_file(...)", 'a.txt', true)
      local unstaged = n:lua("return require('nvimos.git').diff_file(...)", 'a.txt', false)
      local untracked = n:lua("return require('nvimos.git').diff_file(...)", 'u.txt', false)
      h.eq(1, staged.additions)
      h.eq({ kind = 'del', text = 'three', old = 3 }, staged.hunks[1].lines[3])
      h.eq({ kind = 'add', text = 'THREE', new = 3 }, staged.hunks[1].lines[4])
      h.eq('FIVE', unstaged.hunks[1].lines[#unstaged.hunks[1].lines].text)
      h.eq({ 'added', 2, 'u.txt' }, { untracked.status, untracked.additions, untracked.path })
      h.eq(nil, n:lua("return require('nvimos.git').diff_file(...)", 'b.txt', false))
    end,
  },
}
