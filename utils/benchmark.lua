--[[                             !!! BEWARE !!!

This benchmark saturates a 10G link, i.e. can send ~14.8 millions of packets per second.
This leaves VERY little budget for anything besides sending packets.
If you make ANY changes, try sending packets at 10G and make sure the right amount of packets is sent!
]]--

local ffi     = require "ffi"
local device  = require "device"
local hist    = require "histogram"
local memory  = require "memory"
local mg      = require "moongen"
local stats   = require "stats"
local timer   = require "timer"
local ts      = require "timestamping"
local limiter = require "software-ratecontrol"
local libmoon = require "libmoon"
local pcap    = require "pcap"
local log     = require "log"

-- Default batch size
local BATCH_SIZE = 64 -- packets
local RATE_MIN   = 0 -- Mbps
local RATE_MAX

local HEATUP_DURATION = 5 -- seconds
local HEATUP_RATE     = 80 -- Mbps

local LATENCY_LOAD_RATE = 1000 -- Mbps
local N_PROBE_FLOWS     = 1000

local RESULTS_FILE_NAME = 'results.tsv'

local NIC_TYPE = 'Intel'

local HEARTBEAT_INTERVAL = 1000 -- usecs


-- Arguments for the script
function configure(parser)
  parser:description("Generates UDP traffic and measures throughput.")
  parser:argument("type", "'latency' or 'throughput'.")
  parser:argument("layer", "Layer at which the flows are meaningful."):convert(tonumber)
  parser:argument("txDev", "Device to transmit from."):convert(tonumber)
  parser:argument("rxDev", "Device to receive from."):convert(tonumber)
  parser:argument("numThr", "Number of threads to use."):convert(tonumber)
  parser:argument("flowSize", "Size of flows in both directions"):convert(tonumber)
  parser:argument("isHeatUp", "heat up or real benchmark (workaround for yet another MoonGen bug...)"):convert(tonumber)
  parser:option("-p --packetsize", "Packet size."):convert(tonumber)
  parser:option("-d --duration", "Step duration."):convert(tonumber)
  parser:option("-x --reversePcap", "Send real traces from both ports.")
  parser:option("-r --rate", "Max rate."):convert(tonumber)
  parser:option("-n --nictype", "NIC type.")
  -- Arguments for LB exp
  parser:option("-s --speed", "average skew build up speed, unit: 10^10 pkts / sec^2."):convert(tonumber)
  parser:option("-w --extraload", "extra offered load on the core when skew finishes building up, unit: mpps."):convert(tonumber)
  parser:option("-f --freq", "frequency of skew events, unit: #skew events / sec."):convert(tonumber)
  -- Arguments for maglev
  parser:option("-b --backends", "backend devices. Format: <backend1,backend2,...>")
  parser:option("-i --heartbeat-interval", "Interval for sending heartbeats"):default(1000):convert(tonumber):target("heartbeatInterval")
  -- Arguments for replaying traces
	parser:option("-c --file", "Files to replay. Format: <file1,file2,...>")
	parser:option("-l --rate-multiplier", "Speed up or slow down replay, 1 = use intervals from file, default = replay as fast as possible"):default(0):convert(tonumber):target("rateMultiplier")
  -- NF-specific load
  parser:option("-t --loadtype", "NF-specific load type")
end

-- Per-layer functions to configure a packet given a counter;
-- this assumes the total number of flows is <= 65536
-- Layer "one" is for NAT, which touches the real-world layer 3,4
-- Layer 2 is dedicated to Bridge... Better way is to separate the IP config
-- from MAC config.
-- FIXME: All layers except for layer 2 requires a "unused" argument
-- to have the same interface as layer 2
local packetConfigs = {
  -- LAN->WAN flows
  [0] = {
    [2] = function(pkt, counter1, counter2)
      pkt.eth.src:set(0xFE0000000000 + counter1 * 256)
      pkt.eth.dst:set(0xFF0000000000 + counter2 * 256)
      pkt.ip4.src:set(counter1 + 1073741824)
      pkt.ip4.dst:set(counter2)
    end,
    [3] = function(pkt, counter, unused)
      pkt.ip4.dst:set(counter)
    end,
    [4] = function(pkt, counter, unused)
      -- Use moongen's internal function to get endianess right!
      pkt.udp:setDstPort(counter)
    end,
    [1] = function(pkt, counter, unused)
      pkt.ip4.dst:set(counter)
    end
  },
  -- WAN->LAN flows
  [1] = {
    [2] = function(pkt, counter1, counter2)
      pkt.eth.src:set(0xFF0000000000 + counter2 * 256)
      pkt.eth.dst:set(0xFE0000000000 + counter1 * 256)
      pkt.ip4.src:set(counter2)
      pkt.ip4.dst:set(counter1 + 1073741824)
    end,
    [3] = function(pkt, counter, unused)
      pkt.ip4.src:set(counter)
    end,
    [4] = function(pkt, counter, unused)
      -- Use moongen's internal function to get endianess right!
      pkt.udp:setSrcPort(counter)
    end,
    [1] = function(pkt, counter, unused)
      pkt.ip4.src:set(counter)
      -- Try to minimize spoofing in NAT
      pkt.udp.dst = counter
    end
  }
}

