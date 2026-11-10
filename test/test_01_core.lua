local h = require('helpers')

-- A domain for the tests: counts installs, emits on demand.
local PROBE = [[
  local core = require('nvimos')
  _G.probe = { installs = 0, uninstalls = 0 }
  core.register('probe', {
    install = function() probe.installs = probe.installs + 1 end,
    uninstall = function() probe.uninstalls = probe.uninstalls + 1 end,
    snapshot = function() return { hello = 'world' } end,
  })
]]

return {
  {
    'core: attach returns version, channel, seq and snapshot',
    function()
      local n = h.nvim()
      n:lua(PROBE)
      local r = n:attach({ 'probe' })
      h.eq(1, r.v)
      h.ok(type(r.chan) == 'number' and r.chan > 0, 'chan')
      h.eq({ probe = 0 }, r.seq)
      h.eq({ probe = { hello = 'world' } }, r.snapshot)
    end,
  },
  {
    'core: events carry v, domain, seq, reason; seq has no gaps',
    function()
      local n = h.nvim()
      n:lua(PROBE)
      n:attach({ 'probe' })
      n:lua("for i = 1, 5 do require('nvimos').emit('probe', 'tick', { i = i }) end")
      n:settle()
      local evs = n:events('probe')
      h.eq(5, #evs)
      h.no_gaps(evs, 0)
      h.eq({ v = 1, domain = 'probe', seq = 1, reason = 'tick', i = 1 }, evs[1])
    end,
  },
  {
    'core: hooks install on first subscriber and uninstall on detach',
    function()
      local n = h.nvim()
      n:lua(PROBE)
      h.eq(0, n:lua('return probe.installs'))
      n:attach({ 'probe' })
      h.eq(1, n:lua('return probe.installs'))
      h.eq({ 'probe' }, n:lua("return require('nvimos').status().active"))
      n:lua("require('nvimos').detach(...)", { chan = n:chan() })
      h.eq(1, n:lua('return probe.uninstalls'))
      h.eq({}, n:lua("return require('nvimos').status().active"))
      n:lua("require('nvimos').emit('probe', 'tick', {})")
      n:settle()
      h.eq(0, #n:events())
    end,
  },
  {
    'core: unsubscribed domains send nothing',
    function()
      local n = h.nvim()
      n:lua(PROBE)
      n:lua("require('nvimos').register('other', { install = function() end, uninstall = function() end, snapshot = function() return {} end })")
      n:attach({ 'probe' })
      n:lua("require('nvimos').emit('other', 'tick', {})")
      n:settle()
      h.eq(0, #n:events())
    end,
  },
  {
    'core: resync returns the current seq and a snapshot',
    function()
      local n = h.nvim()
      n:lua(PROBE)
      n:attach({ 'probe' })
      n:lua("for i = 1, 3 do require('nvimos').emit('probe', 'tick', {}) end")
      local r = n:lua("return require('nvimos').resync('probe')")
      h.eq({ v = 1, domain = 'probe', seq = 3, snapshot = { hello = 'world' } }, r)
    end,
  },
  {
    'core: attach without a valid channel is an error',
    function()
      local n = h.nvim()
      local ok, err = pcall(n.lua, n, "return require('nvimos').attach({ chan = 9999 })")
      h.ok(not ok and tostring(err):find('pass opts.chan'), tostring(err))
    end,
  },
  {
    'core: unknown domain is an error',
    function()
      local n = h.nvim()
      local ok, err = pcall(n.attach, n, { 'nope' })
      h.ok(not ok and tostring(err):find('unknown domain nope'), tostring(err))
    end,
  },
  {
    'core: a client over TCP is dropped when its channel closes',
    function()
      local n = h.nvim()
      n:lua(PROBE)
      local port = math.random(30000, 40000)
      n:request('nvim_call_function', 'serverstart', { '127.0.0.1:' .. port })
      local c = h.connect('127.0.0.1', port)
      c:attach({ 'probe' })
      h.eq(1, #n:lua("return require('nvimos').status().clients"))
      n:lua("require('nvimos').emit('probe', 'tick', {})")
      h.ok(c:wait_for(function(ev)
        return ev.reason == 'tick'
      end), 'tcp client got the event')
      c:close()
      vim.wait(2000, function()
        return #n:lua("return require('nvimos').status().clients") == 0
      end, 20)
      h.eq({}, n:lua("return require('nvimos').status()").clients)
      h.eq({}, n:lua("return require('nvimos').status().active"))
    end,
  },
}
