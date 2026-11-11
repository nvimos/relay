local h = require('helpers')

-- A code repo whose .nvimos points at a separate planning folder.
local function split_repos(extra)
  local plan = h.tmpdir()
  h.write(plan .. '/backlog/tasks/task-1 - first.md', { '---', 'id: TASK-1', 'status: To Do', '---' })
  local code = h.repo()
  local lines = { '# planning lives elsewhere', 'tracking = ' .. plan, 'project = frontend' }
  vim.list_extend(lines, extra or {})
  h.write(code .. '/.nvimos', lines)
  return code, plan
end

local function L(n, mod, fn, ...)
  return n:lua(("return require('%s').%s(...)"):format(mod, fn), ...)
end

return {
  {
    'tracking: without .nvimos the planning folder is the repo root',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      local t = L(n, 'nvimos.tracking', 'info')
      h.eq(d:lower(), t.root:lower())
      h.eq(vim.NIL, t.project)
      h.eq(vim.NIL, t.file)
    end,
  },
  {
    'tracking: .nvimos names the planning folder and the project; files work there',
    function()
      local code, plan = split_repos()
      local n = h.nvim({ cwd = code })
      local t = L(n, 'nvimos.tracking', 'info')
      h.eq(plan:lower(), t.root:lower())
      h.eq(code:lower(), t.repo_root:lower())
      h.eq('frontend', t.project)
      local list = L(n, 'nvimos.files', 'list', { 'backlog' })
      h.eq('backlog/tasks/task-1 - first.md', list[1] and list[1].path)
      L(n, 'nvimos.files', 'create', 'backlog/tasks/task-2 - second.md', { '---', 'id: TASK-2', '---' })
      h.ok(vim.uv.fs_stat(plan .. '/backlog/tasks/task-2 - second.md'), 'created in the planning folder')
      h.ok(not vim.uv.fs_stat(code .. '/backlog'), 'nothing in the code repo')
    end,
  },
  {
    'tracking: a relative path is relative to the repo root; a missing folder falls back',
    function()
      local code = h.repo()
      vim.fn.mkdir(code .. '/plan/backlog', 'p')
      h.write(code .. '/.nvimos', { 'tracking = plan' })
      local n = h.nvim({ cwd = code })
      h.eq((code .. '/plan'):lower(), L(n, 'nvimos.tracking', 'info').root:lower())
      h.write(code .. '/.nvimos', { 'tracking = nowhere', 'project = x' })
      vim.uv.fs_utime(code .. '/.nvimos', os.time() + 5, os.time() + 5)
      local t = L(n, 'nvimos.tracking', 'info')
      h.eq(code:lower(), t.root:lower())
      h.ok(t.missing and t.missing:find('nowhere$'), vim.inspect(t))
    end,
  },
  {
    'tracking: an edit in the planning folder outside Neovim sends a git hint with why=files',
    function()
      local code, plan = split_repos()
      local n = h.nvim({ cwd = code })
      n:attach({ 'git' })
      h.write(plan .. '/backlog/tasks/task-3 - third.md', { '---', 'id: TASK-3', '---' })
      local ev = n:wait_for(function(e)
        return e.reason == 'changed' and vim.tbl_contains(e.why, 'files')
      end, 4000)
      h.ok(ev, vim.inspect(n:events('git')))
      h.ok(vim.tbl_contains(ev.paths, 'backlog/tasks/task-3 - third.md'), vim.inspect(ev.paths))
    end,
  },
  {
    'tracking: parse skips comments and trims values',
    function()
      local n = h.nvim({})
      local got = L(n, 'nvimos.tracking', 'parse', { '# tracking = no', '  tracking =  ~/plan  ', 'project=x', 'junk' })
      h.eq({ tracking = '~/plan', project = 'x' }, got)
    end,
  },
}