-- Fills a packet with default values
-- Set the src to the max, so that dst can easily be set to
-- the counter if needed without overlap
function packetInit(buf, packetSize)
  buf:getUdpPacket():fill{
    -- Don't use broadcast MAC addr here since some NICs could
    -- block it by default even when set as promiscous...
    ethSrc = "FE:FF:FF:FF:FF:FF",
    ethDst = "00:00:00:00:00:00",
    ip4Src = "0.0.0.0",
    ip4Dst = "0.0.0.0",
    udpSrc = 0,
-- TODO: Do we need this?
    udpDst = 80,
    pktLength = packetSize
  }
end

-- Packet utils for latency measurement
function packetInitLatency(buf, packetSize)
  buf:getUdpPacket():fill{
    -- Don't use broadcast MAC addr here since some NICs could
    -- block it by default even when set as promiscous...
    ethSrc = "FE:FF:FF:FF:FF:FF",
    ethDst = "00:00:00:00:00:00",
    ip4Src = "0.0.0.0",
	-- magic number
    ip4Dst = "118.0.0.1",
    udpSrc = 0,
	-- magic number
    udpDst = 0,
    pktLength = packetSize
  }
end

local packetConfigsLatency = {
    [2] = function(pkt, counter)
      pkt.eth.src:set(0xFD0000000000 + counter * 256)
      pkt.eth.dst:set(0xFF0000000000)
      pkt.ip4:setSrc(counter)
    end,
    [3] = function(pkt, counter)
      pkt.ip4:setSrc(counter)
    end
}


-- Get the rate that should be given to MoonGen
-- using packets of the given size to achieve the given true rate
function moongenRate(packetSize, rate)
  -- The rate the user wants is in total Mbits/s
  -- But MoonGen will send it as if the packet size
  -- was packetsize+4 (the 4 is for the hardware-offloaded MAC CRC)
  -- when in fact there are 20 bytes of framing on top of that
  -- (preamble, start delimiter, interpacket gap)
  -- Thus we must find the "moongen rate"
  -- at which MoonGen will transmit at the true rate the user wants
  -- Easiest way to do that is to convert in packets-per-second
  -- Beware, we count packets in bytes and rate in bits so we need to convert!
  -- Also, MoonGen internally calls DPDK in which the rate is an uint16_t,
  -- let's avoid floats...
  -- Furthermore, it seems from tests that rates less than 10 are just ignored...
  --
  -- When we talk about packet rate or bit rates, G = 1000 * 1000 * 1000
  local byteRate = rate * 1000 * 1000 / 8
  local packetsPerSec = byteRate / (packetSize + 24)
  local moongenByteRate = packetsPerSec * (packetSize + 4)
  local moongenRate = moongenByteRate * 8 / (1000 * 1000)
  return math.floor(moongenRate)
end

function getInterArrCycle(packetSize, batchSize, rate)
  local packetRate = rate / (packetSize + 24) / 8
  local interArrTime = 1 / packetRate * 1000
  local interArrCycle = batchSize * interArrTime * (libmoon.getCyclesFrequency() / 1000000000)
  return interArrCycle
end

function rateToBatchSize(hwRateLimitingSupport, rate)
  local batchSize

  if hwRateLimitingSupport == true then
    batchSize = BATCH_SIZE
  else
    -- HACKY, don't remove before understanding.
    -- Use lower batch size whenever possible.
    -- This effectively reduces burst size.
    -- Only works if using Mellanox cx-5 100G NIC.
    -- Hardware & System-dependent code.
    if rate <= 3000 then
      batchSize = 1
    elseif rate <= 4000 then
      batchSize = 2
    elseif rate <= 5000 then
      batchSize = 4
    elseif rate <= 7000 then
      batchSize = 8
    else
      batchSize = 16
    end
  end

  batchSize = 16

  return batchSize
end

