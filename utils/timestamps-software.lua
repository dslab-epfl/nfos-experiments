--- Software timestamping precision test.
--- (Used for an evaluation for a paper)
local mg     = require "moongen"
local ts     = require "timestamping"
local device = require "device"
local hist   = require "histogram"
local memory = require "memory"
local stats  = require "stats"
local timer  = require "timer"
local ffi    = require "ffi"

local PKT_SIZE = 60

local NUM_PKTS = 10^6

function master(txPort, rxPort, load)
	if not txPort or not rxPort or type(load) ~= "number" then
		errorf("usage: txPort rxPort load")
	end
	local txDev = device.config{port = txPort, rxQueues = 2, txQueues = 2}
	local rxDev = device.config{port = rxPort, rxQueues = 2, txQueues = 2}
	device.waitForLinks()
	-- Not working with mlx5
	-- txDev:getTxQueue(0):setRate(load)
	if load > 0 then
		mg.startTask("loadSlave", txDev:getTxQueue(0))
	end
	mg.startTask("txTimestamper", txDev:getTxQueue(1))
	mg.startTask("rxTimestamper", rxDev:getRxQueue(1))
	mg.waitForTasks()
end

function loadSlave(queue)
	local mem = memory.createMemPool(function(buf)
        buf:getUdpPacket():fill{
          -- Don't use broadcast MAC addr here since some NICs could
          -- block it by default even when set as promiscous...
          ethSrc = "FE:FF:FF:FF:FF:FF",
          ethDst = "00:00:00:00:00:00",
          ip4Src = "10.0.0.0",
          ip4Dst = "10.0.0.0",
          udpSrc = 10,
          udpDst = 10,
          pktLength = PKT_SIZE
        }
	end)
	local bufs = mem:bufArray()
	local ctr = stats:newDevTxCounter("Load Traffic", queue.dev, "plain")
	while mg.running() do
		bufs:alloc(PKT_SIZE)
		queue:send(bufs)
		ctr:update()
	end
	ctr:finalize()
end

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
	-- magic number
    ip4Dst = "118.0.0.1",
    udpSrc = 0,
	-- magic number
    udpDst = 0,
    pktLength = packetSize
  }
end

function packetConfig(pkt, counter)
    pkt.ip4:setSrc(counter)
end

function txTimestamper(queue)
  	local mem = memory.createMemPool(function(buf) packetInit(buf, PKT_SIZE) end)
	mg.sleepMillis(1000) -- ensure that the load task is running
	local bufs = mem:bufArray(1)
	local rateLimit = timer:new(0.001) -- 1kpps timestamped packets
	local i = 0
	while i < NUM_PKTS and mg.running() do
		bufs:alloc(PKT_SIZE)
		for _, buf in ipairs(bufs) do
            packetConfig(buf:getUdpPacket(), i)
		    i = i + 1
        end
        bufs:offloadIPChecksums()

		queue:sendWithTimestamp(bufs)
		rateLimit:wait()
		rateLimit:reset()
	end
	mg.sleepMillis(500)
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
	local f = io.open("pings.txt", "w+")
	for i, v in ipairs(results) do
		f:write(v .. "\n")
	end
	f:close()
end

