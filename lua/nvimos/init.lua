-- nvimos: stream Neovim's state to an RPC client as typed, ordered events.
--
-- A client attaches over RPC (nvim_exec_lua) and names the domains it wants. Each domain installs
-- its autocommands only while some client subscribes to it, so nothing runs when no one listens.
-- Events are `nvimos` notifications with { v, domain, seq, reason, ... }; seq goes up by one per
-- domain, so a client sees a gap and resyncs.
local M = {}

M.API_VERSION = 1

-- Built-in domains, loaded on first use from lua/nvimos/domain/<name>.lua.
local BUILTIN = { 'buffers', 'windows', 'git', 'diagnostics', 'jobs' }

local domains = {} -- name -> { install, uninstall, snapshot }
local seq = {} -- name -> last seq sent
local active = {} -- name -> true while installed
local clients = {} -- chan -> { domains = { name = true } }
local core_group -- ChanClose watcher, present while any client is attached (see watch_channels)

function M.version()
  return M.API_VERSION
end

--- Add a domain. `mod` has install(), uninstall() and snapshot().
function M.register(name, mod)
  domains[name] = mod
  seq[name] = seq[name] or 0
end

local function domain(name)
  if not domains[name] and vim.tbl_contains(BUILTIN, name) then
    M.register(name, require('nvimos.domain.' .. name))
  end
  return domains[name]
end

