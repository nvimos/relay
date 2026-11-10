local h = require('helpers')

return {
  {
    'smoke: plugin loads over RPC',
    function()
      local n = h.nvim()
      h.eq(1, n:lua("return require('nvimos').version()"))
    end,
  },
}
