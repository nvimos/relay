-- Only a command here; the plugin loads when a client calls it or :NvimosServe runs.
vim.api.nvim_create_user_command('NvimosServe', function(a)
  require('nvimos').serve(a.args ~= '' and a.args or nil)
end, { nargs = '?', desc = 'nvimos: listen for the GUI on 127.0.0.1:6666 (or the given address)' })

vim.api.nvim_create_user_command('NvimosStatus', function()
  print(vim.inspect(require('nvimos').status()))
end, { desc = 'nvimos: attached clients, active domains, seq' })
