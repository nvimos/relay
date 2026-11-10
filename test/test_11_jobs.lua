local h = require('helpers')

-- git stands in for a long-running agent: allowed only in these tests.
local ALLOW_GIT = "require('nvimos.jobs').allowed.git = true"

return {
  {
    'jobs: a job runs without blocking and sends started and finished',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      n:lua(ALLOW_GIT)
      n:attach({ 'jobs' })
      local id = n:lua("return require('nvimos.jobs').start('git', { 'log', '--format=%s' }, { label = 'log' })")
      h.eq(2, n:request('nvim_eval', '1 + 1')) -- Neovim answers while the job runs
      local fin = n:wait_for(function(e)
        return e.domain == 'jobs' and e.reason == 'finished' and e.id == id
      end, 5000)
      h.ok(fin, vim.inspect(n:events('jobs')))
      h.eq({ 0, 'log', 'first\n' }, { fin.code, fin.label, fin.stdout })
      h.ok(n:wait_for(function(e)
        return e.reason == 'started'
      end), 'started')
      h.eq(false, n:lua('return require("nvimos.jobs").get(...)', id).running)
    end,
  },
  {
    'jobs: stdin reaches the command; commands outside the list are refused',
    function()
      local d = h.repo()
      local n = h.nvim({ cwd = d })
      n:lua(ALLOW_GIT)
      n:attach({ 'jobs' })
      local id = n:lua("return require('nvimos.jobs').start('git', { 'hash-object', '--stdin' }, { stdin = 'hello' })")
      local fin = n:wait_for(function(e)
        return e.reason == 'finished' and e.id == id
      end, 5000)
      h.eq('b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0\n', fin and fin.stdout)
      local ok, err = pcall(n.lua, n, "return require('nvimos.jobs').start('cmd', { '/c', 'dir' })")
      h.ok(not ok and tostring(err):find('not allowed'), tostring(err))
    end,
  },
}