-- Helper function, has to be global because it's started as a task
function _excessiveLoadTask(txQueue, txQueueRev,
                            layer, packetSize, flowCount, duration,
                            hwRateLimitingSupport,
                            extraLoad, speed, freq)

  -- Traffic rate (Mbps) generated by the excessive load task
  local extraRate = extraload * (packetSize + 24) * 8
  local batchSize = rateToBatchSize(hwRateLimitingSupport, extraRate / 2)

  if hwRateLimitingSupport == true then
    txQueue:setRate(moongenRate(packetSize, extraRate / 2))
    txQueueRev:setRate(moongenRate(packetSize, extraRate / 2))
  else
    io.write("WARNING: No support to hw rate limiting, not sending skewed load\n")
    return
  end
  

  local mempool = {}
  local bufs
  local bufsRev
  local packetConfig
  local packetConfigRev
  for i = 0, 1 do
    mempool[i] = memory.createMemPool(function(buf) packetInit(buf, packetSize) end)
  end

  bufs = mempool[0]:bufArray(batchSize)
  bufsRev = mempool[1]:bufArray(batchSize)
  packetConfig = packetConfigs[0][layer]
  packetConfigRev = packetConfigs[1][layer]

  local sendTimer = timer:new(duration)

  local tick = 0
  local counter = 0
  local udpPort

  -- skew build up time in number of pkts
  local skewBuildupTime = math.floor(100 * extraLoad * extraLoad / speed)
  local skewEventLength = math.floor(1000 * 1000 * extraLoad / freq)
  local startSkew = math.floor(1000 * 1000 * extraLoad)
  local endSkew = math.floor(1000 * 1000 * extraLoad * (duration - 1))

  -- STEP ONE
  -- send packets without skew for 1 sec
  while sendTimer:running() and mg.running() and (tick < startSkew) do
    bufs:alloc(packetSize)
    bufsRev:alloc(packetSize)

    for k = 1, batchSize do
      udpPort = counter % flowCount
      packetConfig(bufs[k]:getUdpPacket(), udpPort)
      packetConfigRev(bufsRev[k]:getUdpPacket(), udpPort)
      counter = counter + 1
      tick = tick + 2
    end

    bufs:offloadIPChecksums() -- UDP checksum is optional,
    bufsRev:offloadIPChecksums() -- UDP checksum is optional,
    -- let's do the least possible amount of work
    txQueue:send(bufs)
    txQueueRev:send(bufsRev)
  end

  -- STEP TWO
  -- start first skew event
  startSkew = tick

  local overloadedUdpPort = {}
  overloadedUdpPort[0] = math.random(flowCount)
  overloadedUdpPort[1] = math.random(flowCount)
  local overloadedUdpPortInd = 0

  local batchCnt = 0
  bufs:alloc(packetSize)
  bufsRev:alloc(packetSize)
  while sendTimer:running() and mg.running() and (tick < skewEventLength + startSkew) do
    -- get udp port for current packet
    local val = math.random(skewBuildupTime)
    if tick > (startSkew + skewBuildupTime) then
      udpPort = overloadedUdpPort[overloadedUdpPortInd]
      overloadedUdpPortInd = 1 - overloadedUdpPortInd
    else 
      if (val > (tick - startSkew)) then
        udpPort = counter % flowCount
        counter = counter + 1
      else
        udpPort = overloadedUdpPort[overloadedUdpPortInd]
        overloadedUdpPortInd = 1 - overloadedUdpPortInd
      end
    end

    batchCnt = batchCnt + 1
    packetConfig(bufs[batchCnt]:getUdpPacket(), udpPort)
    packetConfigRev(bufsRev[batchCnt]:getUdpPacket(), udpPort)

    -- send when batch is full
    if (batchCnt >= batchSize) then
      bufs:offloadIPChecksums() -- UDP checksum is optional,
      bufsRev:offloadIPChecksums() -- UDP checksum is optional,

      -- let's do the least possible amount of work
      txQueue:send(bufs)
      txQueueRev:send(bufsRev)

      bufs:alloc(packetSize)
      bufsRev:alloc(packetSize)

      batchCnt = 0
    end

    -- increment time tick
    tick = tick + 2
  end

  -- STEP THREE
  -- start more skew events
  local prevOverloadedUdpPort
  local prevOverloadedUdpPortInd

  while sendTimer:running() and mg.running() do
    -- launch another skew event
    if (tick >= (startSkew + skewEventLength)) then
      startSkew = tick
      prevOverloadedUdpPort = overloadedUdpPort
      prevOverloadedUdpPortInd = overloadedUdpPortInd
      overloadedUdpPort[0] = math.random(flowCount)
      overloadedUdpPort[1] = math.random(flowCount)
      overloadedUdpPortInd = 0
    end

    -- get udp port for current packet
    local val = math.random(skewBuildupTime)
    if tick > (startSkew + skewBuildupTime) then
      udpPort = overloadedUdpPort[overloadedUdpPortInd]
      overloadedUdpPortInd = 1 - overloadedUdpPortInd
    else 
      if (val > (tick - startSkew)) then
        udpPort = prevOverloadedUdpPort[prevOverloadedUdpPortInd]
        prevOverloadedUdpPortInd = 1 - prevOverloadedUdpPortInd
      else
        udpPort = overloadedUdpPort[overloadedUdpPortInd]
        overloadedUdpPortInd = 1 - overloadedUdpPortInd
      end
    end

    batchCnt = batchCnt + 1
    packetConfig(bufs[batchCnt]:getUdpPacket(), udpPort)
    packetConfigRev(bufsRev[batchCnt]:getUdpPacket(), udpPort)

    -- send when batch is full
    if (batchCnt >= batchSize) then
      bufs:offloadIPChecksums() -- UDP checksum is optional,
      bufsRev:offloadIPChecksums() -- UDP checksum is optional,

      -- let's do the least possible amount of work
      txQueue:send(bufs)
      txQueueRev:send(bufsRev)

      bufs:alloc(packetSize)
      bufsRev:alloc(packetSize)

      batchCnt = 0
    end

    -- increment time tick
    tick = tick + 2

  end

end

