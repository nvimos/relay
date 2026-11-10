-- nvimos: stream Neovim's state to an RPC client as typed, ordered events.
local M = {}

M.API_VERSION = 1

function M.version()
  return M.API_VERSION
end

return M
