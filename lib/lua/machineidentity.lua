--[[
Copyright 2013 Rackspace

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

local Error = require('core').Error
local Object = require('core').Object
local async = require('async')
local childprocess = require('childprocess')
local os = require('os')
local fs = require('fs')
local utils = require('virgo_utils')
local fmt = require('string').format
local http = require('http')

local MachineIdentity = Object:extend()

local function awsAdapter(callback)
  local uri = 'http://instance-data.ec2.internal/latest/meta-data/instance-id'
  local req = http.request(uri, function(res)
    local id = ''
    res:on('data', function(data)
      id = id .. data
    end)
    res:on("end", function()
      res:destroy()
      callback(nil, id)
    end)
  end)
  req:setTimeout(1000)
  req:once('timeout', callback)
  req:once('error', callback)
  req:done()
end

local function gceAdapter(callback)
  local uri = 'http://metadata.google.internal/computeMetadata/v1/instance/id'
  local req = http.request(uri, function(res)
    local id = ''
    res:on('data', function(data)
      id = id .. data
    end)
    res:on("end", function()
      res:destroy()
      callback(nil, id)
    end)
  end)
  req:setTimeout(1000)
  req:setHeader('MetaData-Flavor', 'Google')
  req:once('timeout', callback)
  req:once('error', callback)
  req:done()
end

local function xenAdapter(callback)
  local exePath
  local exeArgs

  if os.type() == 'win32' then
    exePath = 'c:\\Program Files\\Citrix\\XenTools\\xenstore_client.exe'
    exeArgs = { 'read', 'name' }
  else
    exePath = 'xenstore-read'
    exeArgs = { 'name' }
  end

  local buffer = ''
  local child = childprocess.spawn(exePath, exeArgs)

  child.stdout:on('data', function(chunk)
    buffer = buffer .. chunk
  end)

  child:on('exit', function(code)
    if code == 0 and buffer:len() > 10 then
      callback(nil, utils.trim(buffer:sub(10)))
    else
      callback(Error:new(fmt('Could not retrieve xenstore name, ret: %d, buffer: %s', code, buffer)))
    end
  end)
end

local function cloudInitAdapter(callback)
  -- TODO: Win32 cloud-init paths
  local instanceIdPath = '/var/lib/cloud/data/instance-id'
  fs.readFile(instanceIdPath, function(err, data)
    if err ~= nil then
      callback(err)
      return
    end

    data = utils.trim(data)

    -- the fallback datasource is iid-datasource-none when it does not exist
    -- http://cloudinit.readthedocs.org/en/latest/topics/datasources.html#fallback-none
    if data == 'iid-datasource-none' or data == 'nocloud' then
      callback(Error:new('Invalid instance-id'))
    else
      callback(nil, data)
    end
  end)
end

function MachineIdentity:initialize(config)
  self._config = config
end

function MachineIdentity:get(callback)
  local rv
  local instanceId

  rv = utils.tableGetBoolean(self._config, 'autodetect_machine_id', true)
  if rv == false then
    return callback()
  end

  local adapters = {
    cloudInitAdapter,
    xenAdapter,
    awsAdapter,
    gceAdapter
  }

  async.forEachSeries(adapters, function(adapter, callback)
    adapter(function(err, _instanceId)
      if err then
        return callback()
      end
      if instanceId then
        return callback()
      end
      instanceId = _instanceId
      callback()
    end)
  end, function(err)
    if err then
      return callback(err)
    end
    if instanceId == nil then
      return callback(Error:new('no instance id'))
    end
    callback(nil, { id = instanceId })
  end)
end

local exports = {}
exports.MachineIdentity = MachineIdentity
return exports