-- Helper function, has to be global because it's started as a task
-- Transmit packets from a pair of device
function _throughputTask(txQueue, txQueueRev, layer, packetSize, flowSize, duration,
                         hwRateLimitingSupport, rate)
  -- Convert to per-queue rate
  rate = rate / 2

  local curr
  local interArrCycle
  local lastSendCycle
  local batchSize = rateToBatchSize(hwRateLimitingSupport, rate)

  local mempool = {}
  local bufs
  local bufsRev
  local packetConfig
  local packetConfigRev
  for i = 0, 1 do
    mempool[i] = memory.createMemPool(function(buf) packetInit(buf, packetSize) end)
  end

  bufs = mempool[0]:bufArray(batchSize)
  bufsRev = mempool[1]:bufArray(batchSize)
  packetConfig = packetConfigs[0][layer]
  packetConfigRev = packetConfigs[1][layer]

  if hwRateLimitingSupport == true then
    txQueue:setRate(moongenRate(packetSize, rate))
    txQueueRev:setRate(moongenRate(packetSize, rate))
  else
    -- Effectively 2x batchSize and 2x rate
    interArrCycle = getInterArrCycle(packetSize, 2 * batchSize, 2 * rate)
    lastSendCycle = libmoon.getCycles()
  end
  local sendTimer = timer:new(duration)

  local counter = 0
  local startFlow = 0
  local endFlow = flowSize
  local counter1, counter2

  while sendTimer:running() and mg.running() do
    bufs:alloc(packetSize)
    bufsRev:alloc(packetSize)

    for k = 1, batchSize do
      -- have 200 macs on one side
      counter2 = counter % 200
      counter1 = (counter - counter2) / 200
      packetConfig(bufs[k]:getUdpPacket(), counter1, counter2)
      packetConfigRev(bufsRev[k]:getUdpPacket(), counter1, counter2)
      
      counter = counter + 1 
      if (counter >= endFlow) then
        startFlow = startFlow + 1 
        endFlow = endFlow + 1 
        counter = startFlow
      end
    end

    bufs:offloadIPChecksums() -- UDP checksum is optional,
    bufsRev:offloadIPChecksums() -- UDP checksum is optional,

    -- let's do the least possible amount of work
    txQueue:send(bufs)
    txQueueRev:send(bufsRev)

    if hwRateLimitingSupport == false then
      curr = libmoon.getCycles()
      while (curr - lastSendCycle) < interArrCycle do
        curr = libmoon.getCycles()
      end
      -- this ensures that moongen sends a batch of packets every interArrCycle
      lastSendCycle = lastSendCycle + interArrCycle
    end
  end

end


-- Helper function, has to be global because it's started as a task
-- Transmit packets from a pair of device
function _throughputTask_antiddos(txQueue, packetSize, duration,
                         hwRateLimitingSupport, rate, txQueueId)
  local curr
  local interArrCycle
  local lastSendCycle
  local batchSize = rateToBatchSize(hwRateLimitingSupport, rate)

  local mempool = {}
  local bufs
  local packetConfig = function(pkt, ipCnt, udpCnt)
      pkt.ip4.src:set(ipCnt + 1073741824)
      pkt.udp:setSrcPort(udpCnt)
    end

  mempool[0] = memory.createMemPool(function(buf) packetInit(buf, packetSize) end)

  bufs = mempool[0]:bufArray(batchSize)

  if hwRateLimitingSupport == true then
    txQueue:setRate(moongenRate(packetSize, rate))
  else
    interArrCycle = getInterArrCycle(packetSize, batchSize, rate)
    lastSendCycle = libmoon.getCycles()
  end
  local sendTimer = timer:new(duration)

  -- send different port range from each core
  -- assuming less than 32 cores used to send packets
  local startPort = 2048 * txQueueId
  -- Simulate ddos attack traffic with 80% onePktFlow
  local newFlowDist = 5
  local newNormalFlowDist = newFlowDist * 5

  local flowCnt = 0
  local pktCnt = 0
  local ipCnt, udpCnt
  local normalFlowIpCnt, normalFlowUdpCnt

  --debug
  -- local num_dumped = 0

  while sendTimer:running() and mg.running() do
    bufs:alloc(packetSize)

    for k = 1, batchSize do
      -- New flow every 5 packets
      if pktCnt % newFlowDist == 0 then
        ipCnt = flowCnt / 2048
        udpCnt = (flowCnt % 2048) + startPort
        -- New normal flow every 25 packets
        if pktCnt % newNormalFlowDist == 0 then
          normalFlowIpCnt = ipCnt
          normalFlowUdpCnt = udpCnt
        end
        flowCnt = flowCnt + 1
      else
        ipCnt = normalFlowIpCnt
        udpCnt = normalFlowUdpCnt
      end

      packetConfig(bufs[k]:getUdpPacket(), ipCnt, udpCnt)
      -- debug
      -- if num_dumped < 25 then
      --   bufs[k]:dump()
      --   num_dumped = num_dumped + 1
      -- end
      pktCnt = pktCnt + 1
    end

    bufs:offloadIPChecksums() -- UDP checksum is optional,

    -- let's do the least possible amount of work
    txQueue:send(bufs)

    if hwRateLimitingSupport == false then
      curr = libmoon.getCycles()
      while (curr - lastSendCycle) < interArrCycle do
        curr = libmoon.getCycles()
      end
      -- this ensures that moongen sends a batch of packets every interArrCycle
      lastSendCycle = lastSendCycle + interArrCycle
    end
  end

end



