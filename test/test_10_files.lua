local h = require('helpers')

-- A repo with a tiny planning layout.
local function plan_repo()
  local d = h.repo()
  h.write(d .. '/backlog/tasks/task-1 - first.md', { '---', 'id: TASK-1', 'status: To Do', '---', '', '- [ ] step' })
  h.write(d .. '/openspec/changes/1-first/proposal.md', { '# 1. first', '', 'Status: To Do (backlog TASK-1)' })
  h.write(d .. '/openspec/changes/1-first/tasks.md', { '# Tasks', '', '## 1. Build', '', '- [ ] 1.1 do it' })
  return d
end

local function F(n, fn, ...)
  return n:lua("return require('nvimos.files')." .. fn .. '(...)', ...)
end

return {
  {
    'files: list walks the given dirs, sorted, relative paths',
    function()
      local d = plan_repo()
      local n = h.nvim({ cwd = d })
      local paths = {}
      for _, f in ipairs(F(n, 'list', { 'backlog', 'openspec', 'legacy' })) do
        paths[#paths + 1] = f.path
      end
      h.eq({
        'backlog/tasks/task-1 - first.md',
        'openspec/changes/1-first/proposal.md',
        'openspec/changes/1-first/tasks.md',
      }, paths)
    end,
  },
  {
    'files: read prefers an open buffer with unsaved edits',
    function()
      local d = plan_repo()
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit openspec/changes/1-first/tasks.md')
      n:request('nvim_buf_set_lines', 0, 4, 5, false, { '- [x] 1.1 do it' })
      local r = F(n, 'read', { 'openspec/changes/1-first/tasks.md', 'backlog/tasks/task-1 - first.md', 'nope.md' })
      h.eq({ true, '- [x] 1.1 do it' }, { r[1].buffer, r[1].lines[5] })
      h.eq({ false, 'id: TASK-1' }, { r[2].buffer, r[2].lines[2] })
      h.eq(false, r[3].exists)
    end,
  },
  {
    'files: set_lines edits through a buffer and writes; expect guards stale edits',
    function()
      local d = plan_repo()
      local n = h.nvim({ cwd = d })
      local p = 'backlog/tasks/task-1 - first.md'
      F(n, 'set_lines', p, {
        { first = 2, last = 3, lines = { 'status: In Progress' }, expect = { 'status: To Do' } },
        { first = 5, last = 6, lines = { '- [x] step' } },
      })
      h.eq({ '---', 'id: TASK-1', 'status: In Progress', '---', '', '- [x] step' }, vim.fn.readfile(d .. '/' .. p))
      local ok, err = pcall(F, n, 'set_lines', p, { { first = 2, last = 3, lines = { 'status: Done' }, expect = { 'status: To Do' } } })
      h.ok(not ok and tostring(err):find('changed since'), tostring(err))
      h.eq('status: In Progress', vim.fn.readfile(d .. '/' .. p)[3])
      h.eq(0, #vim.tbl_filter(function(b)
        return b ~= ''
      end, vim.tbl_map(function(b)
        return n:request('nvim_buf_get_name', b):find('task%-1') and 'x' or ''
      end, n:request('nvim_list_bufs'))))
    end,
  },
  {
    'files: set_lines refuses a buffer with unsaved changes',
    function()
      local d = plan_repo()
      local n = h.nvim({ cwd = d })
      local p = 'backlog/tasks/task-1 - first.md'
      n:request('nvim_command', 'edit ' .. vim.fn.fnameescape(p))
      n:request('nvim_buf_set_lines', 0, 0, 0, false, { 'unsaved' })
      local ok, err = pcall(F, n, 'set_lines', p, { { first = 0, last = 0, lines = { 'x' } } })
      h.ok(not ok and tostring(err):find('unsaved'), tostring(err))
    end,
  },
  {
    'files: move archives a change folder; create refuses to overwrite',
    function()
      local d = plan_repo()
      local n = h.nvim({ cwd = d })
      n:request('nvim_command', 'edit openspec/changes/1-first/proposal.md')
      F(n, 'move', 'openspec/changes/1-first', 'openspec/changes/archive/2026-11-10-1-first')
      h.eq(1, vim.fn.filereadable(d .. '/openspec/changes/archive/2026-11-10-1-first/proposal.md'))
      h.eq(0, vim.fn.isdirectory(d .. '/openspec/changes/1-first'))
      F(n, 'create', 'backlog/tasks/task-2 - new.md', { '---', 'id: TASK-2', '---' })
      h.eq('id: TASK-2', vim.fn.readfile(d .. '/backlog/tasks/task-2 - new.md')[2])
      h.eq(false, (pcall(F, n, 'create', 'backlog/tasks/task-2 - new.md', { 'x' })))
    end,
  },
  {
    'files: cli runs only openspec and backlog, and reports a missing tool',
    function()
      local d = plan_repo()
      local n = h.nvim({ cwd = d })
      h.eq(false, (pcall(F, n, 'cli', 'git', { 'status' })))
      local r = F(n, 'cli', 'openspec', { 'list', '--json' })
      h.ok(type(r.code) == 'number', vim.inspect(r))
    end,
  },
  {
    'files: an edit under openspec/ outside Neovim sends a git hint with why=files',
    function()
      local d = plan_repo()
      local n = h.nvim({ cwd = d })
      n:attach({ 'git' })
      h.write(d .. '/openspec/changes/1-first/design.md', { '# design' })
      local ev = n:wait_for(function(e)
        return e.reason == 'changed' and vim.tbl_contains(e.why, 'files')
      end, 4000)
      h.ok(ev, vim.inspect(n:events('git')))
      h.ok(vim.tbl_contains(ev.paths, 'openspec/changes/1-first/design.md'), vim.inspect(ev.paths))
    end,
  },
}
