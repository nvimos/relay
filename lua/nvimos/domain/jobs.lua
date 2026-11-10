-- jobs domain: `started` and `finished` events of commands started with nvimos.jobs.start.
-- No hooks of its own; the jobs module emits when this domain is active.
local M = {}

function M.install() end

function M.uninstall() end

function M.snapshot()
  return { jobs = require('nvimos.jobs').list() }
end

return M