-- Helper function, has to be global because it's started as a task
-- Generate 1-packet LAN->WAN short flows that trigger expiration
function _shortFlowTask(txQueue, layer, packetSize, shortFlowCount,
                             longFlowCount, duration, direction)
  local mempool = memory.createMemPool(function(buf) packetInit(buf, packetSize) end)
  local bufs = mempool:bufArray(1)
  local packetConfig = packetConfigs[direction][layer]
  local sendTimer = timer:new(duration)
  local counter = 0

  local rateLimiter = timer:new(2 / shortFlowCount) -- ASSUMPTION: < 2 sec expiration time

  while sendTimer:running() and mg.running() do
    bufs:alloc(packetSize)
    for _, buf in ipairs(bufs) do
      packetConfig(buf:getUdpPacket(), counter + longFlowCount)
      -- incAndWrap does this in a supposedly fast way;
      -- in practice it's actually slower!
      -- with incAndWrap this code cannot do 10G line rate
      counter = (counter + 1) % shortFlowCount
    end

    bufs:offloadIPChecksums() -- UDP checksum is optional,

    rateLimiter:wait()
    rateLimiter:reset()
    -- let's do the least possible amount of work
    txQueue:send(bufs)
  end

end

-- Helper function, has to be global because it's started as a task
-- Replay traces
function _pcapTask(queue, file, multiplier, duration)
	local mempool = memory:createMemPool(4096)
	local bufs = mempool:bufArray(16)
	local pcapFile = pcap:newReader(file)
	local prev = 0
  local sendTimer = timer:new(duration)
  local loop = true

  local tscFreqNs = (libmoon.getCyclesFrequency() / 1000000000) 
  local lastSendCycle = libmoon.getCycles()
  local curr

	while sendTimer:running() and mg.running() do
		local n = pcapFile:read(bufs)
		if n > 0 then
			if prev == 0 then
				prev = bufs.array[0].udata64
			end
			local buf = bufs[n]
			-- ts is in microseconds
			local ts = buf.udata64
			if prev > ts then
				ts = prev
			end
			local delay = ts - prev
			delay = tonumber(delay * 10^3) / multiplier -- nanoseconds
      delay = delay * tscFreqNs
			prev = ts

			queue:sendN(bufs, n)

      curr = libmoon.getCycles()
      while (curr - lastSendCycle) < delay do
        curr = libmoon.getCycles()
      end
      lastSendCycle = lastSendCycle + delay

		else

			if loop then
				pcapFile:reset()
        prev = 0
			else
				break
			end

		end
	end
  -- allows us to terminate all the tasks that polls mg.running() and end the script
  -- Update: not needed anymore since we don't use moongen's software rateLimiter
  -- mg.stop()
	-- mg.sleepMillisIdle(10 * 1000)
end



-- Helper function, has to be global because it's started as a task
-- Generates heartbeats
function _heartbeatTask(backendDevs, heartbeatInterval, duration)
  local packetSize = 60
  local mempool = {}
  local bufs = {}
  local txQueues = {}
  for i = 0, table.getn(backendDevs) do
    mempool[i] = memory.createMemPool(function(buf) packetInit(buf, packetSize) end)
    bufs[i] = mempool[i]:bufArray(1)
    txQueues[i] = backendDevs[i]:getTxQueue(0)
  end


  local sendTimer = timer:new(duration)
  local rateLimiter = timer:new(heartbeatInterval / 1000000) -- one heartbeat from each backend

  while sendTimer:running() and mg.running() do
    for k = 0, table.getn(backendDevs) do
      bufs[k]:alloc(packetSize)
      for _, buf in ipairs(bufs[k]) do
        pkt = buf:getUdpPacket()
        pkt.eth.src:set(0xFE0000000000 + k)
        pkt.ip4.src:set(256 + k)
        -- debug
        -- buf:dump()
      end
      bufs[k]:offloadIPChecksums() -- UDP checksum is optional,
    end

    -- let's do the least possible amount of work
    for k = 0, table.getn(backendDevs) do
      txQueues[k]:send(bufs[k])
    end

    rateLimiter:wait()
    rateLimiter:reset()
  end
end

-- Helper function, has to be global because it's started as a task
-- Generate 4 flows for heating up purpose
function _heatupTask(txQueue, rxQueue, layer, packetSize, duration,
                     direction, hwRateLimitingSupport, rate)
  local flowCount = 4

  local curr
  local interArrCycle
  local lastSendCycle
  local batchSize = rateToBatchSize(hwRateLimitingSupport, rate)

  local mempool = memory.createMemPool(function(buf) packetInit(buf, packetSize) end)
  local bufs = mempool:bufArray(batchSize)
  local packetConfig = packetConfigs[direction][layer]
  local sendTimer = timer:new(duration)

  if hwRateLimitingSupport == true then
    txQueue:setRate(moongenRate(packetSize, rate))
  else
    interArrCycle = getInterArrCycle(packetSize, batchSize, rate)
    lastSendCycle = libmoon.getCycles()
  end
  local counter = 0

  while sendTimer:running() and mg.running() do
    bufs:alloc(packetSize)
    for _, buf in ipairs(bufs) do
      packetConfig(buf:getUdpPacket(), counter, 0)
      -- incAndWrap does this in a supposedly fast way;
      -- in practice it's actually slower!
      -- with incAndWrap this code cannot do 10G line rate
      counter = (counter + 1) % flowCount
    end

    bufs:offloadIPChecksums() -- UDP checksum is optional,
    -- let's do the least possible amount of work
    txQueue:send(bufs)

    if hwRateLimitingSupport == false then
      curr = libmoon.getCycles()
      while (curr - lastSendCycle) < interArrCycle do
        curr = libmoon.getCycles()
      end
      -- this ensures that moongen sends a batch of packets every interArrCycle
      lastSendCycle = lastSendCycle + interArrCycle
    end
  end

