--[[
Copyright 2012 Rackspace

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS-IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
--]]


local async = require('async')
local utils = require('utils')
local JSON = require('json')
local Object = require('core').Object
local fmt = require('string').format
local logging = require('logging')
local timer = require('timer')
local dns = require('dns')
local fs = require('fs')
local path = require('path')

local ConnectionStream = require('./lib/client/connection_stream').ConnectionStream
local constants = require('./lib/util/constants')
local misc = require('./lib/util/misc')
local States = require('./lib/states')
local stateFile = require('./lib/state_file')
local fsutil = require('./lib/util/fs')
local UUID = require('./lib/util/uuid')

local table = require('table')

local MonitoringAgent = Object:extend()

function MonitoringAgent:_queryForEndpoints(domains, callback)
  local endpoints = ''
  function iter(domain, callback)
    dns.resolve(domain, 'SRV', function(err, results)
      if err then
        logging.log(logging.ERR, 'Could not lookup SRV record from ' .. domain)
        callback()
        return
      end
      callback(nil, results)
    end)
  end
  async.map(domains, iter, function(err, results)
    local i, v, serverPort
    for i, v in pairs(results) do
      serverPort = results[i][1].name .. ':' .. results[i][1].port
      endpoints = endpoints .. serverPort
      logging.log(logging.INFO, 'found endpoint: ' .. serverPort)
      if i ~= #results then
        endpoints = endpoints .. ','
      end
    end
    callback(nil, endpoints)
  end)
end

function MonitoringAgent:_getSystemId()
  local s = sigar:new()
  local netifs = s:netifs()
  for i=1, #netifs do
    local eth = netifs[i]:info()
    if eth.address ~= '127.0.0.1' then
      return UUID:new(eth.hwaddr):toString()
    end
  end
  return nil
end

function MonitoringAgent:_calculatePersistentFilename(variable)
  return path.join(constants.DEFAULT_PERSISTENT_VARIABLE_PATH, variable .. '.txt')
end

function MonitoringAgent:_savePersistentVariable(variable, data, callback)
  local filename = self:_calculatePersistentFilename(variable)
  fsutil.mkdirp(constants.DEFAULT_PERSISTENT_VARIABLE_PATH, "0644", function(err)
    if err and err.code ~= 'EEXIST' then
      callback(err)
      return
    end
    fs.writeFile(filename, data, callback)
  end)
end

function MonitoringAgent:_getPersistentVariable(variable, callback)
  local filename = self:_calculatePersistentFilename(variable)
  fs.readFile(filename, callback)
end

function MonitoringAgent:_verifyState(callback)
  function exit()
    process.exit(1)
  end

  if self._config == nil then
    logging.log(logging.ERR, "config missing or invalid")
    process.exit(1)
  end

  if self._config['monitoring_token'] == nil then
    logging.log(logging.ERR, "'monitoring_token' is missing from 'config'")
    process.exit(1)
  end

  async.waterfall({
    -- retrieve persistent variables
    function(callback)
      self:_getPersistentVariable('monitoring_id', function(err, monitoring_id)
        if err then
          monitoring_id = self:_getSystemId()
          if not monitoring_id then
            logging.log(logging.ERR, "could not retrieve system id... exiting")
            timer.setTimeout(5000, exit)
            return
          end
          self._config['monitoring_id'] = monitoring_id
          self:_savePersistentVariable('monitoring_id', monitoring_id, callback)
        else
          self._config['monitoring_id'] = monitoring_id
          callback()
        end
      end)
    end,
    -- log
    function(callback)
      logging.log(logging.INFO, 'Using id ' .. self._config['monitoring_id'])
      callback()
    end
  }, callback)
end

function MonitoringAgent:_loadEndpoints(callback)
  local endpoints
  local query_endpoints

  if not self._config['monitoring_query_endpoints'] then
    self._config['monitoring_query_endpoints'] = table.concat(constants.DEFAULT_MONITORING_SRV_QUERIES, ',')
  end

  if self._config['monitoring_query_endpoints'] and
     self._config['monitoring_endpoints'] == nil then
    -- Verify that the endpoint addresses are specified in the correct format
    query_endpoints = misc.split(self._config['monitoring_query_endpoints'], '[^,]+')
    logging.log(logging.INFO, "querying for endpoints")
    self:_queryForEndpoints(query_endpoints, function(err, endpoints)
      if err then
        callback(err)
        return
      end
      self._config['monitoring_endpoints'] = endpoints
      callback()
    end)
  else
    -- Verify that the endpoint addresses are specified in the correct format
    endpoints = misc.split(self._config['monitoring_endpoints'], '[^,]+')
    if #endpoints == 0 then
      logging.log(logging.ERR, "at least one endpoint needs to be specified")
      process.exit(1)
    end
    for i, address in ipairs(endpoints) do
      if misc.splitAddress(address) == nil then
        logging.log(logging.ERR, "endpoint needs to be specified in the following format ip:port")
        process.exit(1)
      end
    end
    logging.log(logging.INFO, "using id " .. self._config['monitoring_id'])
    callback()
  end
end

function MonitoringAgent:loadStates(callback)
  async.series({
    -- Load the States
    function(callback)
      self._states:load(callback)
    end,
    -- Verify
    function(callback)
      self:_verifyState(callback)
    end,
    function(callback)
      self:_loadEndpoints(callback)
    end    
  }, callback)
end

function MonitoringAgent:connect(callback)
  local endpoints = misc.split(self._config['monitoring_endpoints'], '[^,]+')
  if #endpoints <= 0 then
    logging.log(logging.ERR, 'no endpoints')
    timer.setTimeout(misc.calcJitter(constants.SRV_RECORD_FAILURE_DELAY, constants.SRV_RECORD_FAILURE_DELAY_JITTER), function()
      process.exit(1)
    end)
    return
  end
  self._streams = ConnectionStream:new(self._config['monitoring_id'], self._config['monitoring_token'])
  self._streams:on('error', function(err)
    logging.log(logging.ERR, JSON.stringify(err))
  end)
  self._streams:createConnections(endpoints, callback)
end

function MonitoringAgent:initialize(stateDirectory, configFile)
  if not stateDirectory then stateDirectory = virgo.default_state_unix_directory end
  logging.log(logging.INFO, 'Using state directory ' .. stateDirectory)
  self._states = States:new(stateDirectory)
  self._config = virgo.config
end

function MonitoringAgent.run(options)
  if not options then options = {} end
  local agent = MonitoringAgent:new(options.stateDirectory, options.configFile)
  async.series({
    function(callback)
      agent:loadStates(callback)
    end,
    function(callback)
      agent:connect(callback)
    end
  },
  function(err)
    if err then
      logging.log(logging.ERR, err.message)
    end
  end)
end

return MonitoringAgent