local function names()
  local out = vim.deepcopy(BUILTIN)
  for name in pairs(domains) do
    if not vim.tbl_contains(out, name) then
      out[#out + 1] = name
    end
  end
  return out
end

function M.active(name)
  return active[name] == true
end

function M.seq(name)
  return seq[name]
end

local refresh

-- Drop clients whose channel closed. With the ChanClose event (newer Neovim) on that;
-- without it (stable), by checking every POLL_MS whether each client's channel still exists.
-- vim.g.nvimos_chan_poll = true forces the polling (tests).
local POLL_MS = 1000
local poll_timer

local function drop_closed()
  local gone = false
  for chan in pairs(clients) do
    if vim.tbl_isempty(vim.api.nvim_get_chan_info(chan)) then
      clients[chan] = nil
      gone = true
    end
  end
  if gone then
    refresh()
  end
end

local function watch_channels()
  local any = next(clients) ~= nil
  local event = vim.fn.exists('##ChanClose') == 1 and not vim.g.nvimos_chan_poll
  if any and event and not core_group then
    core_group = vim.api.nvim_create_augroup('nvimos_core', { clear = true })
    vim.api.nvim_create_autocmd('ChanClose', {
      group = core_group,
      callback = function()
        local chan = vim.v.event.info and vim.v.event.info.id
        if chan and clients[chan] then
          clients[chan] = nil
          refresh()
        end
      end,
    })
  elseif any and not event and not poll_timer then
    poll_timer = vim.uv.new_timer()
    poll_timer:start(POLL_MS, POLL_MS, vim.schedule_wrap(drop_closed))
  elseif not any then
    if core_group then
      vim.api.nvim_del_augroup_by_id(core_group)
      core_group = nil
    end
    if poll_timer then
      poll_timer:stop()
      poll_timer:close()
      poll_timer = nil
    end
  end
end

--- Install the hooks of domains someone subscribes to, remove the rest.
function refresh()
  watch_channels()
  for name, mod in pairs(domains) do
    local want = false
    for _, c in pairs(clients) do
      if c.domains[name] then
        want = true
        break
      end
    end
    if want and not active[name] then
      active[name] = true
      mod.install()
    elseif not want and active[name] then
      active[name] = nil
      mod.uninstall()
    end
  end
end

--- Send an event to every client subscribed to `name`. No-op while the domain is inactive.
function M.emit(name, reason, ev)
  if not active[name] then
    return
  end
  seq[name] = seq[name] + 1
  ev = ev or {}
  ev.v, ev.domain, ev.seq, ev.reason = M.API_VERSION, name, seq[name], reason
  local dead
  for chan, c in pairs(clients) do
    if c.domains[name] and not pcall(vim.rpcnotify, chan, 'nvimos', ev) then
      dead = dead or {}
      dead[#dead + 1] = chan
    end
  end
  if dead then
    for _, chan in ipairs(dead) do
      clients[chan] = nil
    end
    refresh()
  end
end

-- nvim_exec_lua doesn't tell Lua which channel called, so the client passes its own id
-- (the first item of nvim_get_api_info()).
local function caller(opts)
  local chan = opts and opts.chan
  if type(chan) ~= 'number' or vim.tbl_isempty(vim.api.nvim_get_chan_info(chan)) then
    error('nvimos: pass opts.chan, your channel id from nvim_get_api_info()', 0)
  end
  return chan
end

--- Subscribe a channel. opts.chan: the client's channel id; opts.domains: list of names (default:
--- all built-in).
--- Returns { v, chan, seq = { name = n }, snapshot = { name = ... } }; later events have seq > n.
function M.attach(opts)
  opts = opts or {}
  local chan = caller(opts)
  local want = {}
  for _, name in ipairs(opts.domains or BUILTIN) do
    if not domain(name) then
      error('nvimos: unknown domain ' .. tostring(name), 0)
    end
    want[name] = true
  end
  clients[chan] = { domains = want }
  refresh()
  local res = { v = M.API_VERSION, chan = chan, seq = {}, snapshot = {} }
  for name in pairs(want) do
    res.seq[name] = seq[name]
    res.snapshot[name] = domains[name].snapshot()
  end
  return res
end

--- Unsubscribe a channel (opts.chan).
function M.detach(opts)
  clients[caller(opts)] = nil
  refresh()
  return true
end

--- A full snapshot of one domain, tagged with its current seq. Events with seq <= this are stale.
function M.resync(name)
  local mod = domain(name)
  if not mod then
    error('nvimos: unknown domain ' .. tostring(name), 0)
  end
  return { v = M.API_VERSION, domain = name, seq = seq[name], snapshot = mod.snapshot() }
end

M.DEFAULT_ADDRESS = '127.0.0.1:6666'

--- Listen for clients on `addr` (default 127.0.0.1:6666) in a running Neovim. Returns the address.
function M.serve(addr)
  addr = addr or M.DEFAULT_ADDRESS
  if not vim.tbl_contains(vim.fn.serverlist(), addr) then
    vim.fn.serverstart(addr)
  end
  M.served = addr
  vim.notify('nvimos: listening on ' .. addr)
  return addr
end

--- Stop listening on `addr` (default: the address `serve` last started, else 127.0.0.1:6666).
--- Connected clients stay attached. Returns the address, or nil if it was not listening.
function M.serve_stop(addr)
  addr = addr or M.served or M.DEFAULT_ADDRESS
  if M.served == addr then
    M.served = nil
  end
  if not vim.tbl_contains(vim.fn.serverlist(), addr) then
    vim.notify('nvimos: not listening on ' .. addr)
    return nil
  end
  vim.fn.serverstop(addr)
  vim.notify('nvimos: stopped listening on ' .. addr)
  return addr
end

--- Edit a working-tree file at a line; see nav.lua.
function M.open(path, lnum, col)
  return require('nvimos.nav').open(path, lnum, col)
end

--- Show a file as it is on a revision, read-only; see nav.lua.
function M.show(rev, path, lnum, col)
  return require('nvimos.nav').show(rev, path, lnum, col)
end

--- Full text of a buffer; see domain/buffers.lua.
function M.get_text(buf)
  return require('nvimos.domain.buffers').get_text(buf)
end

--- What is attached and installed, for debugging.
function M.status()
  local out = { clients = {}, active = {}, seq = vim.deepcopy(seq), domains = names() }
  for chan, c in pairs(clients) do
    out.clients[#out.clients + 1] = { chan = chan, domains = vim.tbl_keys(c.domains) }
  end
  for name in pairs(active) do
    out.active[#out.active + 1] = name
  end
  table.sort(out.active)
  return out
end

return M