end


function txTimestamper(queue, duration, layer)
  local PKT_SIZE = 60
  local flowCount = 100

  local mem = memory.createMemPool(function(buf) packetInitLatency(buf, PKT_SIZE) end)
	local bufs = mem:bufArray(1)
	local rateLimit = timer:new(0.0002) -- 5kpps timestamped packets
  local sendTimer = timer:new(duration)
  local counter = 0
  local packetConfigLatency = packetConfigsLatency[layer]

	while sendTimer:running() and mg.running() do
		bufs:alloc(PKT_SIZE)
		for _, buf in ipairs(bufs) do
      packetConfigLatency(buf:getUdpPacket(), counter)
      counter = (counter + 1) % flowCount
    end

    bufs:offloadIPChecksums()
		queue:sendWithTimestamp(bufs)
		rateLimit:wait()
		rateLimit:reset()
	end
  mg.stop()
end


function rxTimestamper(queue)
	local tscFreq = mg.getCyclesFrequency()
	local bufs = memory.bufArray(1)
	local results = {}
	local rxts = {}
	while mg.running() do
		local numPkts = queue:recvWithTimestamps(bufs)
		for i = 1, numPkts do
			local rxTs = bufs[i].udata64
			local txTs = bufs[i]:getSoftwareTxTimestamp()
			results[#results + 1] = tonumber(rxTs - txTs) / tscFreq * 10^9 -- to nanoseconds
			rxts[#rxts + 1] = tonumber(rxTs)
		end
		bufs:free(numPkts)
	end
	local f = io.open("latency-profile", "w+")
	for i, v in ipairs(results) do
		f:write(v .. "\n")
	end
	f:close()
end


-- Starts a throughput-measuring task,
-- measuring throughput of the entire tx/rx NICs
-- which returns (#tx, #rx) packets (where rx == tx iff no loss)
function startMeasureThroughput(txQueue, rxQueue, txQueueRev, rxQueueRev, rate, layer,
                                packetSize, flowSize, duration,
                                speed, extraload, freq, reversePcap, shortFlowCount, backendDevs,
                                pcapFiles, rateMultiplier, txQueueLatency, rxQueueLatency,
                                doHeatUp, loadtype)
  -- 1. Stats
  -- global tx, rx counter
  -- data retrived directly from NIC statistic registers
  local txCounter = stats:newDevTxCounter(txQueue[0], "plain")
  local rxCounter = stats:newDevRxCounter(rxQueue[0], "plain")
  local txCounterRev = stats:newDevTxCounter(txQueueRev[0], "plain")
  local rxCounterRev = stats:newDevRxCounter(rxQueueRev[0], "plain")

  local numTxQueue = table.getn(txQueue) + 1
  local numTxQueueRev = table.getn(txQueueRev) + 1

  -- 2. Rate limiting
  -- Only Intel 82599 supports hw rate limiting
  local hwRateLimitingSupport
  if NIC_TYPE == "Intel" then
    hwRateLimitingSupport = true
  else
    hwRateLimitingSupport = false
  end

  -- 3-1. Rate distribution
  -- Traffic rate (Mbps) generated by the excessive load task
  local extraRate = extraload * (packetSize + 24) * 8
  -- Traffic rate (Mbps) generated by all the tasks excluding shortFlow & excessiveLoad tasks
  local perQueueRate = (rate - extraRate) / (numTxQueue - 2)

  -- 3-2. Flow size distribution, each core only sends a partition of a flow
  flowSize = math.floor(flowSize / (numTxQueue - 2))

  -- 4. Tasks
  if backendDevs ~= nil then
    mg.startTask("_heartbeatTask", backendDevs, HEARTBEAT_INTERVAL, duration)
    mg.sleepMillis(100)
  end

  if shortFlowCount > 0 then
    mg.startTask("_shortFlowTask", txQueue[numTxQueue-2],
                 layer, packetSize, shortFlowCount, flowCount, duration, 0)
  end

  if extraload > 0 then
    mg.startTask("_excessiveLoadTask", txQueue[numTxQueue-1],
                   txQueueRev[numTxQueueRev-1],
                   layer, packetSize, flowCount, duration,
                   hwRateLimitingSupport,
                   extraload, speed, freq)
  end

  if moongenRate(packetSize, perQueueRate) >= 10 then
    if (pcapFiles ~= nil) then
      if (reversePcap == false) then
        for i = 0, numTxQueue - 3 do
          mg.startTask("_pcapTask", txQueue[i], pcapFiles[i], rateMultiplier, duration)
        end
      else
        -- temp hack for maglev
        -- Send equal number of traces from two devices
        -- TODO: check if (numTxQueue - 3) is odd
        for i = 0, math.floor((numTxQueue - 3)/2) do
          mg.startTask("_pcapTask", txQueue[i], pcapFiles[i], rateMultiplier, duration)
        end
        for i = math.floor((numTxQueue - 3)/2) + 1, numTxQueue - 3 do
          mg.startTask("_pcapTask", txQueueRev[i], pcapFiles[i], rateMultiplier, duration)
        end
      end

    elseif (loadtype == "antiddos") then
      for i = 0, numTxQueue - 3 do
        mg.startTask("_throughputTask_antiddos", txQueue[i],
                    packetSize, duration, hwRateLimitingSupport, perQueueRate, i)
      end

    else
      if (doHeatUp == false) then
        for i = 0, numTxQueue - 3 do
          mg.startTask("_throughputTask", txQueue[i], txQueueRev[i],
                      layer, packetSize, flowSize, duration,
                      hwRateLimitingSupport, perQueueRate)
        end
      else
        for i = 0, numTxQueue - 3 do
          mg.startTask("_heatupTask", txQueue[i], rxQueue[i],
                      layer, packetSize, duration, 0,
                      hwRateLimitingSupport, perQueueRate)
        end
      end
    end
  else
    io.write("rate limiting may not work with < 10mbps rate per queue\n")
  end

  -- latency measurement
  if txQueueLatency ~= nil then
	  mg.startTask("txTimestamper", txQueueLatency, duration, layer)
	  mg.startTask("rxTimestamper", rxQueueLatency)
  end

  mg.waitForTasks()

  -- 5. Collecting stats
  txCounter:finalize()
  rxCounter:finalize()
  txCounterRev:finalize()
  rxCounterRev:finalize()

  -- masking wrong reverse stats when reverse is not set
  if reversePcap == false then
    txCounterRev.total = 0
    rxCounterRev.total = 0
  end
  return txCounter.total, rxCounter.total, txCounterRev.total, rxCounterRev.total
end


-- Heats up with packets at the given layer, with the given size and number of flows.
-- Errors if the loss is over 0.1%, and ignoreNoResponse is false.
function heatUp(txQueue, rxQueue, txQueueRev, rxQueueRev, layer, packetSize, flowSize, ignoreNoResponse,
                backendDevs)
  io.write("Heating up for " .. HEATUP_DURATION .. " seconds at " ..
             HEATUP_RATE .. " Mbps with " .. flowSize .. " flow size... ")
  -- TODO: there should be an diff generator here... otherwise heatup can only run once at the beginning of
  -- the benchmark
  local tx, rx, txRev, rxRev = startMeasureThroughput(txQueue, rxQueue, txQueueRev, rxQueueRev, HEATUP_RATE,
                                        layer, packetSize, flowSize,
                                        HEATUP_DURATION, 1, 0, 10, false, 0,
                                        backendDevs,
                                        nil, nil,
                                        nil, nil,
                                        true)
  -- Ignore  stats for reverse flows, in the case of
  -- NAT they are likely dropped by the NF

  -- Disable this check for now since moongen's counter is problematic, use sysfiles instead
  -- local loss = (tx - rx) / tx
  -- if loss > 0.001 and not ignoreNoResponse then
  --   io.write("Over 0.1% loss!\n")
  --   os.exit(1)
  -- end
  -- io.write("OK\n")

  return tx, rx, txRev, rxRev
end

-- iterator that diffs a series of values
function diffGenerator(initTx, initRx, initTxRev, initRxRev)
  local prevTx, prevRx, prevTxRev, prevRxRev = initTx, initRx, initTxRev, initRxRev
  return function (tx, rx, txRev, rxRev)
           local diffTx = tx - prevTx
           local diffRx = rx - prevRx
           local diffTxRev = txRev - prevTxRev
           local diffRxRev = rxRev - prevRxRev
           prevTx, prevRx, prevTxRev, prevRxRev = tx, rx, txRev, rxRev
           return diffTx, diffRx, diffTxRev, diffRxRev
         end
end

-- tx diff-only generator 
function txOnlyDiffGenerator(initTx, initRx, initTxRev, initRxRev)
  local prevTx, prevTxRev = initTx, initTxRev
  return function (tx, rx, txRev, rxRev)
           local diffTx, diffTxRev = tx - prevTx, txRev - prevTxRev
           prevTx, prevTxRev = tx, txRev
           return diffTx, rx, diffTxRev, rxRev
         end
end

-- Measure max throughput with less than 0.1% loss
function measureMaxThroughputWithLowLoss(txDev, rxDev, layer, packetSize,
                                         duration, reversePcap, numThr,
                                         _flowSize,
                                         speed, extraload, freq,
                                        backendDevs,
                                        pcapFiles, rateMultiplier, isHeatUp, type, loadtype)
  -- Do not change the name and format of this file
  -- unless you change the rest of the scripts that depend on it!
  local outFile = io.open(RESULTS_FILE_NAME, "w")
  outFile:write("#flows\tMbps\t#packets\t#pkts/s\tloss\n")

  local txQueue = {}
  local rxQueue = {}
  local txQueueRev = {} -- the rx/tx inversion is voluntary
  local rxQueueRev = {}
  for i = 0, numThr - 1 do
    txQueue[i] = txDev:getTxQueue(i)
    rxQueue[i] = rxDev:getRxQueue(i)
    txQueueRev[i] = rxDev:getTxQueue(i) -- the rx/tx inversion is voluntary
    rxQueueRev[i] = txDev:getRxQueue(i)
  end
  -- additional txQueue to generate LAN->WAN short flows
  -- to benchmark expiration
  txQueue[numThr] = txDev:getTxQueue(numThr) 
  rxQueue[numThr] = rxDev:getRxQueue(numThr) 

  local txQueueLatency = nil
  local rxQueueLatency = nil
  -- additional txQueue to generate timestamping packets
  if type == "latency" then
    txQueueLatency = txDev:getTxQueue(numThr + 1)
    if backendDevs ~= nil then
      rxQueueLatency = backendDevs[0]:getRxQueue(1)
    else
      rxQueueLatency = rxDev:getRxQueue(numThr + 1)
    end
  end

  -- Workaround for the counter accumulating across call to
  -- startMeasureThroughput() bug
  local counterTrueVal
  -- Mellanox ConnectX-5
  if NIC_TYPE == "Mellanox" then
    counterTrueVal = diffGenerator(0, 0, 0, 0)
  -- For Intel 82599 case
  else
    counterTrueVal = txOnlyDiffGenerator(0, 0, 0, 0)
  end

  for _, flowSize in ipairs({_flowSize}) do
    if isHeatUp == 1 then
      counterTrueVal(heatUp(txQueue, rxQueue, txQueueRev, rxQueueRev, layer, packetSize, flowSize, false, backendDevs))
      os.exit(0)
    end

    -- temp hack
    -- os.exit(0)

    local rate = RATE_MAX
    io.write("Measuring goodput with " .. flowSize .. " flow size (Offered load " .. rate .. " mbps)\n")

    local tx, rx, txRev, rxRev
    tx, rx, txRev, rxRev = counterTrueVal(startMeasureThroughput(txQueue, rxQueue, txQueueRev, rxQueueRev, rate,
                                          layer, packetSize, flowSize,
                                          duration, speed, extraload, freq, reversePcap, 0,
                                          backendDevs,
                                          pcapFiles, rateMultiplier,
                                          txQueueLatency, rxQueueLatency,
                                          false, loadtype))
    tx = tx + txRev
    rx = rx + rxRev
    local loss = (tx - rx) / tx

    -- Disable for now since moongen's counter is problematic, use sysfiles instead
    -- io.write(tx .. " sent, " .. rx .. " received, loss = " .. loss .. "\n")

  end
end

function master(args)
  -- additional txQueue to generate LAN->WAN short flows
  -- to benchmark expiration
  -- additional tx/rxQueue for measuring latency
  local txDev = device.config{port = args.txDev, rxQueues = args.numThr, txQueues = args.numThr + 2}
  local rxDev = device.config{port = args.rxDev, rxQueues = args.numThr + 2, txQueues = args.numThr}

  -- Get backends
  local backendDevs = nil
  local i = 0
  if args.backends ~= nil then
    backendDevs = {}
    for w in string.gmatch(args.backends, "%d+") do
      -- additional rxQueue for measuring latency
      backendDevs[i] = device.config{port = tonumber(w), rxQueues = 2, txQueues = 1}
      i = i + 1
    end 
  end

  -- Get pcap Files
  local pcapFiles = {}
  i = 0
  if args.file ~= nil then
    -- https://stackoverflow.com/questions/19907916/split-a-string-using-string-gmatch-in-lua
    for w in string.gmatch(args.file .. ",", "([^,]*),") do
      pcapFiles[i] = w
      i = i + 1
    end
  else
    pcapFiles = nil
  end
  
  device.waitForLinks()

  measureFunc = nil
  if args.type == 'throughput' or args.type == 'latency' then
    measureFunc = measureMaxThroughputWithLowLoss
  else
    print("Unknown type.")
    os.exit(1)
  end

  if args.nictype ~= nil then
    NIC_TYPE = args.nictype
  end

  if NIC_TYPE == "Mellanox" then
    RATE_MAX = 100000 -- Mbps
  else
    RATE_MAX = 7000 -- Mbps
  end
  if args.rate ~= nil then
    RATE_MAX = args.rate
  end

  if args.heartbeatInterval ~= nil then
    HEARTBEAT_INTERVAL = args.heartbeatInterval
  end

  -- set per queue heatup rate as 40 Mbps
  HEATUP_RATE = 40 * 2 * (args.numThr - 1)

  if args.speed == nil then
    args.speed = 1
  end

  if args.extraload == nil then
    args.extraload = 0
  end

  if args.freq == nil then
    args.freq = 10
  end

  if args.reversePcap == nil then
    args.reversePcap = false
  else
    args.reversePcap = true
  end

  if args.loadtype == nil then
    args.loadtype = "default"
  end

  measureFunc(txDev, rxDev, args.layer, args.packetsize,
              args.duration, args.reversePcap, args.numThr,
              args.flowSize,
              args.speed, args.extraload, args.freq,
              backendDevs, pcapFiles, args.rateMultiplier, args.isHeatUp,
              args.type, args.loadtype)
end
