-- c4plex Plex Music
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- A native Control4 streaming music source for a Plex Media Server: browse and
-- search the music library under Listen, pick a track, and the Control4
-- Digital Audio engine streams it straight from the server (direct play or a
-- server-side MP3 transcode). Pandora-style native service: no external player
-- hardware, the C4 controller is the renderer.
--
-- Queue model: Director's audio engine takes one URL at a time
-- (SELECT_AUDIO_URL) plus one pre-fetched next URL (SET_NEXT_AUDIO_URL) for
-- gapless advance; this driver mirrors the actual track queue and reacts to
-- the engine's QUEUE_* notifications. There is no public API that hands the
-- engine a whole track list.
--
-- Event correlation: every QUEUE_INFO this driver sends is "gen:index" where
-- gen is a queue-arrangement generation. Engine echoes carrying a stale gen
-- (from before a replace or shuffle) are rejected instead of trusted, and
-- queue ids are adopted only from an ack or a PLAY transition, never from a
-- passing notification. Ids of replaced queues are remembered and their tail
-- events dropped.

require ('c4plex.c4handlers')
require ('c4plex.c4timer')
local Debug = require ('c4plex.debug')
local Plex = require ('plex')

do -- globals
	MSP = 5001 -- media_service proxy binding

	gSections = {}      -- music sections: array of {key, title, agent}
	gSectionKey = nil   -- selected library section key
	gSectionsLoaded = false -- a sections fetch has succeeded for THIS config
	-- capability gates, detected silently (no user prompt): the modern music
	-- agent provides Top Tracks / Similar Artists; Plex Pass provides Artist
	-- Radio (deferred). Rows tied to a gate are simply omitted when it is off.
	gModernAgent = false
	gPlexPass = false
	gServerLabel = ''   -- friendlyName + version + endpoint, for the Composer Server property
	gServerName = ''    -- friendlyName only, for the Navigator "Linked to ..." status
	gConnectFault = nil -- last terminal connect failure, surfaced on the account screen
	gLinkDoneNavs = nil -- navs waiting for the "link finished" dialog once the server is found
	gConnectGen = 0     -- generation counter: stale connect callbacks drop out
	gDiscoverGen = 0    -- config generation the last server discovery ran for

	-- the queue this driver mirrors; the engine only ever holds one current
	-- and one next URL from it
	gQueue = {}         -- array of track tables (see trackFromRow)
	gUnshuffled = nil   -- pre-shuffle order backup, restored on shuffle-off
	gIndex = 0          -- 1-based position in gQueue; 0 = nothing selected
	gSelectGen = 0      -- queue-arrangement generation, rides inside QUEUE_INFO
	gQueueId = nil      -- Director queue id for the live session
	gDeadQueueIds = {}  -- ids of replaced queues whose tail events are dropped
	gReplacedQueueId = nil -- the id displaced by the in-flight SELECT
	gAwaitQueueId = false -- a SELECT was just sent; awaiting the engine's answer
	gPendingDeleteRooms = nil -- a QUEUE_DELETED seen during the await window
	gPlayState = 'STOP' -- engine state: PLAY | PAUSE | STOP
	gElapsedSec = 0     -- driver-side clockwork; the engine sends no progress
	gNextArmed = nil    -- queue index currently armed as the engine's NEXT_URL
	gEndStreak = 0      -- consecutive END-fallback selects with no adopted PLAY
	gShuffle = false
	gRepeat = false
	gRooms = ''         -- room id(s) the current session plays in (CSV)
	gLastRoom = nil     -- most recent room seen on any proxy command
	gRadio = nil        -- when set {key=stationKey,...} the queue is a radio station; refilled as it nears the end
	gDeleteGraceUntil = 0 -- id-less deletes deferred briefly after adoption
	gGraceDeleteRooms = nil -- rooms of a grace-deferred delete, until decided
	gAdoptSerial = 0    -- bumped per adoption; stamps deferred deletes stale
	gAdoptAt = 0        -- os.time of the last id adoption
	gLastPlayAt = 0     -- os.time of the last adopted PLAY transition
	gSelectSentThisSession = false -- distinguishes reload from live timeouts
	gLastStreamErrAt = 0 -- rate limit for stream-error toasts

	-- browse context: track lists keyed by container path plus page offset,
	-- so tapping a track can queue the page it came from. Bounded: oldest
	-- entries are evicted past MAX_CTX.
	gCtx = {}           -- key -> {tracks = {...}, stamp = n}
	gCtxStamp = 0
	MAX_CTX = 20

	gLast = {}          -- last payload per broadcast event, to skip repeats

	-- short-TTL browse reply cache: repeat visits to a page (tab switches,
	-- back-navigation) answer instantly instead of re-asking the server
	gBrowseCache = {}   -- key -> {data, tracks, cacheKey, stamp, at}
	gBrowseStamp = 0
	BROWSE_CACHE_MAX = 20
	BROWSE_CACHE_TTL = 60 -- seconds

	-- A-Z index buckets per section+type, backing the AlphaMap scrubber
	gAlpha = {}         -- key -> {xml, at}
	ALPHA_TTL = 600 -- seconds

	-- plex.tv account-link flow state (transient, never persisted)
	gLink = nil         -- {pending=true} while requesting, then {id, code, deadline}
	gLinkErr = nil      -- last link failure, surfaced on the Account screen
	gLastAutoLink = 0   -- rate limit for browse-triggered setup prompts
	gLinkNavs = {}      -- navigators shown the code dialog, for targeted closes

	TOKEN_MASK = '\226\128\162\226\128\162\226\128\162\226\128\162\226\128\162\226\128\162\226\128\162\226\128\162' -- eight bullet dots shown in place of the token

	QUEUE_DISPLAY_MAX = 200 -- rows of queue sent to Navigators
	QUEUE_MAX = 2000    -- total mirrored queue cap across appends
	LIST_ROWS_MAX = 500 -- browse rows rendered even if the server sends more
	CONTAINER_FETCH_MAX = 500 -- tracks fetched when playing a whole container
	SECTIONS_MAX = 64   -- cap on music sections (a hostile server can't bloat the dropdown/alpha cache)
	RADIO_REFILL_AT = 5 -- refill a radio station when this few tracks remain ahead
	DEFAULT_KBPS = 320  -- transcode bitrate when the Playback property names none
	DELETE_GRACE_S = 5  -- after adoption, an id-less delete is deferred this long
	TIMELINE_PERIOD_SEC = 10 -- Plex progress report cadence while playing
	AWAIT_QUEUE_TIMEOUT_MS = 10000 -- await window closes even with no reply
	DEAD_IDS_MAX = 8    -- remembered replaced-queue ids
	END_STREAK_MAX = 25 -- END-fallback selects tolerated with no PLAY between
	TRACK_FIELD_MAX = 256 -- per-field cap on mirrored/persisted track strings
end

-- ---- small helpers --------------------------------------------------------

-- XML-escape text placed into DATA / EVTARGS payloads; control bytes are
-- stripped because one stray byte in a tag makes the whole list unparseable.
local function esc (s)
	s = tostring (s or '')
	s = s:gsub ('[%z\1-\8\11\12\14-\31]', '')
	s = s:gsub ('&', '&amp;'):gsub ('<', '&lt;'):gsub ('>', '&gt;')
	s = s:gsub ('"', '&quot;'):gsub ("'", '&apos;')
	return s
end

local function fmtTime (sec)
	sec = math.max (0, math.floor (tonumber (sec) or 0))
	local h = math.floor (sec / 3600)
	local m = math.floor ((sec % 3600) / 60)
	local s = sec % 60
	if (h > 0) then return string.format ('%d:%02d:%02d', h, m, s) end
	return string.format ('%d:%02d', m, s)
end

-- server-supplied numerics are hostile: inf/nan/negative/absurd values are
-- rejected here so they can never reach string.format('%d') or an event attr
local function finite (v, max)
	local n = tonumber (v)
	if (not n or n ~= n or n < 0 or n > (max or 1e9)) then return nil end
	return math.floor (n)
end

-- room ids are numeric (CSV for multi-room); anything else (a location path,
-- an empty string) must never ride into SELECT_AUDIO_URL's ROOM_ID
local function validRooms (s)
	s = tostring (s or '')
	return s:match ('^%d+[%d,]*$') and s or nil
end

-- do two numeric CSVs share a room id?
local function roomsOverlap (a, b)
	local set = {}
	for id in tostring (a or ''):gmatch ('%d+') do set [id] = true end
	for id in tostring (b or ''):gmatch ('%d+') do
		if (set [id]) then return true end
	end
	return false
end

-- the Plex token must never reach a log line, even inside an engine-composed
-- error string that may echo the failing stream URL
local function scrubToken (s)
	return (tostring (s or ''):gsub ('X%-Plex%-Token=[^&%s]*', 'X-Plex-Token=REDACTED'))
end

-- forward declaration: pickSection is defined with the server-connection
-- code far below, but SelectItem and the Account pickers call it; declaring
-- the local here makes those references resolve to it as an upvalue rather
-- than a nil global
local pickSection
-- forward declaration: maybeRefillRadio is called from playIndex but is defined
-- with the queue-append helpers below it
local maybeRefillRadio

local function dataReceived (binding, navId, seq, data)
	C4:SendToProxy (binding, 'DATA_RECEIVED', {NAVID = navId, SEQ = seq, DATA = data or ''})
end

local function dataError (binding, navId, seq, msg)
	C4:SendToProxy (binding, 'DATA_RECEIVED', {NAVID = navId, SEQ = seq, DATA = '', ERROR = msg or 'error'})
end

-- map Plex client errors to sentences a Navigator user can act on; the raw
-- detail goes to the debug log only
local function friendlyErr (err)
	err = scrubToken (err)
	Debug.Warn ('plex error:', err)
	if (err == 'unauthorized') then return 'Your Plex account link was rejected - re-link from the Settings tab' end
	if (err == 'not configured') then return 'Plex is not set up yet - open the Settings tab' end
	if (err == 'request failed to start' or err == 'C4:url unavailable') then
		return 'The request to the Plex server could not be started'
	end
	if (err == 'invalid request path') then return 'The Plex server returned an unusable item link' end
	if (err == 'response too large') then return 'The Plex server sent an oversized response' end
	if (err == 'no data') then return 'That item has no playable tracks' end
	if (err == 'bad rating key') then return 'That item is no longer available' end
	if (err == 'unparseable response' or err:find ('^unexpected response root')) then
		return 'The Plex response could not be read'
	end
	if (err:find ('^HTTP 404')) then return 'Not found on the Plex server - the library may have changed' end
	if (err:find ('^HTTP')) then return 'The Plex server returned an error' end
	if (err:find ('transfer error')) then return 'The Plex server is not responding' end
	return 'The Plex request failed'
end

-- playback failure reasons -> the message the Navigator user sees
local function playFailMsg (reason)
	if (reason == 'noroom') then return 'Select this service in a room first' end
	if (reason == 'full') then return 'The queue is full' end
	-- an artist Plex has not analyzed has no station; the Play Mix row still
	-- shows (we cannot know per-artist up front), so say so plainly
	if (reason == 'no mix' or reason == 'no station') then
		return 'No mix available for this artist yet'
	end
	if (reason == 'notrack' or reason == 'no data') then
		return 'That item has no playable tracks'
	end
	-- an unbuildable stream URL means the driver is not configured yet
	if (reason == 'nourl') then return 'Plex is not set up yet - open the Settings tab' end
	-- fall back to the Plex client error map so auth/404/timeout read correctly
	-- instead of a blanket "try again" that would never succeed
	if (reason and reason ~= '') then return friendlyErr (reason) end
	return 'The stream could not be started - please try again'
end

local function sendEvent (navId, roomId, name, evtargs)
	C4:SendToProxy (MSP, 'SEND_EVENT', {NAVID = navId, ROOMS = roomId, NAME = name, EVTARGS = evtargs}, 'COMMAND')
end

-- steady-state broadcasts go to the session's rooms, not the whole system
local function sessionRooms ()
	return (gRooms ~= '' and gRooms) or nil
end

-- toast to the session's rooms, or the last known room; with no room known
-- the toast is suppressed rather than broadcast house-wide
local function notifyUser (title, message)
	local rooms = sessionRooms () or validRooms (gLastRoom)
	if (not rooms) then
		Debug.Warn ('notification suppressed (no room):', message)
		return
	end
	sendEvent (nil, rooms, 'DriverNotification',
		'<Id>c4plex</Id><Title>' .. esc (title) .. '</Title><Message>' .. esc (message) .. '</Message>')
end

-- remember the room attached to any proxy command; SELECT_AUDIO_URL needs one
local function noteRoom (tParams)
	local r = validRooms (tParams and (tParams.ROOMID or tParams.ROOM_ID))
	if (r) then gLastRoom = r end
end

-- QUEUE_INFO codec: "gen:index". The generation lets stale engine echoes
-- (from before a queue replace or shuffle) be recognized and rejected.
local function makeQI (idx)
	return tostring (gSelectGen) .. ':' .. tostring (idx or '')
end

local function parseQI (s)
	local gen, idx = tostring (s or ''):match ('^(%d+):(%d+)$')
	return tonumber (gen), tonumber (idx)
end

-- ---- track extraction -----------------------------------------------------

local function capField (s)
	return tostring (s or ''):sub (1, TRACK_FIELD_MAX)
end

-- Collapse a <Track> row into what playback and display need. duration is
-- milliseconds on the wire; kept as seconds here. String fields are capped:
-- they are mirrored per-track up to QUEUE_MAX times and persisted.
local function trackFromRow (row)
	local a = row.attrs
	local t = {
		rk = capField (a.ratingKey),
		title = capField (a.title),
		artist = capField (a.grandparentTitle or a.originalTitle),
		album = capField (a.parentTitle),
		durSec = math.floor ((finite (a.duration) or 0) / 1000),
		thumb = capField (a.thumb or a.parentThumb or a.grandparentThumb),
	}
	for _, media in ipairs (row.children) do
		if (media.tag == 'Media') then
			t.codec = capField (media.attrs.audioCodec)
			for _, part in ipairs (media.children) do
				if (part.tag == 'Part') then
					-- part keys run longer than display fields but are still
					-- bounded: they ride in every queue mirror and persist
					t.partKey = tostring (part.attrs.key or ''):sub (1, 512)
					break
				end
			end
			break
		end
	end
	return (t.rk ~= '') and t or nil
end

-- codecs the Digital Audio engine is trusted to direct-play. Conservative on
-- purpose; anything else goes through the server transcode. UNVERIFIED list -
-- bench will refine it.
local DIRECT_CODECS = {mp3 = true, aac = true, flac = true}

local function playbackMode ()
	local p = tostring (Properties and Properties ['Playback'] or '')
	if (p:find ('Direct', 1, true)) then return 'direct' end
	local kbps = tonumber (p:match ('(%d+)%s*kbps')) or DEFAULT_KBPS
	return 'transcode', kbps
end

-- Returns url, mode ('direct'|'transcode'). positionSec is baked into the
-- transcode URL only (progressive transcodes restart at an offset; direct
-- play seeks via the engine's POSITION instead). A direct-play track whose
-- Part key fails validation falls back to the transcode rather than failing.
local function urlForTrack (track, positionSec)
	local mode, kbps = playbackMode ()
	if (mode == 'direct' and track.partKey and DIRECT_CODECS [tostring (track.codec)]) then
		local url = Plex.DirectUrl (track.partKey)
		if (url) then return url, 'direct' end
	end
	return Plex.TranscodeUrl (track.rk, kbps or DEFAULT_KBPS, positionSec), 'transcode'
end

-- ---- persistence ----------------------------------------------------------

-- The queue mirror and session state must survive a driver update/reload
-- while the engine keeps playing, or track-end finds an empty mirror and
-- playback dies silently. Note: PersistData.queue deliberately aliases
-- gQueue (same table), so mutations between persist calls are captured at
-- Director's serialization time; do not "fix" this into a copy.
local function persistQueue ()
	PersistData.queue = gQueue
	PersistData.qIndex = gIndex
	PersistData.selectGen = gSelectGen
	PersistData.rooms = gRooms
	PersistData.shuffle = gShuffle
	PersistData.rpt = gRepeat
	PersistData.unshuffled = gUnshuffled
end

-- a persisted track written by an older driver version may lack fields;
-- normalize instead of letting a nil comparison throw mid-event
local function normalizeTrack (t)
	if (type (t) ~= 'table' or type (t.rk) ~= 'string' or t.rk == '') then return nil end
	t.title = capField (t.title)
	t.artist = capField (t.artist)
	t.album = capField (t.album)
	t.durSec = math.max (0, math.floor (tonumber (t.durSec) or 0))
	t.thumb = capField (t.thumb)
	t.codec = t.codec and capField (t.codec) or nil
	t.partKey = t.partKey and tostring (t.partKey):sub (1, 512) or nil
	return t
end

local function restoreQueue ()
	if (type (PersistData.queue) ~= 'table') then return end
	local q = {}
	for _, t in ipairs (PersistData.queue) do
		local n = normalizeTrack (t)
		if (n) then q[#q + 1] = n end
	end
	if (#q == 0) then return end
	gQueue = q
	gIndex = math.max (0, math.min (math.floor (tonumber (PersistData.qIndex) or 0), #gQueue))
	gSelectGen = math.floor (tonumber (PersistData.selectGen) or 0)
	gRooms = validRooms (PersistData.rooms) or ''
	gShuffle = (PersistData.shuffle == true)
	gRepeat = (PersistData.rpt == true)
	if (type (PersistData.unshuffled) == 'table') then
		local u = {}
		for _, t in ipairs (PersistData.unshuffled) do
			local n = normalizeTrack (t)
			if (n) then u[#u + 1] = n end
		end
		-- Re-point restored backup entries at the very tables now in gQueue
		-- (matched by rating key, consuming duplicates in order): shuffle-off
		-- relocates the current track by table identity, and the persistence
		-- round-trip broke identity between the two arrays.
		if (#u > 0) then
			local byRk = {}
			for _, t in ipairs (gQueue) do
				byRk [t.rk] = byRk [t.rk] or {}
				table.insert (byRk [t.rk], t)
			end
			for i, t in ipairs (u) do
				local list = byRk [t.rk]
				if (list and #list > 0) then u [i] = table.remove (list, 1) end
			end
			gUnshuffled = u
		end
	end
end

-- ---- now playing / queue pushes ------------------------------------------

local function currentTrack ()
	return gQueue [gIndex]
end

local function nextIndex (from)
	if (from < #gQueue) then return from + 1 end
	if (gRepeat and #gQueue > 0) then return 1 end
	return nil
end

-- only offer buttons that do something in the current state
local function dashItems ()
	if (#gQueue == 0) then return '' end
	local skip = nextIndex (gIndex) and ' SkipFwd' or ''
	if (gPlayState == 'PLAY') then return 'Pause Stop SkipRev' .. skip
	elseif (gPlayState == 'PAUSE') then return 'Play Stop SkipRev' .. skip
	else return 'Play SkipRev' .. skip end
end

local function sendDashboard (navId, roomId)
	local items = dashItems ()
	if (navId == nil) then
		if (items == gLast.dash) then return end
		gLast.dash = items
	end
	sendEvent (navId, roomId, 'DashboardChanged', '<Items>' .. items .. '</Items>')
end

local function sendProgress (navId, roomId)
	local t = currentTrack ()
	local evt
	if (not t or t.durSec <= 0) then
		evt = '<length>0</length><offset>0</offset><label></label><canSeek>false</canSeek>'
	else
		local pos = math.min (gElapsedSec, t.durSec)
		local label = fmtTime (pos) .. ' / -' .. fmtTime (t.durSec - pos)
		evt = '<length>' .. t.durSec .. '</length><offset>' .. pos
			.. '</offset><label>' .. esc (label) .. '</label><canSeek>true</canSeek>'
	end
	if (navId == nil) then
		if (evt == gLast.progress) then return end
		gLast.progress = evt
	end
	sendEvent (navId, roomId, 'ProgressChanged', evt)
end

-- the queue Navigators render: a window of rows centered enough to always
-- include the current track, plus the NowPlaying tag block that drives the
-- Shuffle/Repeat action states
local function sendQueue (navId, roomId)
	local rows = {}
	local first = 1
	if (#gQueue > QUEUE_DISPLAY_MAX) then
		first = math.max (1, math.min (gIndex - math.floor (QUEUE_DISPLAY_MAX / 2), #gQueue - QUEUE_DISPLAY_MAX + 1))
	end
	local last = math.min (#gQueue, first + QUEUE_DISPLAY_MAX - 1)
	for i = first, last do
		local t = gQueue [i]
		local row = {'<item><title>', esc (t.title), '</title><subtitle>', esc (t.artist), '</subtitle>'}
		if (t.durSec > 0) then row[#row + 1] = '<duration>' .. fmtTime (t.durSec) .. '</duration>' end
		local art = Plex.ArtUrl (t.thumb, 140)
		if (art) then row[#row + 1] = '<image_list width="140" height="140">' .. esc (art) .. '</image_list>' end
		row[#row + 1] = '</item>'
		rows[#rows + 1] = table.concat (row)
	end
	-- NowPlayingIndex is 0-based, and relative to the window we sent
	local npIndex = math.max (0, gIndex - first)
	local np = '<can_shuffle>true</can_shuffle><can_repeat>true</can_repeat>'
		.. '<shufflemode>' .. tostring (gShuffle) .. '</shufflemode>'
		.. '<repeatmode>' .. tostring (gRepeat) .. '</repeatmode>'
	local evt = '<List>' .. table.concat (rows) .. '</List>'
		.. '<NowPlayingIndex>' .. npIndex .. '</NowPlayingIndex>'
		.. '<NowPlaying>' .. np .. '</NowPlaying>'
	if (navId == nil) then
		if (evt == gLast.queue) then return end
		gLast.queue = evt
	end
	sendEvent (navId, roomId, 'QueueChanged', evt)
end

local function updateMediaInfo ()
	local t = currentTrack ()
	local title = t and t.title or ''
	local artist = t and t.artist or ''
	local album = t and t.album or ''
	local art = (t and Plex.ArtUrl (t.thumb, 512)) or ''
	-- queue id and art are part of the key: a re-selected track on a new
	-- engine queue (or with changed art) must re-send
	local key = table.concat ({title, artist, album, art, tostring (gQueueId)}, '\1')
	if (key == gLast.info) then return end
	gLast.info = key
	-- the TITLE/ARTIST/ALBUM form is what the first-party MSP library sends;
	-- QUEUEID rides along only once the engine has told us the queue id
	local params = {TITLE = title, ARTIST = artist, ALBUM = album, IMAGEURL = art}
	if (gQueueId) then params.QUEUEID = gQueueId end
	C4:SendToProxy (MSP, 'UPDATE_MEDIA_INFO', params, 'COMMAND', true)
end

local function pushAll ()
	updateMediaInfo ()
	sendDashboard (nil, sessionRooms ())
	sendQueue (nil, sessionRooms ())
	sendProgress (nil, sessionRooms ())
end

-- ---- Plex progress reporting ---------------------------------------------

-- fire-and-forget: play history / dashboards on the Plex side. Response body
-- is ignored; a failure only ever costs the scrobble.
local function reportTimeline (state)
	local t = currentTrack ()
	if (not t or t.rk == '') then return end
	Plex.Get ('/:/timeline', {
		ratingKey = t.rk,
		key = '/library/metadata/' .. t.rk,
		state = state,
		time = tostring (gElapsedSec * 1000),
		duration = tostring (t.durSec * 1000),
	}, function () end)
end

-- ---- playback core --------------------------------------------------------

-- keep the engine's pre-fetched NEXT_URL in step with our queue. An empty
-- NEXT_URL clears a stale one; force skips the no-change shortcut, which
-- matters when the caller just invalidated gNextArmed (a nil == nil compare
-- would otherwise skip the clearing send). Without a session room the send
-- is skipped entirely: ROOM_ID='' is meaningless to the engine.
local function armNext (force)
	if (not validRooms (gRooms)) then return end
	-- no session, no arm: after a reboot or a dead restore, SET_NEXT for a
	-- room with no live queue is at best ignored and at worst perturbs the
	-- engine. During the await window the select itself carries the session.
	if (not gQueueId and not gAwaitQueueId) then return end
	local nx = nextIndex (gIndex)
	if (not force and nx == gNextArmed) then return end
	local url = ''
	if (nx) then
		url = urlForTrack (gQueue [nx]) or ''
	end
	gNextArmed = (url ~= '') and nx or nil
	C4:SendToProxy (MSP, 'SET_NEXT_AUDIO_URL', {
		ROOM_ID = gRooms,
		REPORT_ERRORS = true,
		QUEUE_INFO = makeQI (nx),
		FLAGS = 'driver=Plex Music',
		NEXT_URL = url,
	}, 'COMMAND')
end

local function progressTick ()
	if (gPlayState ~= 'PLAY') then return end
	gElapsedSec = gElapsedSec + 1
	sendProgress (nil, sessionRooms ())
	if (gElapsedSec % TIMELINE_PERIOD_SEC == 0) then reportTimeline ('playing') end
end

local function startTicker ()
	SetTimer ('c4plexProgress', ONE_SECOND, progressTick, true)
end

local function stopTicker ()
	CancelTimer ('c4plexProgress')
end

-- ---- await window ---------------------------------------------------------
-- After a SELECT the new engine queue id is unknown. The displaced id joins
-- gDeadQueueIds so the dying queue's tail events are dropped, and is also
-- kept in gReplacedQueueId so a FAILED select can restore it as live (the
-- old queue keeps playing when the engine rejects a replacement). The window
-- closes on adoption, on SELECT error, or on timeout.

local function trimDeadIds ()
	local n = 0
	for _ in pairs (gDeadQueueIds) do n = n + 1 end
	if (n > DEAD_IDS_MAX) then
		-- crude but bounded: reset and re-add only the most recent
		local keep = gReplacedQueueId
		gDeadQueueIds = {}
		if (keep) then gDeadQueueIds [keep] = true end
	end
end

-- forward declaration: defined with the engine notification handlers, used
-- by the await-window lifecycle below
local applyQueueDeleted

-- shared by the timeout timer and the no-timer fallback: nothing adopted,
-- so restore the displaced queue as live (it may well still be playing) and
-- apply any deletion that was deferred during the window
local function awaitTimedOut ()
	gAwaitQueueId = false
	if (gReplacedQueueId) then
		gDeadQueueIds [gReplacedQueueId] = nil
		gQueueId = gReplacedQueueId
		gReplacedQueueId = nil
	end
	if (gPendingDeleteRooms and (gPendingDeleteRooms == '' or gRooms == ''
			or roomsOverlap (gPendingDeleteRooms, gRooms))) then
		applyQueueDeleted ()
	end
	gPendingDeleteRooms = nil
end

local function openAwaitWindow ()
	if (gQueueId) then
		gReplacedQueueId = gQueueId
		gDeadQueueIds [gQueueId] = true
		trimDeadIds ()
	elseif (gAwaitQueueId) then
		-- a second SELECT during an open window: the first select's displaced
		-- queue is already condemned in the dead set and is no longer a safe
		-- restore target for an error on THIS select; a later PLAY adoption
		-- finds the truth instead
		gReplacedQueueId = nil
	end
	gQueueId = nil
	gAwaitQueueId = true
	-- a pending grace-delete's evidence transfers into this window instead
	-- of being destroyed: if this select fails or times out and the old
	-- session is restored, its deferred death still applies
	if (gGraceDeleteRooms) then
		gPendingDeleteRooms = gGraceDeleteRooms
		gGraceDeleteRooms = nil
	end
	CancelTimer ('c4plexGraceDelete')
	local tm = SetTimer ('c4plexAwaitQueue', AWAIT_QUEUE_TIMEOUT_MS, awaitTimedOut)
	if (not tm) then
		-- no timer, no window: an unclosable window would filter the live
		-- session's events forever, which is worse than no filtering
		awaitTimedOut ()
	end
end

local function closeAwaitWindow (adoptedId)
	if (adoptedId) then
		gQueueId = adoptedId
		gDeadQueueIds [adoptedId] = nil
		-- a short grace period: Director tears the replaced queue down
		-- AFTER the new one is confirmed, and that id-less QUEUE_DELETED
		-- must not be mistaken for the live session dying
		gDeleteGraceUntil = os.time () + DELETE_GRACE_S
		gAdoptSerial = gAdoptSerial + 1
		gAdoptAt = os.time ()
		-- the media bar was pushed before the id was known; the next push
		-- must re-send with QUEUEID attached
		gLast.info = nil
	end
	gAwaitQueueId = false
	gReplacedQueueId = nil
	gPendingDeleteRooms = nil
	CancelTimer ('c4plexAwaitQueue')
end

-- play gQueue[idx] in roomId (numeric CSV). positionSec restarts mid-track.
-- Returns ok, reason ('noroom'|'nourl') so callers can name the failure.
local function playIndex (idx, roomId, positionSec)
	-- any select supersedes a debounced seek still waiting to fire; letting
	-- it fire afterwards would yank the fresh selection to a stale offset
	CancelTimer ('c4plexSeek')
	local track = gQueue [idx]
	if (not track) then return false, 'notrack' end
	roomId = validRooms (roomId) or validRooms (gRooms) or validRooms (gLastRoom)
	if (not roomId) then
		Debug.Warn ('playIndex: no room to play in')
		return false, 'noroom'
	end
	local pos = math.max (0, math.floor (tonumber (positionSec) or 0))
	local url, mode = urlForTrack (track, pos)
	if (not url) then
		return false, 'nourl'
	end
	gIndex = idx
	gRooms = roomId
	gElapsedSec = pos
	gNextArmed = nil
	-- every SELECT is a fresh correlation epoch: a skip replaces the engine
	-- queue just like a queue replace does, and the old queue's stragglers
	-- must read as stale at every gen gate. This is what keeps a dead
	-- queue's tail events from ever masquerading as the live session.
	gSelectGen = gSelectGen + 1
	gSelectSentThisSession = true
	openAwaitWindow ()
	persistQueue ()
	Debug.Info ('play', track.title, 'in room(s)', roomId)
	local params = {
		ROOM_ID = roomId,
		STATION_URL = url,
		QUEUE_INFO = makeQI (idx),
		FLAGS = 'driver=Plex Music',
	}
	-- POSITION only for direct play: the transcode URL already starts at the
	-- offset, and seeking the engine on top would double-apply it
	if (pos > 0 and mode == 'direct') then params.POSITION = tostring (pos) end
	C4:SendToProxy (MSP, 'SELECT_AUDIO_URL', params, 'COMMAND')
	pushAll ()
	reportTimeline ('playing')
	-- force: the engine may retain a NEXT_URL across selections (behavior
	-- undocumented), so always send a fresh arm or an explicit clear
	armNext (true)
	maybeRefillRadio (roomId) -- a radio queue nearing its end gets another batch
	return true
end

-- replace the queue with `tracks` and start at startIdx; the queue is only
-- mutated once a target room is known, so a failed start cannot leave a
-- populated-but-dead queue behind
local function playTracks (tracks, startIdx, roomId)
	if (not tracks or #tracks == 0) then return false, 'notrack' end
	if (not (validRooms (roomId) or validRooms (gRooms) or validRooms (gLastRoom))) then
		return false, 'noroom'
	end
	-- the only way playIndex fails past this point is an unbuildable URL,
	-- whose only cause is a broken config; checking it BEFORE committing the
	-- queue keeps a failed start from replacing the live queue and bumping
	-- the generation out from under the engine's still-playing session
	if (not Plex.IsConfigured ()) then return false, 'nourl' end
	gRadio = nil -- an explicit play ends any radio session; playStation re-sets it
	-- copy the array: `tracks` is often a browse-cache entry (findContext
	-- returns the cached list), and later appends into gQueue must not
	-- pollute the cache. The track TABLES stay shared, which shuffle's
	-- identity handling relies on; only the array is fresh.
	local q = {}
	for i, t in ipairs (tracks) do q [i] = t end
	tracks = q
	gQueue = tracks
	gUnshuffled = nil
	gShuffle = false
	gEndStreak = 0
	-- playIndex bumps the generation for the select itself
	return playIndex (math.max (1, math.min (startIdx or 1, #tracks)), roomId)
end


local function appendTracks (tracks, roomId)
	if (not tracks or #tracks == 0) then return false, 'notrack' end
	local wasEmpty = (#gQueue == 0)
	if (wasEmpty and not (validRooms (roomId) or validRooms (gRooms) or validRooms (gLastRoom))) then
		return false, 'noroom'
	end
	if (wasEmpty and not Plex.IsConfigured ()) then return false, 'nourl' end
	local added = 0
	for _, t in ipairs (tracks) do
		if (#gQueue >= QUEUE_MAX or (gUnshuffled and #gUnshuffled >= QUEUE_MAX)) then break end
		gQueue [#gQueue + 1] = t
		if (gUnshuffled) then gUnshuffled [#gUnshuffled + 1] = t end
		added = added + 1
	end
	if (added == 0) then
		return false, 'full'
	end
	-- the caller owns the single user-facing toast (built from `added`), so no
	-- partial-add notice here; a background caller (radio refill) stays silent
	persistQueue ()
	if (wasEmpty) then
		local ok, reason = playIndex (1, roomId)
		if (not ok) then return false, reason end
		return true, nil, added, true -- started fresh playback
	end
	pushAll ()
	armNext () -- the appended tracks may create a next where none existed
	return true, nil, added, false
end

-- insert tracks to play right after the current one (Play Next). Empty queue
-- (or an anomalous restored state with nothing playing, gIndex < 1) behaves like
-- Play Now. gQueue gets them at gIndex+1 (in order); gUnshuffled keeps them
-- (appended) so a later un-shuffle still holds them. The cued next URL is
-- force-rearmed so the inserted track actually preempts what was queued.
-- Returns (ok, reason, added, started); `started` is true when it began playback
-- outright, so the caller navigates to Now Playing instead of toasting.
local function playNext (tracks, roomId)
	if (not tracks or #tracks == 0) then return false, 'notrack' end
	if (#gQueue == 0 or gIndex < 1) then
		local ok, reason = playTracks (tracks, 1, roomId)
		if (not ok) then return false, reason end
		return true, nil, #tracks, true
	end
	if (not (validRooms (roomId) or validRooms (gRooms) or validRooms (gLastRoom))) then
		return false, 'noroom'
	end
	local at, added = gIndex, 0
	for _, t in ipairs (tracks) do
		if (#gQueue >= QUEUE_MAX) then break end
		at = at + 1
		table.insert (gQueue, at, t)
		if (gUnshuffled and #gUnshuffled < QUEUE_MAX) then gUnshuffled[#gUnshuffled + 1] = t end
		added = added + 1
	end
	if (added == 0) then return false, 'full' end
	-- caller owns the single toast (built from `added`); no partial notice here
	persistQueue ()
	pushAll ()
	armNext (true) -- the inserted track is the new next; force a fresh arm to preempt any cued one
	return true, nil, added, false
end

-- ---- radio stations -------------------------------------------------------

local function tracksFromContainer (container)
	local tracks = {}
	for _, row in ipairs (container.children) do
		if (row.tag == 'Track') then
			local t = trackFromRow (row)
			if (t) then tracks[#tracks + 1] = t end
		end
	end
	return tracks
end

-- refill a playing radio station as it nears the end: fetch another random
-- batch and append it. One refill in flight at a time; a no-op unless the
-- current queue is a radio session actually running low. (Assigned to the
-- forward declaration above playIndex.)
maybeRefillRadio = function (roomId)
	if (not gRadio or gRadio.refilling) then return end
	if (gIndex < #gQueue - RADIO_REFILL_AT) then return end
	gRadio.refilling = true
	local key = gRadio.key
	Plex.StationTracks (key, function (container, err)
		if (not gRadio or gRadio.key ~= key) then return end -- radio ended or changed
		gRadio.refilling = false
		if (not container) then Debug.Warn ('radio refill failed:', tostring (err)) return end
		local tracks = tracksFromContainer (container)
		if (#tracks > 0) then appendTracks (tracks, roomId or gRooms) end
	end)
end

-- play a radio station: seed the queue from its first batch and mark it a radio
-- so it keeps refilling. cb(ok, reason).
local function playStation (stationKey, roomId, cb)
	Plex.StationTracks (stationKey, function (container, err)
		if (not container) then cb (false, err or 'no data') return end
		local tracks = tracksFromContainer (container)
		if (#tracks == 0) then cb (false, 'no data') return end
		local ok, reason = playTracks (tracks, 1, roomId)
		if (ok) then gRadio = {key = tostring (stationKey)} end -- after playTracks, which clears it
		cb (ok, reason)
	end)
end

-- Play Mix for an artist: resolve the artist's Plex station, then play it as a
-- radio (reuses playStation's refill). cb(ok, reason). Plex Pass only; artists
-- without a station report 'no mix'.
local function playMix (artistRk, roomId, cb)
	Plex.ArtistStation (artistRk, function (stationKey, err)
		if (not stationKey) then cb (false, err or 'no mix') return end
		playStation (stationKey, roomId, cb)
	end)
end

-- ---- browse -> item XML ---------------------------------------------------

-- the long-press / kabob action menu for an item, ordered, by type. Favorite to
-- Room is offered on everything; Play Mix only on artists (Plex Pass required).
-- Play Now / Play Next / Add to Queue map to PlayItem playTypes; Shuffle Play is
-- container-only. (Replace Queue is omitted: in a single mirror queue it equals
-- Play Now. Add/Remove Library have no Plex equivalent.)
local function actionsList (itemType)
	local a
	if (itemType == 'track') then
		a = {'PlayNow', 'PlayNext', 'AddToQueue'}
	elseif (itemType == 'artist') then
		-- keep the play spine stable (Play Now, Shuffle Play, ...) and slot Play
		-- Mix after it, matching the artist page's Play All / Shuffle All / Play Mix
		a = {'PlayNow', 'ShufflePlay'}
		if (gPlexPass) then a[#a + 1] = 'PlayMix' end
		a[#a + 1] = 'PlayNext'; a[#a + 1] = 'AddToQueue'
	else -- album / playlist
		a = {'PlayNow', 'ShufflePlay', 'PlayNext', 'AddToQueue'}
	end
	a[#a + 1] = 'FavoriteToRoom'
	return table.concat (a, ' ')
end

-- fav_art: a hidden item field carrying the cover-art URL, read by the Favorite
-- action so the pinned tile has artwork without a re-fetch.
local function favArtField (thumb)
	local art = Plex.ArtUrl (thumb, 400)
	return art and ('<fav_art>' .. esc (art) .. '</fav_art>') or ''
end

local function containerRow (title, subtitle, id, itemType, thumb)
	local row = {'<item><title>', esc (title), '</title>'}
	if (subtitle and subtitle ~= '') then row[#row + 1] = '<subtitle>' .. esc (subtitle) .. '</subtitle>' end
	row[#row + 1] = '<id>' .. esc (id) .. '</id>'
	row[#row + 1] = '<itemType>' .. esc (itemType) .. '</itemType>'
	row[#row + 1] = '<nav>dir</nav>'
	row[#row + 1] = '<isLink>true</isLink>'
	row[#row + 1] = '<default_action>SelectItem</default_action>'
	-- containers can also be played/queued/favorited outright from the menu
	row[#row + 1] = '<actions_list>' .. actionsList (itemType) .. '</actions_list>'
	row[#row + 1] = favArtField (thumb)
	local art = Plex.ArtUrl (thumb, 140)
	if (art) then row[#row + 1] = '<image_list width="140" height="140">' .. esc (art) .. '</image_list>' end
	row[#row + 1] = '</item>'
	return table.concat (row)
end

local function trackRow (t)
	local row = {'<item><title>', esc (t.title), '</title>'}
	if (t.artist ~= '') then row[#row + 1] = '<subtitle>' .. esc (t.artist) .. '</subtitle>' end
	row[#row + 1] = '<id>' .. esc (t.rk) .. '</id>'
	row[#row + 1] = '<itemType>track</itemType>'
	row[#row + 1] = '<nav>play</nav>'
	if (t.durSec > 0) then row[#row + 1] = '<duration>' .. fmtTime (t.durSec) .. '</duration>' end
	row[#row + 1] = '<default_action>SelectItem</default_action>'
	row[#row + 1] = '<actions_list>' .. actionsList ('track') .. '</actions_list>'
	row[#row + 1] = favArtField (t.thumb)
	local art = Plex.ArtUrl (t.thumb, 140)
	if (art) then row[#row + 1] = '<image_list width="140" height="140">' .. esc (art) .. '</image_list>' end
	row[#row + 1] = '</item>'
	return table.concat (row)
end

-- remember a rendered track container so SelectItem can play it in context.
-- Keyed by container path PLUS page offset: pages of one large container are
-- separate entries, so paging forward never evicts the rows still on screen.
local function cacheContainer (key, tracks)
	gCtxStamp = gCtxStamp + 1
	gCtx [key] = {tracks = tracks, stamp = gCtxStamp}
	local n = 0
	for _ in pairs (gCtx) do n = n + 1 end
	if (n > MAX_CTX) then
		local oldestKey, oldest
		for k, c in pairs (gCtx) do
			if (not oldest or c.stamp < oldest) then oldest, oldestKey = c.stamp, k end
		end
		gCtx [oldestKey] = nil
	end
end

-- find a cached (container, index) pair for a track id
local function findContext (rk)
	local best, bestIdx
	for _, c in pairs (gCtx) do
		for i, t in ipairs (c.tracks) do
			if (t.rk == rk) then
				-- newest container wins if the track appears in several
				if (not best or c.stamp > best.stamp) then best, bestIdx = c, i end
				break
			end
		end
	end
	if (best) then return best.tracks, bestIdx end
	return nil
end

-- build the <List> reply for a container of rows. Track containers are
-- cached for context playback. The length attribute is emitted only when a
-- sane total is known and rows exist (an empty list ships a message row,
-- which a declared length of 0 could suppress). opts.header = {id, itemType}
-- prepends Play All / Shuffle All rows when the container has tracks.
local function containerActionRow (label, nav, id, itemType)
	return '<item><title>' .. esc (label) .. '</title>'
		.. '<id>' .. esc (id) .. '</id>'
		.. '<itemType>' .. esc (itemType) .. '</itemType>'
		.. '<nav>' .. nav .. '</nav>'
		.. '<default_action>SelectItem</default_action></item>'
end

-- a drill-into link row (chevron, no play/queue actions): the artist page's
-- Top Tracks / Discography / Similar Artists rows and the Extras browse
-- dimensions (Recently Played/Added, Most Played, Genres, Decades, Moods)
local function navLinkRow (label, id, itemType)
	return '<item><title>' .. esc (label) .. '</title>'
		.. '<id>' .. esc (id) .. '</id>'
		.. '<itemType>' .. esc (itemType) .. '</itemType>'
		.. '<nav>dir</nav><isLink>true</isLink>'
		.. '<default_action>SelectItem</default_action></item>'
end

local function listFromContainer (cacheKey, container, opts)
	local items = {}
	local tracks = {}
	for _, row in ipairs (container.children) do
		if (#items >= LIST_ROWS_MAX) then break end
		if (row.tag == 'Track') then
			local t = trackFromRow (row)
			if (t) then
				tracks[#tracks + 1] = t
				items[#items + 1] = trackRow (t)
			end
		elseif (row.tag == 'Directory') then
			local a = row.attrs
			local rtype = a.type
			if (rtype == 'artist' or rtype == 'album') then
				local subtitle = (rtype == 'album') and (a.parentTitle or '') or ''
				-- similar-artist rows can arrive without a browse key; build
				-- the children path from the ratingKey so they still drill
				local key = a.key
				if ((not key or key == '') and a.ratingKey) then
					key = '/library/metadata/' .. a.ratingKey .. '/children'
				end
				items[#items + 1] = containerRow (a.title or '', subtitle, key or '', rtype, a.thumb)
			end
		elseif (row.tag == 'Playlist') then
			local a = row.attrs
			local n = finite (a.leafCount)
			local subtitle = n and (n == 1 and '1 track' or (n .. ' tracks')) or ''
			items[#items + 1] = containerRow (a.title or '', subtitle, a.key or '', 'playlist', a.composite)
		end
	end
	if (#tracks > 0) then cacheContainer (cacheKey, tracks) end
	local total = finite (container.attrs.totalSize)
	if (#items == 0) then
		items[1] = '<item><title>No results</title><isHeader>true</isHeader></item>'
		total = nil
	elseif (opts and opts.header and #tracks > 0 and (not total or total <= #tracks)) then
		-- the "top menu" for an opened album/playlist: whole-container Play All /
		-- Shuffle All as the first rows. (Artist pages are rendered separately by
		-- renderArtistPage, so they never reach here.)
		-- Only when the whole container arrived in this one fetch: the header rows
		-- exist on page 1 alone, so prepending them to a PAGINATED list would shift
		-- every later track by two and desync Navigator's OFFSET paging (dropped or
		-- repeated rows at each boundary). A paginated container shows all its tracks
		-- correctly, just without the header rows.
		local pre = {
			containerActionRow ('Play All', 'playall', opts.header.id, opts.header.itemType),
			containerActionRow ('Shuffle All', 'shuffleall', opts.header.id, opts.header.itemType),
		}
		for i = #pre, 1, -1 do table.insert (items, 1, pre [i]) end
		if (total) then total = total + #pre end
	end
	local open = total and ('<List length="' .. total .. '">') or '<List>'
	return open .. table.concat (items) .. '</List>', tracks
end

-- recent searches, persisted; served to the native search History block
local function pushSearchHistory (q)
	q = tostring (q or '')
	if (q == '') then return end
	local hist = PersistData.searchHistory
	if (type (hist) ~= 'table') then hist = {} end
	local out = {q}
	for _, h in ipairs (hist) do
		if (h ~= q and #out < 10) then out[#out + 1] = h end
	end
	PersistData.searchHistory = out
end

-- ---- browse reply cache ---------------------------------------------------

local function browseCachePut (key, data, tracks, cacheKey)
	gBrowseStamp = gBrowseStamp + 1
	gBrowseCache [key] = {data = data, tracks = tracks, cacheKey = cacheKey,
		stamp = gBrowseStamp, at = os.time ()}
	local n = 0
	for _ in pairs (gBrowseCache) do n = n + 1 end
	if (n > BROWSE_CACHE_MAX) then
		local oldestKey, oldest
		for k, c in pairs (gBrowseCache) do
			if (not oldest or c.stamp < oldest) then oldest, oldestKey = c.stamp, k end
		end
		gBrowseCache [oldestKey] = nil
	end
end

local function browseCacheGet (key)
	local c = gBrowseCache [key]
	if (not c) then return nil end
	if (os.time () - c.at > BROWSE_CACHE_TTL) then
		gBrowseCache [key] = nil
		return nil
	end
	-- the context cache may have evicted this page since it was rendered;
	-- re-register its tracks so a tap still plays in context
	if (c.tracks and #c.tracks > 0) then cacheContainer (c.cacheKey, c.tracks) end
	return c.data
end

local function clearBrowseCaches ()
	gBrowseCache = {}
	gAlpha = {}
	-- gCtx belongs to the previous configuration too: a track row cached from
	-- server A must not be resolvable by findContext after switching to server
	-- B, or a tap builds B's host with A's ratingKey (wrong or dead playback,
	-- since Plex servers number ratingKeys from small ints and collide).
	gCtx = {}
end

-- ---- AlphaMap -------------------------------------------------------------

-- Build the <AlphaMap> for a section+type from the firstCharacter buckets:
-- cumulative indices into the default-sorted full listing, exactly the
-- offsets Navigator will request via DATA_OFFSET. Cached; cb(xml or '').
local function alphaMapFor (sectionKey, mediaType, cb)
	local key = tostring (sectionKey) .. ':' .. tostring (mediaType)
	local hit = gAlpha [key]
	if (hit and os.time () - hit.at <= ALPHA_TTL) then
		cb (hit.xml)
		return
	end
	local gen = gConnectGen
	Plex.FirstCharacters (sectionKey, mediaType, function (buckets, err)
		if (gen ~= gConnectGen) then
			-- config/section changed while the buckets were in flight; a
			-- stale index under a colliding small-integer section key would
			-- misplace the scrubber for ten minutes
			cb ('')
			return
		end
		if (not buckets) then
			Debug.Warn ('alpha map fetch failed:', tostring (err))
			cb ('')
			return
		end
		local parts = {}
		local idx = 0
		for _, b in ipairs (buckets) do
			parts[#parts + 1] = '<item><key>' .. esc (b.title) .. '</key><index>' .. idx .. '</index></item>'
			idx = idx + b.size
		end
		local xml = (#parts > 0) and ('<AlphaMap>' .. table.concat (parts) .. '</AlphaMap>') or ''
		gAlpha [key] = {xml = xml, at = os.time ()}
		cb (xml)
	end)
end

-- ---- fetching whole containers for playback -------------------------------

-- fetch a container's tracks (album children / playlist items / artist
-- allLeaves) and hand them to done(tracks). Cap at CONTAINER_FETCH_MAX.
local function fetchTracks (path, done)
	Plex.Children (path, 0, CONTAINER_FETCH_MAX, function (container, err)
		if (not container) then
			done (nil, err)
			return
		end
		local tracks = {}
		for _, row in ipairs (container.children) do
			if (#tracks >= CONTAINER_FETCH_MAX) then break end
			if (row.tag == 'Track') then
				local t = trackFromRow (row)
				if (t) then tracks[#tracks + 1] = t end
			end
		end
		-- a container larger than the fetch cap must not look complete: the
		-- fetch itself is capped at CONTAINER_FETCH_MAX rows, so compare the
		-- server's real totalSize (not the truncated page) and warn, as
		-- appendTracks does on a full queue, instead of silently dropping
		-- truncation happened iff the container held more than the fetch cap;
		-- compare totalSize to the CAP, not to the filtered #tracks (a mixed
		-- container has totalSize > #tracks with nothing actually dropped)
		local total = finite (container.attrs.totalSize)
		-- warn only on a real drop: a known total ABOVE the cap, or (total
		-- unknown) a page that filled the cap. A known total EQUAL to the cap
		-- dropped nothing, so it must not toast.
		if ((total and total > CONTAINER_FETCH_MAX) or (not total and #tracks >= CONTAINER_FETCH_MAX)) then
			-- verb-neutral: this list feeds Play Now, Shuffle, Add, and Play Next
			-- alike, so it must not claim "playing" during a queue add
			notifyUser ('Plex Music', 'Large item - limited to the first ' .. #tracks .. ' tracks')
		end
		done (tracks)
	end)
end

-- resolve an item (track/album/playlist/artist) to a track list + start index
-- allowlist for a Navigator-supplied container key that becomes a request
-- path. Only the shapes this driver's own list rows emit are accepted, so a
-- crafted id cannot reach an arbitrary (possibly side-effecting) endpoint on
-- the pinned Plex host. NOTE: when the deferred hub / album-category browse
-- lands, its '/library/sections/{id}/...' keys must be added here.
local function isBrowseKey (id)
	id = tostring (id)
	return (id:match ('^/library/metadata/%d+/children$')
		or id:match ('^/library/metadata/%d+/allLeaves$')
		or id:match ('^/playlists/%d+/items$')) ~= nil
end

-- solo (optional): for a track, ignore any cached list context and resolve just
-- the one track. A pinned favorite uses this so recall is deterministic (it
-- plays the track you pinned, not whatever album/playlist happened to be cached).
local function resolveItem (id, itemType, cb, solo)
	if (itemType == 'track') then
		if (not solo) then
			local tracks, idx = findContext (id)
			if (tracks) then
				cb (tracks, idx)
				return
			end
		end
		-- solo, or no cached context (driver reloaded, page evicted): play it alone
		local rk = tostring (id):match ('^%d+$')
		if (not rk) then cb (nil, nil, 'bad rating key') return end
		Plex.Children ('/library/metadata/' .. rk, 0, 1, function (container, err)
			if (not container) then cb (nil, nil, err) return end
			-- /library/metadata/{rk} returns the track itself as the row
			local tracks2 = {}
			for _, row in ipairs (container.children) do
				if (row.tag == 'Track') then
					local t = trackFromRow (row)
					if (t) then tracks2[#tracks2 + 1] = t end
				end
			end
			cb (tracks2, 1)
		end)
		return
	end
	-- Top Tracks is a playable list off the artist rk (not a browse-key path);
	-- Plex.PopularTracks returns a flat Track container, so Play All / Shuffle All
	-- on that screen resolve through here.
	if (itemType == 'toptracks') then
		Plex.PopularTracks (id, function (container, err)
			if (not container) then cb (nil, nil, err) return end
			local tracks = tracksFromContainer (container)
			if (#tracks == 0) then cb (nil, nil, 'no data') return end
			cb (tracks, 1)
		end)
		return
	end
	-- artists play all their tracks; albums/playlists their children. id
	-- becomes a request path, so it must be one of our own browse keys.
	if (not isBrowseKey (id)) then
		cb (nil, nil, 'invalid request path')
		return
	end
	local path = id
	if (itemType == 'artist') then
		path = tostring (id):gsub ('/children$', '/allLeaves')
	end
	fetchTracks (path, function (tracks, err)
		cb (tracks, 1, err)
	end)
end

-- ---- plex.tv account linking ----------------------------------------------

local function setLinkStatus (s)
	UpdateProperty ('Account Link', tostring (s))
end

-- appended to the code box (not the Composer status property): the box stays
-- up through the account link AND the server discovery that follows, so tell
-- the user to leave it alone until it finishes on its own.
local LINK_KEEP_OPEN =
	'\n\nPlease keep this window open - it can take up to a minute to finish after you enter the code.'

-- targeted (or broadcast, navId nil) link-code dialog. The dialog is sent
-- WITH an InstanceId so the matching close can dismiss it; a notification
-- sent without one cannot be closed by InstanceId, which is why the code
-- box lingered after success.
local function linkNotify (navId, message)
	gLinkNavs [navId or '*'] = true
	local inst = navId and ('<InstanceId>' .. esc (navId) .. '</InstanceId>') or ''
	sendEvent (navId, nil, 'DriverNotification',
		'<Id>PlexLink</Id>' .. inst .. '<Title>Link Plex Account</Title><Message>' .. esc (message) .. '</Message>')
end

-- close the code dialog everywhere it was shown: matched per navigator by
-- InstanceId plus a plain broadcast fallback
local function closeLinkDialog ()
	for nav in pairs (gLinkNavs) do
		if (nav ~= '*') then
			sendEvent (nav, nil, 'CloseDriverNotification',
				'<Id>PlexLink</Id><InstanceId>' .. esc (nav) .. '</InstanceId>')
		end
	end
	sendEvent (nil, nil, 'CloseDriverNotification', '<Id>PlexLink</Id>')
	gLinkNavs = {}
end

local LINK_POLL_MS = 5000
local LINK_LIFETIME_MAX = 900 -- cap even if plex.tv grants longer

-- end the flow: clear state, stop the poll, optionally dismiss the dialog
local function endLinkFlow (status, closeDialog)
	gLink = nil
	if (status == 'Linked') then gLinkErr = nil end
	CancelTimer ('c4plexPinPoll')
	if (status) then setLinkStatus (status) end
	if (closeDialog) then closeLinkDialog () end
end

-- a link code that ran out its lifetime. If a token arrived meanwhile the
-- account is linked, so close normally; otherwise keep the dialog open with an
-- actionable message rather than closing it silently onto a settings screen that
-- does not self-refresh (which would strand the "expired, try again" guidance).
local function expireLinkFlow (navId)
	if (Plex.HasToken ()) then
		endLinkFlow ('Linked', true)
	else
		endLinkFlow ('Link code expired - run Link Plex Account for a new one', false)
		linkNotify (navId, 'That link code expired.\n\nClose this and press Get Link Code for a new one.')
	end
end

-- Start (or re-announce) the plex.tv PIN link flow: request a 4-character
-- code, show "visit plex.tv/link, enter CODE", poll until the user claims it,
-- then write the account token into the Plex Token property (the single source
-- of truth; the write triggers the normal connect path).
local function startLinkFlow (navId)
	-- an already-linked driver never opens a new pin flow: connectivity
	-- problems are the server's, not the link's, and a fresh code dialog
	-- over a working link is pure confusion. Unlink first to re-link.
	if (Plex.HasToken ()) then
		endLinkFlow ('Linked', true)
		return
	end
	if (gLink) then
		if (gLink.pending) then return end -- a pin request is already in flight
		if (os.time () > gLink.deadline) then
			-- the poll should have expired this; a dead poll timer must not
			-- pin the flow open forever
			endLinkFlow (nil, true)
		else
			-- a code is already outstanding: repeat it for this Navigator
			linkNotify (navId, 'Visit plex.tv/link and enter code ' .. gLink.code .. LINK_KEEP_OPEN)
			return
		end
	end
	gLink = {pending = true}
	gLinkErr = nil
	setLinkStatus ('Requesting a link code...')
	local mine = gLink
	Plex.TvRequestPin (function (pin, err)
		if (gLink ~= mine) then return end -- superseded or cancelled
		if (Plex.HasToken ()) then
			-- a token was pasted while the pin request was in flight; the
			-- account is linked and the code would only confuse (or its
			-- claim would overwrite the working token)
			endLinkFlow ('Linked', true)
			return
		end
		if (not pin) then
			gLink = nil
			err = tostring (err)
			gLinkErr = (err:find ('^HTTP')) and 'plex.tv returned an error - try again'
				or 'The controller could not reach plex.tv'
			setLinkStatus ('Link failed - ' .. gLinkErr)
			-- the settings screen does not self-refresh, so a failure with no
			-- code box would leave "Requesting a link code..." on screen with
			-- no resolution. Surface the reason in a dialog the user can act on.
			linkNotify (navId, gLinkErr .. '\n\nClose this and press Get Link Code to try again.')
			Debug.Warn ('pin request failed:', err)
			return
		end
		-- floor as well as cap: a zero/negative expiresIn must not produce a
		-- flow that expires before its first poll
		local life = math.max (60, math.min (tonumber (pin.expiresIn) or LINK_LIFETIME_MAX, LINK_LIFETIME_MAX))
		gLink = {id = pin.id, code = pin.code, deadline = os.time () + life}
		local msg = 'Visit plex.tv/link and enter code ' .. pin.code
		setLinkStatus (msg)
		linkNotify (navId, msg .. LINK_KEEP_OPEN)
		local pinId = pin.id
		local tm = SetTimer ('c4plexPinPoll', LINK_POLL_MS, function ()
			if (not gLink or gLink.id ~= pinId) then
				CancelTimer ('c4plexPinPoll')
				return
			end
			if (os.time () > gLink.deadline) then
				expireLinkFlow (navId)
				return
			end
			Plex.TvCheckPin (pinId, function (res, cerr)
				-- correlate: a lagging response for an older pin must not
				-- disturb a fresh flow
				if (not gLink or gLink.id ~= pinId) then return end
				if (not res) then
					if (cerr == 'pin expired') then
						expireLinkFlow (navId)
					end
					-- transient plex.tv errors: keep polling to the deadline
					return
				end
				if (res.authToken ~= '') then
					local navs = {}
					for nav in pairs (gLinkNavs) do navs[#navs + 1] = nav end
					-- leave the code box on screen (still showing the code) until
					-- the connect resolves: closing it now would blank the screen
					-- for the second or two the server takes to find, and an
					-- open settings screen will not refresh its own status.
					-- endLinkFlow(false) stops the poll and clears link state
					-- without dismissing the box; the success/fault box then
					-- replaces it and carries the user to the linked screen.
					endLinkFlow ('Linked', false)
					gLinkDoneNavs = navs
					UpdateProperty ('Plex Token', res.authToken, true)
				end
			end)
		end, true)
		if (not tm) then
			-- no poll timer, no flow: leaving the code up with nothing
			-- checking it would pin the state open forever
			gLinkErr = 'the controller could not start the check timer'
			endLinkFlow ('Link failed - ' .. gLinkErr, true)
		end
	end)
end

-- ---- proxy commands: browse ----------------------------------------------

-- root listing per screen; drills follow the tapped row's own key. Playlist
-- /playlists has no server-side title filter, so a playlist search matches
-- client-side over EVERY playlist. Page through them (Plex caps a page well
-- below a large collection) and hand back one container; bounded so a runaway
-- library cannot spin forever. cb(container) or cb(nil, err) on a first-page
-- failure. A later-page failure returns what was gathered so far.
local PLAYLIST_SCAN_MAX = 2000 -- max playlists gathered
local PLAYLIST_PAGE_MAX = 20   -- max page requests (bounds a small-paging server)
local function fetchAllPlaylists (cb)
	local all = {}
	local function page (start, pages)
		Plex.Playlists (start, 200, function (container, err)
			if (not container) then
				if (#all > 0) then cb ({tag = 'MediaContainer', attrs = {}, children = all})
				else cb (nil, err) end
				return
			end
			local got = #container.children -- rows returned this page (any tag)
			for _, row in ipairs (container.children) do
				if (row.tag == 'Playlist') then all[#all + 1] = row end
			end
			-- advance by rows ACTUALLY returned so a server that pages below the
			-- requested 200 does not skip the remainder. Two independent bounds
			-- guarantee termination regardless of what the server sends: a page
			-- cap (a server returning tiny pages can't spin) and a gathered cap.
			-- got==0 (past the end) also stops.
			local total = finite (container.attrs.totalSize)
			local nextStart = start + got
			if (got > 0 and pages < PLAYLIST_PAGE_MAX and #all < PLAYLIST_SCAN_MAX
					and (not total or nextStart < total)) then
				page (nextStart, pages + 1)
			else
				cb ({tag = 'MediaContainer', attrs = {}, children = all})
			end
		end)
	end
	page (0, 1)
end

-- search is client-side: /playlists has no server-side title filter, so a
-- searched playlists root pages every playlist, filters, and slices to the
-- requested window with the filtered total as the list length.
local function browseRoot (screenId, start, count, search, cb)
	if (screenId == 'playlists') then
		if (search and search ~= '') then
			fetchAllPlaylists (function (container, err)
				if (not container) then cb (nil, err) return end
				local needle = tostring (search):lower ()
				local kept = {}
				for _, row in ipairs (container.children) do
					local title = tostring (row.attrs and row.attrs.title or ''):lower ()
					if (title:find (needle, 1, true)) then kept[#kept + 1] = row end
				end
				local page = {}
				for i = start + 1, math.min (#kept, start + count) do
					page[#page + 1] = kept [i]
				end
				cb ({tag = container.tag, attrs = {totalSize = tostring (#kept)}, children = page})
			end)
		else
			Plex.Playlists (start, count, cb)
		end
		return
	end
	local mediaType = (screenId == 'albums') and Plex.TYPE_ALBUM or Plex.TYPE_ARTIST
	if (search and search ~= '') then
		Plex.Search (gSectionKey, mediaType, search, start, count, cb)
	else
		Plex.SectionAll (gSectionKey, mediaType, start, count, nil, cb)
	end
end

-- virtual browse item types: id-carrying rows that are NOT a plain container
-- drill. Most route to a dedicated fetch off a bare-token id; `discography` is
-- the exception - it carries a real /children browse-key path and falls through
-- to the generic container branch, and is listed here only so it skips the Play
-- All header. All are namespaced in the cache key so an id cannot collide with a
-- real container's.
local VIRTUAL_ITEMTYPE = {
	toptracks = true, similar = true,
	genres = true, decades = true, moods = true,
	genrealbums = true, decadealbums = true, moodalbums = true,
	recentplayed = true, recentadded = true, mostplayed = true,
	discography = true,
}

-- the collapsed "Recently/Most" album drills are single capped pages, not the
-- whole library: past this many the list stops (recents/most-played that deep
-- are not useful).
local RECENT_CAP = 50

-- Moods number in the hundreds and most are obscure; show a recognizable
-- shortlist (only those the library actually has, see renderTagList) instead of
-- a 300-row wall. Order here is the display order.
local CURATED_MOODS = {
	'Happy', 'Sad', 'Melancholy', 'Energetic', 'Chill', 'Relaxed', 'Romantic',
	'Angry', 'Aggressive', 'Peaceful', 'Dreamy', 'Nostalgic', 'Party', 'Uplifting',
	'Dark', 'Mellow', 'Sexy', 'Epic', 'Groovy', 'Funky', 'Warm', 'Bittersweet',
	'Playful', 'Sentimental', 'Ethereal', 'Hypnotic',
}

-- the Extras landing: a curated screen combining the radio Stations (Plex Pass),
-- Recently Played, and Recently Added albums. Three fetches joined into one
-- non-paginated reply; each section is omitted when empty, so a non-Pass account
-- simply sees the two recent lists.
local function renderExtras (idBinding, navId, seq)
	if (not gSectionKey) then
		dataError (idBinding, navId, seq, gSectionsLoaded
			and 'No music library found on the Plex server'
			or 'The music library is still loading - try again in a moment')
		return
	end
	local gen = gConnectGen
	-- only the Stations section needs data on the landing (to know Plex Pass and
	-- list the stations to tap); everything else is a collapsed drill row opened
	-- on demand, so the landing is one quick fetch.
	Plex.Stations (gSectionKey, function (list)
		if (gen ~= gConnectGen) then dataReceived (idBinding, navId, seq, '<List></List>') return end
		local items = {}
		-- Plex Pass content up top; the whole section is omitted (no header) when
		-- the account has no stations
		if (list and #list > 0) then
			items[#items + 1] = '<item><title>Stations</title><isHeader>true</isHeader></item>'
			for _, s in ipairs (list) do
				items[#items + 1] = containerActionRow (s.title, 'station', s.key, 'station')
			end
		end
		-- universal content (any account), each a collapsed drill row
		items[#items + 1] = '<item><title>Library</title><isHeader>true</isHeader></item>'
		items[#items + 1] = navLinkRow ('Recently Played', gSectionKey, 'recentplayed')
		items[#items + 1] = navLinkRow ('Recently Added', gSectionKey, 'recentadded')
		items[#items + 1] = navLinkRow ('Most Played', gSectionKey, 'mostplayed')
		items[#items + 1] = navLinkRow ('Decades', gSectionKey, 'decades')
		items[#items + 1] = navLinkRow ('Genres', gSectionKey, 'genres')
		items[#items + 1] = navLinkRow ('Moods', gSectionKey, 'moods')
		dataReceived (idBinding, navId, seq, '<List>' .. table.concat (items) .. '</List>')
	end)
end

-- render a tag-dimension list (genres/decades/moods) as drill rows; each tag
-- drills to its albums via the itemType passed. `curated` (optional) is an
-- ordered name list: only tags whose title the library actually has are shown,
-- in curated order (used to tame the ~300 moods down to a recognizable set).
local function renderTagList (dim, albumItemType, idBinding, navId, seq, curated)
	if (not gSectionKey) then
		dataError (idBinding, navId, seq, 'The music library is still loading - try again in a moment')
		return
	end
	local gen = gConnectGen
	Plex.TagList (gSectionKey, dim, function (list, err)
		if (gen ~= gConnectGen) then
			-- config changed mid-fetch: the list is for the old library. Answer
			-- anyway (empty) so the Navigator never hangs; it re-browses next.
			dataReceived (idBinding, navId, seq, '<List></List>')
			return
		end
		if (not list) then dataError (idBinding, navId, seq, friendlyErr (err)) return end
		local items = {}
		if (curated) then
			-- only the curated tags the library actually has, in curated order
			local have = {}
			for _, tag in ipairs (list) do have [tostring (tag.title):lower ()] = tag end
			for _, name in ipairs (curated) do
				local tag = have [tostring (name):lower ()]
				if (tag) then items[#items + 1] = navLinkRow (tag.title, tag.id, albumItemType) end
			end
		else
			for _, tag in ipairs (list) do
				items[#items + 1] = navLinkRow (tag.title, tag.id, albumItemType)
			end
		end
		if (#items == 0) then
			items[1] = '<item><title>None found</title><isHeader>true</isHeader></item>'
		end
		dataReceived (idBinding, navId, seq, '<List>' .. table.concat (items) .. '</List>')
	end)
end

-- the artist page: a compact menu (like Deezer) instead of an inline album list.
-- Play All / Shuffle All, Play Mix (Plex Pass), then Top Tracks / Discography /
-- Similar Artists drill rows. `id` is the artist's /library/metadata/{rk}/children
-- key; Discography reuses it, the others use the bare rk. No fetch needed.
local function renderArtistPage (idBinding, navId, seq, id)
	local rk = tostring (id):match ('/library/metadata/(%d+)')
	if (not rk) then dataError (idBinding, navId, seq, friendlyErr ('invalid request path')) return end
	local items = {
		containerActionRow ('Play All', 'playall', id, 'artist'),
		containerActionRow ('Shuffle All', 'shuffleall', id, 'artist'),
	}
	if (gPlexPass) then
		items[#items + 1] = containerActionRow ('Play Mix', 'playmix', rk, 'artist')
	end
	if (gModernAgent) then
		items[#items + 1] = navLinkRow ('Top Tracks', rk, 'toptracks')
	end
	items[#items + 1] = navLinkRow ('Discography', id, 'discography')
	if (gModernAgent) then
		items[#items + 1] = navLinkRow ('Similar Artists', rk, 'similar')
	end
	dataReceived (idBinding, navId, seq, '<List>' .. table.concat (items) .. '</List>')
end

RFP.Browse = function (idBinding, strCommand, tParams, args)
	noteRoom (tParams)
	local navId, seq = tParams.NAVID, tParams.SEQ
	-- floor and clamp Navigator-supplied paging before it becomes a server
	-- container size (an absurd count would amplify straight into memory)
	local start = math.max (0, math.floor (tonumber (args.start) or 0))
	local count = math.floor (tonumber (args.count) or 100)
	if (count <= 0) then count = 100 end
	if (count > LIST_ROWS_MAX) then count = LIST_ROWS_MAX end
	local search = args.search
	local id = (args.id ~= '' and args.id) or nil
	local screenId = tostring (args.screenId)

	Debug.Trace ('Browse screen=', screenId, 'id=', tostring (id),
		'search=', tostring (search), 'filter=', tostring (args.search_filter),
		'start=', start, 'count=', count, 'nav=', tostring (navId), 'seq=', tostring (seq))

	-- Setup order matters: linking is the FIRST step (and it auto-discovers
	-- the server address), so the not-linked prompt must come before the
	-- no-address error. A fresh instance has neither host nor token, so
	-- checking host first would swallow the setup prompt entirely.
	if (not Plex.HasToken ()) then
		-- unlinked first open: a dialog routes the user to the Settings tab
		-- (its Go To Settings button deep-links there); rate limited so
		-- tab-hopping does not stack dialogs
		if (os.time () - gLastAutoLink >= 60) then
			gLastAutoLink = os.time ()
			sendEvent (navId, nil, 'DriverNotification',
				'<Id>AuthRequired</Id><Title>Plex Music setup</Title>'
				.. '<Message>Link your Plex account to start listening.</Message>')
		end
		dataError (idBinding, navId, seq, 'Plex account not linked - open the Settings tab to link your account')
		return
	end
	if (not Plex.HasHost ()) then
		dataError (idBinding, navId, seq, 'Finding your Plex server - this can take a moment, then try again')
		return
	end
	if (not Plex.IsConfigured ()) then
		dataError (idBinding, navId, seq, 'Linked - still finding your Plex server, try again in a moment')
		return
	end
	-- the Extras landing (no id) is a curated multi-section screen; drilling an
	-- album from it (id present) falls through to the normal container browse
	if (screenId == 'extras' and not id) then
		renderExtras (idBinding, navId, seq)
		return
	end
	-- Native search: the magnifier's filter tabs (track/album/artist/
	-- playlist) all point at this one screen, which fires with the typed
	-- query in `search` and the tab's filter id in `search_filter`. Each
	-- filter is a type-scoped Plex query, rendered by the normal builders.
	-- only the ROOT search (no id) runs a query here; drilling into a result
	-- (id present) falls through to the normal container browse below, so a
	-- tapped artist lists its albums instead of re-running an empty search
	if (screenId == 'searchlist' and not id) then
		local query = tostring (search or '')
		local filter = tostring (args.search_filter or 'track')
		if (query == '') then
			dataReceived (idBinding, navId, seq, '<List></List>')
			return
		end
		-- a section-scoped search (everything but playlists) needs the library
		-- loaded; without this guard an early search hits /library/sections/nil
		-- and returns a misleading "library may have changed" 404
		if (filter ~= 'playlist' and not gSectionKey) then
			dataError (idBinding, navId, seq, gSectionsLoaded
				and 'No music library found on the Plex server'
				or 'The music library is still loading - try again in a moment')
			return
		end
		pushSearchHistory (query)
		local cacheKey = 'search:' .. filter .. ':' .. query .. ':' .. start
		local function reply (container, err)
			if (not container) then
				dataError (idBinding, navId, seq, friendlyErr (err))
				return
			end
			local ok2, data2 = pcall (listFromContainer, cacheKey, container)
			if (not ok2) then
				dataError (idBinding, navId, seq, 'The Plex response could not be read')
				return
			end
			dataReceived (idBinding, navId, seq, data2)
		end
		if (filter == 'playlist') then
			-- /playlists has no server title filter; page all and match locally
			fetchAllPlaylists (function (container, perr)
				if (not container) then reply (nil, perr) return end
				local needle = query:lower ()
				local kept = {}
				for _, row in ipairs (container.children) do
					local title = tostring (row.attrs and row.attrs.title or ''):lower ()
					if (title:find (needle, 1, true)) then kept[#kept + 1] = row end
				end
				local page = {}
				for i = start + 1, math.min (#kept, start + count) do page[#page + 1] = kept [i] end
				reply ({tag = container.tag, attrs = {totalSize = tostring (#kept)}, children = page})
			end)
		else
			local mt = (filter == 'album' and Plex.TYPE_ALBUM)
				or (filter == 'artist' and Plex.TYPE_ARTIST) or Plex.TYPE_TRACK
			Plex.Search (gSectionKey, mt, query, start, count, reply)
		end
		return
	end
	-- Account-tab option pickers: plain lists writing the same properties
	-- Composer edits, so both sides stay in sync
	if (screenId == 'libraries') then
		local items = {'<item><title>Music Library</title><isHeader>true</isHeader></item>'}
		for _, s in ipairs (gSections) do
			local current = (s.key == gSectionKey) and '<subtitle>Current</subtitle>' or ''
			items[#items + 1] = '<item><title>' .. esc (s.title) .. '</title>' .. current
				.. '<id>' .. esc (s.title) .. '</id><itemType>setlibrary</itemType><nav>set</nav>'
				.. '<default_action>SelectItem</default_action></item>'
		end
		if (#items == 1) then
			items[1] = '<item><title>No music libraries found yet - try again in a moment</title><isHeader>true</isHeader></item>'
		end
		dataReceived (idBinding, navId, seq, '<List>' .. table.concat (items) .. '</List>')
		return
	end
	if (screenId == 'playback') then
		local opts = {'Transcode (MP3 320 kbps)', 'Transcode (MP3 192 kbps)',
			'Transcode (MP3 128 kbps)', 'Direct Play When Possible'}
		local active = tostring (Properties and Properties ['Playback'] or '')
		local items = {'<item><title>Playback Quality</title><isHeader>true</isHeader></item>'}
		for _, o in ipairs (opts) do
			local current = (o == active) and '<subtitle>Current</subtitle>' or ''
			items[#items + 1] = '<item><title>' .. esc (o) .. '</title>' .. current
				.. '<id>' .. esc (o) .. '</id><itemType>setplayback</itemType><nav>set</nav>'
				.. '<default_action>SelectItem</default_action></item>'
		end
		dataReceived (idBinding, navId, seq, '<List>' .. table.concat (items) .. '</List>')
		return
	end
	-- the playlists root needs no library section; everything else does.
	-- "No music library" is only claimed when a sections fetch has actually
	-- succeeded; before that the honest answer is a connection problem.
	if (not gSectionKey and not id and screenId ~= 'playlists') then
		if (gSectionsLoaded) then
			dataError (idBinding, navId, seq, 'No music library found on the Plex server')
		else
			dataError (idBinding, navId, seq, 'The music library is still loading - try again in a moment')
		end
		return
	end

	-- toptracks and similar are virtual sublists of one artist: they share
	-- the same id (the artist rk), so the itemType must be part of the key or
	-- they collide in both the browse cache and the playback context cache
	-- (whichever fetches first would serve the other, and empty tracks would
	-- poison a tapped row's context)
	local vType = VIRTUAL_ITEMTYPE [args.itemType] and (':' .. tostring (args.itemType)) or ''
	local cacheKey = (id or ('root:' .. screenId)) .. vType .. ':' .. start
	-- count is part of the reply cache key: Navigator classes use different
	-- page sizes, and serving one device's page length to another corrupts
	-- OFFSET pagination
	local browseKey = cacheKey .. ':' .. count .. '|' .. tostring (search or '')
	local cached = browseCacheGet (browseKey)
	if (cached) then
		dataReceived (idBinding, navId, seq, cached)
		return
	end
	-- a reply landing after a reconfigure must not seed the new config's
	-- cache with the old server's rows
	local cfgGen = gConnectGen

	-- artists/albums roots (unsearched) carry the A-Z scrubber map; it is
	-- fetched (or served from its own cache) before the page renders
	local wantAlpha = (not id) and (not (search and search ~= ''))
		and (screenId == 'artists' or screenId == 'albums') and gSectionKey

	-- an opened album/playlist gets Play All / Shuffle All header rows on page 1.
	-- (Artists are handled by renderArtistPage; discography/recent/etc. are
	-- VIRTUAL_ITEMTYPE and get no header.)
	local hdrOpts
	if (id and start == 0 and not VIRTUAL_ITEMTYPE [args.itemType]) then
		local ctype = tostring (args.itemType)
		if (ctype ~= 'album' and ctype ~= 'playlist') then
			ctype = (tostring (id):find ('^/playlists')) and 'playlist' or 'album'
		end
		hdrOpts = {header = {id = id, itemType = ctype}}
	elseif (id and start == 0 and args.itemType == 'toptracks') then
		-- Top Tracks is a playable track list, so it gets Play All / Shuffle All
		-- too; resolveItem knows how to turn the artist rk back into the tracks
		hdrOpts = {header = {id = id, itemType = 'toptracks'}}
	end

	local function reply (container, err)
		if (not container) then
			dataError (idBinding, navId, seq, friendlyErr (err))
			return
		end
		-- built under pcall: a malformed row must produce an error reply,
		-- never a Navigator spinning on a request nothing will answer
		local ok, data, tracks = pcall (listFromContainer, cacheKey, container, hdrOpts)
		if (not ok) then
			dataError (idBinding, navId, seq, 'The Plex response could not be read')
			return
		end
		local function finish (alphaXml)
			if (alphaXml and alphaXml ~= '') then data = data .. alphaXml end
			if (cfgGen == gConnectGen) then
				browseCachePut (browseKey, data, tracks, cacheKey)
			end
			dataReceived (idBinding, navId, seq, data)
		end
		if (wantAlpha) then
			local mediaType = (screenId == 'albums') and Plex.TYPE_ALBUM or Plex.TYPE_ARTIST
			alphaMapFor (gSectionKey, mediaType, finish)
		else
			finish ()
		end
	end

	if (id and args.itemType == 'toptracks') then
		-- the artist's popular tracks (modern agent); id is the artist rk
		Plex.PopularTracks (id, reply)
	elseif (id and args.itemType == 'similar') then
		-- in-library similar artists; id is the artist rk
		Plex.SimilarArtists (id, 24, reply)
	elseif (id and args.itemType == 'genres') then
		renderTagList ('genre', 'genrealbums', idBinding, navId, seq) -- the genre list
	elseif (id and args.itemType == 'decades') then
		renderTagList ('decade', 'decadealbums', idBinding, navId, seq) -- the decade list
	elseif (id and args.itemType == 'genrealbums') then
		-- albums in a tapped genre; id is the genre tag id
		Plex.SectionAll (gSectionKey, Plex.TYPE_ALBUM, start, count, {genre = tostring (id)}, reply)
	elseif (id and args.itemType == 'decadealbums') then
		-- albums in a tapped decade; id is the decade (e.g. 2020)
		Plex.SectionAll (gSectionKey, Plex.TYPE_ALBUM, start, count, {decade = tostring (id)}, reply)
	elseif (id and args.itemType == 'moods') then
		renderTagList ('mood', 'moodalbums', idBinding, navId, seq, CURATED_MOODS) -- curated mood list
	elseif (id and args.itemType == 'moodalbums') then
		-- albums tagged with a mood; id is the mood tag id
		Plex.SectionAll (gSectionKey, Plex.TYPE_ALBUM, start, count, {mood = tostring (id)}, reply)
	elseif (id and (args.itemType == 'recentplayed' or args.itemType == 'recentadded'
			or args.itemType == 'mostplayed')) then
		-- a single capped page of recently-played / recently-added / most-played
		-- albums; paginates within RECENT_CAP, then stops (no whole-library walk)
		local sort = (args.itemType == 'recentplayed' and 'lastViewedAt:desc')
			or (args.itemType == 'recentadded' and 'addedAt:desc') or 'viewCount:desc'
		if (start >= RECENT_CAP) then
			reply ({tag = 'MediaContainer', attrs = {totalSize = tostring (RECENT_CAP)}, children = {}})
		else
			local want = math.min (count, RECENT_CAP - start)
			Plex.SectionAll (gSectionKey, Plex.TYPE_ALBUM, start, want, {sort = sort}, function (c, err)
				if (c and c.attrs) then
					-- cap the declared length so the Navigator stops at RECENT_CAP
					c.attrs.totalSize = tostring (math.min (RECENT_CAP, tonumber (c.attrs.totalSize) or RECENT_CAP))
				end
				reply (c, err)
			end)
		end
	elseif (id and args.itemType == 'artist') then
		-- an opened artist: the compact menu page (not an inline album list).
		-- renderArtistPage validates the id itself (it must yield a numeric
		-- rating key) and re-checks every request the page can trigger, so a
		-- crafted id is rejected there rather than by the isBrowseKey gate below.
		renderArtistPage (idBinding, navId, seq, id)
	elseif (id) then
		-- drilling into a tapped container (album/playlist/discography); search
		-- within a drill is not supported (documented limitation). id becomes a
		-- request path, so it must be one of our own browse keys - reject a crafted value.
		if (not isBrowseKey (id)) then
			dataError (idBinding, navId, seq, friendlyErr ('invalid request path'))
			return
		end
		Plex.Children (id, start, count, reply)
	else
		browseRoot (screenId, start, count, search, reply)
	end
end

RFP.SelectItem = function (idBinding, strCommand, tParams, args)
	noteRoom (tParams)
	local navId, seq = tParams.NAVID, tParams.SEQ
	-- Account option picks: write the property both sides read, go back
	if (args.nav == 'set') then
		if (tostring (args.itemType) == 'setlibrary') then
			PersistData.libTitle = tostring (args.id or '')
			gConnectGen = gConnectGen + 1
			clearBrowseCaches ()
			pickSection ()
		elseif (tostring (args.itemType) == 'setplayback') then
			UpdateProperty ('Playback', tostring (args.id or ''), true)
		end
		dataReceived (idBinding, navId, seq, '<RemoveScreen>true</RemoveScreen>')
		return
	end
	-- the Play All / Shuffle All rows at the top of an opened container
	if (args.nav == 'station') then
		-- a tapped radio station: seed the queue from its first batch and let it
		-- refill as it plays. id is the station key.
		local room = validRooms (tParams.ROOMID) or gLastRoom
		playStation (tostring (args.id or ''), room, function (ok, reason)
			if (ok) then
				dataReceived (idBinding, navId, seq, '<NextScreen>#nowplaying</NextScreen>')
			else
				dataError (idBinding, navId, seq, playFailMsg (reason))
			end
		end)
		return
	end
	if (args.nav == 'playmix') then
		-- artist Play Mix (Plex Pass): id is the artist rk
		local room = validRooms (tParams.ROOMID) or gLastRoom
		playMix (tostring (args.id or ''), room, function (ok, reason)
			if (ok) then
				dataReceived (idBinding, navId, seq, '<NextScreen>#nowplaying</NextScreen>')
			else
				dataError (idBinding, navId, seq, playFailMsg (reason))
			end
		end)
		return
	end
	if (args.nav == 'playall' or args.nav == 'shuffleall') then
		local room = validRooms (tParams.ROOMID) or gLastRoom
		local wantShuffle = (args.nav == 'shuffleall')
		resolveItem (tostring (args.id or ''), tostring (args.itemType or 'album'), function (tracks, idx, err)
			if (not tracks or #tracks == 0) then
				dataError (idBinding, navId, seq, friendlyErr (err or 'no data'))
				return
			end
			local startIdx = wantShuffle and math.random (#tracks) or 1
			local ok, reason = playTracks (tracks, startIdx, room)
			if (ok) then
				if (wantShuffle and not gShuffle) then
					RFP.ToggleShuffle (idBinding, 'ToggleShuffle', {ROOMID = room})
				end
				dataReceived (idBinding, navId, seq, '<NextScreen>#nowplaying</NextScreen>')
			else
				dataError (idBinding, navId, seq, playFailMsg (reason))
			end
		end)
		return
	end
	if (args.nav == 'dir') then
		-- deeper into the same screen; Navigator re-issues Browse with the id
		dataReceived (idBinding, navId, seq, '<NextScreen>' .. esc (args.screenId or 'artists') .. '</NextScreen>')
		return
	end
	-- track tapped: play it in the context of the list it came from
	local room = validRooms (tParams.ROOMID) or gLastRoom
	resolveItem (tostring (args.id or ''), 'track', function (tracks, idx, err)
		if (not tracks or #tracks == 0) then
			dataError (idBinding, navId, seq, friendlyErr (err or 'no data'))
			return
		end
		local ok, reason = playTracks (tracks, idx, room)
		if (ok) then
			dataReceived (idBinding, navId, seq, '<NextScreen>#nowplaying</NextScreen>')
		else
			dataError (idBinding, navId, seq, playFailMsg (reason))
		end
	end)
end

-- Play Now / Add To Queue from the long-press action menu
RFP.PlayItem = function (idBinding, strCommand, tParams, args)
	noteRoom (tParams)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local room = validRooms (tParams.ROOMID) or gLastRoom
	local playType = tostring (args.playType or 'NOW')
	local itemType = tostring (args.itemType or 'track')
	if (playType == 'MIX') then
		-- Play Mix on an artist container: id is the artist container key or rk
		local rk = tostring (args.id or ''):match ('/library/metadata/(%d+)')
			or tostring (args.id or ''):match ('^%d+$')
		playMix (rk or '', room, function (ok, reason)
			if (ok) then
				dataReceived (idBinding, navId, seq, '<NextScreen>#nowplaying</NextScreen>')
			else
				dataError (idBinding, navId, seq, playFailMsg (reason))
			end
		end)
		return
	end
	resolveItem (tostring (args.id or ''), itemType, function (tracks, idx, err)
		if (not tracks or #tracks == 0) then
			dataError (idBinding, navId, seq, friendlyErr (err or 'no data'))
			return
		end
		local ok, reason
		if (playType == 'ADD' or playType == 'NEXT') then
			-- a single track queues just that track, not the album around it
			if (itemType == 'track') then
				tracks = {tracks [idx or 1]}
			end
			local added, started
			if (playType == 'NEXT') then
				ok, reason, added, started = playNext (tracks, room)
			else
				ok, reason, added, started = appendTracks (tracks, room)
			end
			if (ok and started and playType == 'NEXT') then
				-- Play Next on an empty/idle queue actually begins playback, and
				-- its intent is "play this now", so jump to Now Playing like Play
				-- Now. (Add To Queue keeps the user browsing even when the empty
				-- queue means the add starts playing; only the toast changes.)
				dataReceived (idBinding, navId, seq, '<NextScreen>#nowplaying</NextScreen>')
			elseif (ok) then
				-- queued (or an Add that started an idle queue): no screen change,
				-- so a single toast reflecting exactly how many landed (a full
				-- queue truncates). An Add that began playback says so plainly.
				local n = added or #tracks
				local verb
				if (playType == 'NEXT') then
					verb = (n > 1) and ('Playing ' .. n .. ' tracks next') or 'Playing next'
				elseif (started) then
					verb = (n > 1) and ('Playing ' .. n .. ' tracks now') or 'Playing now'
				else
					verb = (n > 1) and ('Added ' .. n .. ' tracks to the queue') or 'Added to the queue'
				end
				if (added and added < #tracks) then verb = verb .. ' (queue full)' end
				notifyUser ('Plex Music', verb)
				dataReceived (idBinding, navId, seq, '')
			else
				dataError (idBinding, navId, seq, playFailMsg (reason))
			end
		else
			local startIdx = idx or 1
			if (playType == 'SHUFFLE') then startIdx = math.random (#tracks) end
			ok, reason = playTracks (tracks, startIdx, room)
			if (ok) then
				if (playType == 'SHUFFLE' and not gShuffle) then
					RFP.ToggleShuffle (idBinding, 'ToggleShuffle', {ROOMID = room})
				end
				dataReceived (idBinding, navId, seq, '<NextScreen>#nowplaying</NextScreen>')
			else
				dataError (idBinding, navId, seq, playFailMsg (reason))
			end
		end
	end)
end

-- ---- favorites (pin to room) ----------------------------------------------

-- Favorite To Room: the action responds with a FavoriteResponse the Navigator
-- turns into a pinned tile. favoriteId encodes the Plex identity so recall can
-- rebuild the track list. Cover art is a plain URL (fav_art carried on the row).
RFP.Favorite = function (idBinding, strCommand, tParams, args)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local id = tostring (args.id or '')
	local itemType = tostring (args.itemType or '')
	local title = tostring (args.title or 'Plex')
	local art = tostring (args.fav_art or '')
	if (id == '' or itemType == '') then
		dataError (idBinding, navId, seq, 'Nothing to favorite')
		return
	end
	local img = (art ~= '') and ('<ImageUrl width="400" height="400">' .. esc (art) .. '</ImageUrl>') or ''
	dataReceived (idBinding, navId, seq,
		'<FavoriteResponse><Title>' .. esc (title) .. '</Title>' .. img
		.. '<Context><favoriteId>' .. esc (itemType .. '|' .. id) .. '</favoriteId></Context></FavoriteResponse>')
end

-- recall a pinned favorite: decode favoriteId -> resolve -> play into the room.
RFP.PlayFavorite = function (idBinding, strCommand, tParams, args)
	noteRoom (tParams)
	local navId, seq = tParams.NAVID, tParams.SEQ
	local room = validRooms (tParams.ROOMID) or gLastRoom
	local fav = tostring (args.favoriteId or args.id or '')
	local itemType, id = fav:match ('^([^|]*)|(.*)$')
	if (not itemType or itemType == '' or not id or id == '') then
		dataError (idBinding, navId, seq, 'That favorite is no longer available')
		return
	end
	-- solo=true: a pinned track plays just that track, the same way every time,
	-- rather than the whole album/playlist if it happens to still be cached
	resolveItem (id, itemType, function (tracks, idx, err)
		if (not tracks or #tracks == 0) then
			dataError (idBinding, navId, seq, friendlyErr (err or 'no data'))
			return
		end
		local ok, reason = playTracks (tracks, idx or 1, room)
		if (ok) then
			dataReceived (idBinding, navId, seq, '<NextScreen>#nowplaying</NextScreen>')
		else
			dataError (idBinding, navId, seq, playFailMsg (reason))
		end
	end, true)
end

-- ---- proxy commands: transport / now playing ------------------------------

RFP.SKIP_FWD = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	gEndStreak = 0 -- a deliberate user action earns a fresh failure budget
	local nx = nextIndex (gIndex)
	if (nx) then playIndex (nx, tParams.ROOMID or gRooms) end
end

RFP.SKIP_REV = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	gEndStreak = 0
	-- a few seconds in, "previous" means restart the current track
	if (gElapsedSec > 5 or gIndex <= 1) then
		playIndex (gIndex, tParams.ROOMID or gRooms)
	else
		playIndex (gIndex - 1, tParams.ROOMID or gRooms)
	end
end

-- PLAY / PAUSE / STOP are ROOM-typed transports: the room routes them to the
-- Digital Audio engine, which does the actual pause/resume/stop natively.
-- The driver must NOT re-send them to the room (that loops room -> proxy ->
-- room and floods Director into a restart). Faithful to the first-party
-- library, the handler only clears the pre-fetched next URL so a resume
-- rebuilds it; the pause itself is the engine's job.
local function clearNextArmed ()
	gNextArmed = nil
	if (validRooms (gRooms)) then
		C4:SendToProxy (MSP, 'SET_NEXT_AUDIO_URL', {
			ROOM_ID = gRooms, REPORT_ERRORS = true, QUEUE_INFO = '',
			FLAGS = 'driver=Plex Music', NEXT_URL = '',
		}, 'COMMAND')
	end
end

RFP.PLAY = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	gEndStreak = 0
	Debug.Info ('PLAY (room path drives the engine)')
	-- clear the prefetch on resume rather than re-arming it. Re-arming makes the
	-- next boundary gapless, but after a pause the engine's QUEUE_NEED_NEXT echoes
	-- the CURRENT (paused) track's queue-info, not the armed next, so the driver
	-- rejects the advance and Now Playing freezes on the finished track while
	-- audio moves on. Clearing routes the boundary through END -> re-SELECT, which
	-- advances reliably (at the cost of a brief gap on the first change post-pause).
	clearNextArmed ()
end
RFP.PAUSE = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	Debug.Info ('PAUSE (room path drives the engine)')
	clearNextArmed ()
end
RFP.STOP = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	Debug.Info ('STOP (room path drives the engine)')
	clearNextArmed ()
end

RFP.ToggleShuffle = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	local cur = currentTrack ()
	gSelectGen = gSelectGen + 1 -- either direction rearranges: old echoes die
	if (not gShuffle) then
		-- shuffle the remainder; the playing track moves to slot 1
		gUnshuffled = {}
		for i, t in ipairs (gQueue) do gUnshuffled [i] = t end
		local rest = {}
		for i, t in ipairs (gQueue) do
			if (i ~= gIndex) then rest[#rest + 1] = t end
		end
		for i = #rest, 2, -1 do
			local j = math.random (i)
			rest[i], rest[j] = rest[j], rest[i]
		end
		gQueue = {}
		if (cur) then gQueue [1] = cur end
		for _, t in ipairs (rest) do gQueue [#gQueue + 1] = t end
		gIndex = (cur and 1) or 0
		gShuffle = true
	else
		-- restore original order, keeping our place on the current track.
		-- Identity compare, not rk: the queue may hold the same track twice
		gQueue = gUnshuffled or gQueue
		gUnshuffled = nil
		gShuffle = false
		if (cur) then
			for i, t in ipairs (gQueue) do
				if (t == cur) then gIndex = i break end
			end
		end
	end
	persistQueue ()
	gNextArmed = nil
	armNext (true) -- force: the engine's armed next no longer matches our order
	pushAll ()
end

RFP.ToggleRepeat = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	gRepeat = not gRepeat
	persistQueue ()
	gNextArmed = nil
	armNext (true) -- force: the wrap point may have appeared or vanished
	pushAll ()
end

RFP.SHUFFLE_ON = function (b, c, tParams) if (not gShuffle) then RFP.ToggleShuffle (b, c, tParams) end end
RFP.SHUFFLE_OFF = function (b, c, tParams) if (gShuffle) then RFP.ToggleShuffle (b, c, tParams) end end
RFP.REPEAT_ON = function (b, c, tParams) if (not gRepeat) then RFP.ToggleRepeat (b, c, tParams) end end
RFP.REPEAT_OFF = function (b, c, tParams) if (gRepeat) then RFP.ToggleRepeat (b, c, tParams) end end

RFP.GetQueue = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	sendQueue (tParams.NAVID, tParams.ROOMID)
	sendProgress (tParams.NAVID, tParams.ROOMID)
end

RFP.GetDashboard = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	sendDashboard (tParams.NAVID, tParams.ROOMID)
end
RFP.GetDashBoard = RFP.GetDashboard -- proxy casing varies across OS versions

-- the Navigator asks for the current now-playing metadata on demand (e.g. when
-- the now-playing screen or media bar opens). The driver otherwise only PUSHES
-- media info on a PLAY transition, so an unanswered request leaves the screen
-- without title/artist/art. Answer with the current track, forcing a re-send.
RFP.REQUEST_CURRENT_MEDIA_INFO = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	gLast.info = nil -- a request must be answered even if unchanged since last push
	updateMediaInfo ()
end

-- seek within the current track: absolute/percent compute a target second,
-- relative offsets the driver clock; playback restarts at the target (the
-- transcode URL carries the offset, direct play rides the engine POSITION).
-- Seeks are coalesced through a short timer: each restart is a full engine
-- SELECT cycle, and a scrub gesture must land ONE select (the last target),
-- not a storm of them churning the await window. Consequence for relative
-- seeks: two SCANs inside one window compute from the same unmoved clock,
-- so they collapse to one 15s step rather than accumulating; deliberate.
RFP.SEEK = function (idBinding, strCommand, tParams)
	noteRoom (tParams)
	local t = currentTrack ()
	if (not t or t.durSec <= 0) then return end
	local pos = tonumber (tParams.POSITION)
	if (not pos) then return end
	local seekType = tostring (tParams.TYPE or 'absolute')
	local target
	if (seekType == 'relative') then target = gElapsedSec + pos
	elseif (seekType == 'percent') then target = t.durSec * pos / 100
	else target = pos end
	target = math.max (0, math.min (math.floor (target), math.max (0, t.durSec - 2)))
	local room = validRooms (tParams.ROOMID or tParams.ROOM_ID) or gRooms
	local idx = gIndex
	local tm = SetTimer ('c4plexSeek', 400, function ()
		-- fire only into a session that still exists: a same-index select
		-- cancels this timer in playIndex, and a deleted session (gQueueId
		-- gone) must not be resurrected by a stale scrub
		if (gIndex == idx and currentTrack () and gQueueId) then
			playIndex (idx, room, target)
		end
	end)
	if (not tm) then playIndex (idx, room, target) end
end
RFP.SCAN_FWD = function (b, c, tParams) RFP.SEEK (b, c, {ROOMID = tParams.ROOMID or tParams.ROOM_ID, POSITION = 15, TYPE = 'relative'}) end
RFP.SCAN_REV = function (b, c, tParams) RFP.SEEK (b, c, {ROOMID = tParams.ROOMID or tParams.ROOM_ID, POSITION = -15, TYPE = 'relative'}) end

-- ---- setup dialog + option pickers ----------------------------------------

-- the setup dialog's Set Up button: deep-link to the Settings tab
RFP.ConfirmAuthRequired = function (idBinding, strCommand, tParams)
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen tabId="settings">link</NextScreen>')
end

RFP.CancelAuthRequired = function (idBinding, strCommand, tParams)
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '')
end

-- the success/fault box's OK: land on the linked screen. The box is only shown
-- once the connect has resolved (server found, or a terminal fault), so the
-- linked screen's status is ready - "Linked to <name>" or the fault text.
RFP.LinkDone = function (idBinding, strCommand, tParams)
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen tabId="settings">linked</NextScreen>')
end

-- the code dialog's Close button: cancel a still-pending link. Leaving the
-- poll running would let the account link silently in the background (no
-- acknowledgment) and could pop a stale "account is linked" dialog later. A
-- token already obtained is left intact; this only stops an unfinished attempt.
RFP.DismissLink = function (idBinding, strCommand, tParams)
	if (tParams.NAVID) then gLinkNavs [tParams.NAVID] = nil end
	if (gLink) then endLinkFlow (nil, false) end -- clears gLink + cancels the pin poll
	-- endLinkFlow(nil,...) leaves the property showing the abandoned code; reset
	-- it to the real state so Composer does not keep displaying a dead link code
	setLinkStatus (Plex.HasToken () and 'Linked' or 'Not linked')
	gLinkDoneNavs = nil
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '')
end

RFP.ChooseLibrary = function (idBinding, strCommand, tParams)
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen>libraries</NextScreen>')
end

RFP.ChoosePlayback = function (idBinding, strCommand, tParams)
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen>playback</NextScreen>')
end

-- ---- search screens -------------------------------------------------------

-- the native search History block calls this (empty search box); return
-- recent queries as <item><name>..</name></item> per the History TextProperty
RFP.GetSearchHistory = function (idBinding, strCommand, tParams)
	local items = {}
	local hist = PersistData.searchHistory
	if (type (hist) == 'table') then
		for _, h in ipairs (hist) do
			items[#items + 1] = '<item><name>' .. esc (h) .. '</name></item>'
		end
	end
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<List>' .. table.concat (items) .. '</List>')
end

-- ---- account settings screens ---------------------------------------------

RFP.GetSettingsScreen = function (idBinding, strCommand, tParams)
	-- linked = has a token; the server address is a separate concern. While a
	-- fresh link is still finding its server the linked screen shows a
	-- "Linking, please wait..." status (see linkStatusText).
	local screen = Plex.HasToken () and 'linked' or 'link'
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<NextScreen>' .. screen .. '</NextScreen>')
end

local function linkStatusText ()
	if (Plex.HasToken ()) then
		if (gServerName ~= '') then return 'Linked to ' .. gServerName end
		if (gConnectFault) then return gConnectFault end
		return 'Linking, please wait...'
	end
	if (gLink and gLink.code) then
		return 'Visit plex.tv/link and enter code ' .. gLink.code
	end
	if (gLink and gLink.pending) then
		return 'Requesting a link code...'
	end
	if (gLinkErr) then
		return 'Link failed - ' .. gLinkErr
	end
	return 'Not linked - press Get Link Code'
end

RFP.GetLinkSettings = function (idBinding, strCommand, tParams)
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ,
		'<Settings><status>' .. esc (linkStatusText ()) .. '</status></Settings>')
end

RFP.StartLink = function (idBinding, strCommand, tParams)
	startLinkFlow (tParams.NAVID)
	-- the reply reflects the actual state: a fresh request, an outstanding
	-- code being re-announced, or already linked
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ,
		'<Settings><status>' .. esc (linkStatusText ()) .. '</status></Settings>')
end

RFP.Unlink = function (idBinding, strCommand, tParams)
	-- a still-outstanding code must die with the link: someone claiming it
	-- at plex.tv later must not silently re-link an unlinked driver
	endLinkFlow (nil, true)
	gLinkErr = nil
	UpdateProperty ('Plex Token', '', true)
	setLinkStatus ('Not linked')
	dataReceived (idBinding, tParams.NAVID, tParams.SEQ, '<ReplaceScreen>link</ReplaceScreen>')
end

-- ---- engine notifications -------------------------------------------------

-- Queue-id discipline: ids are adopted ONLY from AUDIO_URL_SELECTED (whose
-- echoed QUEUE_INFO must match the in-flight select) or from a PLAY state
-- transition (a dying queue never transitions to PLAY, so PLAY adopts even
-- an id previously marked dead: Director may reuse ids). Events from dead
-- queues, or from unknown queues while a live/awaited id exists, are
-- dropped. There is deliberately NO passing adoption from STOP/PAUSE/END/
-- NEED_NEXT/DELETED: adopting from those is how stale queues hijack state.
local function adoptOrFilterQueueId (tParams, canAdopt)
	local qid = tParams.QUEUE_ID and tostring (tParams.QUEUE_ID)
	if (not qid) then return true end -- no id on the event; caller decides
	if (qid == gQueueId) then return true end
	if (canAdopt) then
		closeAwaitWindow (qid)
		return true
	end
	-- dead ids were condemned by this driver on purpose; they are filtered
	-- BEFORE gen-proofing so a dead queue's stragglers can never be adopted
	if (gDeadQueueIds [qid]) then
		Debug.Trace ('event for dead queue', qid, 'ignored')
		return false
	end
	-- gen-proof recovery: with every id lost (driver reload, or a wrongly
	-- applied delete) and no select in flight, an event that echoes our
	-- CURRENT-generation QUEUE_INFO is provably ours: only this driver mints
	-- gen:idx values, and every select opens a fresh generation. Adopt its
	-- id so the session keeps advancing instead of going deaf until the
	-- next PLAY transition.
	if (not gQueueId and not gAwaitQueueId) then
		local gen, idx = parseQI (tParams.QUEUE_INFO)
		if (gen == gSelectGen and idx and gQueue [idx]) then
			Debug.Trace ('adopting queue', qid, 'via current-generation echo')
			closeAwaitWindow (qid)
			return true
		end
	end
	if (gQueueId) then
		Debug.Trace ('event for unknown queue', qid, 'ignored (live queue', tostring (gQueueId), ')')
		return false
	end
	-- no live id (awaiting, or post-error): a non-adoptable event from an
	-- unknown queue proves nothing about the session; drop it
	Debug.Trace ('event for queue', qid, 'ignored (no live queue id)')
	return false
end

RFP.QUEUE_STATE_CHANGED = function (idBinding, strCommand, tParams)
	local state = tostring (tParams.STATE or '')
	if (not adoptOrFilterQueueId (tParams, state == 'PLAY')) then return end
	Debug.Trace ('queue state', state)
	if (state == 'PLAY') then
		gPlayState = 'PLAY'
		gEndStreak = 0
		gLastPlayAt = os.time ()
		updateMediaInfo () -- re-send with QUEUEID once the id is known
		startTicker ()
	elseif (state == 'PAUSE') then
		gPlayState = 'PAUSE'
		stopTicker ()
		reportTimeline ('paused')
	elseif (state == 'STOP') then
		gPlayState = 'STOP'
		stopTicker ()
		reportTimeline ('stopped')
		sendProgress (nil, sessionRooms ())
	elseif (state == 'END') then
		-- the queue ran dry without a NEXT_URL armed (single track, repeat
		-- off at the end, or the arm failed): advance ourselves if possible.
		-- The streak counter stops an endless select/END loop when every
		-- stream fails (repeat wrap would otherwise cycle forever).
		gPlayState = 'STOP'
		stopTicker ()
		local nx = nextIndex (gIndex)
		if (nx) then
			gEndStreak = gEndStreak + 1
			if (gEndStreak <= math.min (#gQueue, END_STREAK_MAX)) then
				local ok, reason = playIndex (nx, gRooms)
				if (ok) then return end
				-- a failed auto-advance must not end the night silently;
				-- no-room stays quiet (nowhere to toast anyway)
				if (reason and reason ~= 'noroom') then
					notifyUser ('Plex Music', playFailMsg (reason))
				end
			else
				Debug.Error ('every stream ended without playing; stopping the auto-advance')
				notifyUser ('Plex Music', 'Playback stopped - the streams keep failing')
			end
		end
		reportTimeline ('stopped')
		sendProgress (nil, sessionRooms ())
	end
	sendDashboard (nil, sessionRooms ())
end

RFP.QUEUE_NEED_NEXT = function (idBinding, strCommand, tParams)
	if (not adoptOrFilterQueueId (tParams, false)) then return end
	-- The engine consumed a NEXT_URL: that track is now the current one.
	-- QUEUE_INFO echoes the "gen:index" this driver sent on the arm; a
	-- stale generation (pre-replace, pre-shuffle) is rejected outright.
	-- When gNextArmed is nil but the echo is current-generation and valid
	-- (the arm state was lost to a driver reload while the engine kept its
	-- URL), the echo is trusted: only this driver produces these values.
	local gen, echoed = parseQI (tParams.QUEUE_INFO)
	if (gen and gen ~= gSelectGen) then
		Debug.Trace ('QUEUE_NEED_NEXT from generation', gen, '(current', gSelectGen, '); ignoring')
		-- the engine really did advance on a pre-toggle arm; re-arm force so
		-- its next slot matches the current arrangement immediately
		if (gQueueId) then armNext (true) end
		return
	end
	local idx
	if (gNextArmed) then
		if (echoed and echoed ~= gNextArmed) then
			Debug.Trace ('stale QUEUE_NEED_NEXT for', echoed, '(armed', gNextArmed, '); ignoring')
			return
		end
		idx = gNextArmed
	elseif (echoed and gen and gQueue [echoed]) then
		idx = echoed
	else
		Debug.Trace ('QUEUE_NEED_NEXT with nothing armed and no usable echo; ignoring')
		return
	end
	gIndex = idx
	gNextArmed = nil
	gElapsedSec = 0
	persistQueue ()
	pushAll ()
	reportTimeline ('playing')
	armNext ()
	-- gapless advance runs here, NOT through playIndex, so a radio queue is
	-- refilled from this path as it nears its end (else it stops at the seed)
	maybeRefillRadio (gRooms)
end

-- apply a queue deletion: the session is over, the queue stays as a
-- resumable snapshot, and displays reflect the stopped state
-- (assigned to the forward declaration above the await-window lifecycle)
applyQueueDeleted = function ()
	Debug.Info ('queue deleted by Digital Audio')
	stopTicker ()
	gPlayState = 'STOP'
	gQueueId = nil
	gNextArmed = nil
	-- gElapsedSec deliberately kept: a falsely applied delete followed by a
	-- resume must not restart the progress clock mid-track; a real new
	-- select resets it in playIndex anyway
	gLast.info = nil -- a re-select of the same track must re-send media info
	reportTimeline ('stopped')
	pushAll ()
end

RFP.QUEUE_DELETED = function (idBinding, strCommand, tParams)
	-- During the await window this is usually Director tearing down the
	-- queue being replaced. It is not discarded outright: the rooms are
	-- remembered, and if the window times out with no adoption the deletion
	-- was real and gets applied then (see openAwaitWindow's timeout).
	if (gAwaitQueueId) then
		gPendingDeleteRooms = tostring (tParams.ROOMS or '')
		Debug.Trace ('queue deleted during select; deferred')
		return
	end
	if (not adoptOrFilterQueueId (tParams, false)) then return end
	-- QUEUE_DELETED carries no queue id in the documented set, but it does
	-- carry ROOMS: a deletion for rooms that share nothing with this session
	-- belongs to another queue
	local rooms = tostring (tParams.ROOMS or '')
	if (rooms ~= '' and gRooms ~= '' and not roomsOverlap (rooms, gRooms)) then
		Debug.Trace ('queue deleted for other rooms (', rooms, '); ignoring')
		return
	end
	-- Director tears the REPLACED queue down after confirming the new one;
	-- that deletion arrives id-less right after adoption and must not be
	-- read as the live session dying. It is DEFERRED, not dropped: if it was
	-- a genuine death (room off right after track start), no fresh adoption
	-- follows, and the delete applies when the grace expires.
	if (not tParams.QUEUE_ID and os.time () < gDeleteGraceUntil) then
		-- Discriminator at expiry: the delete is applied unless the session
		-- proved itself alive AND still claims to play. "PLAY arrived this
		-- adoption epoch" filters the replaced queue's teardown delete; the
		-- play-state term catches a genuine death AFTER that PLAY, where
		-- the engine's STOP has already dropped us out of PLAY. The one
		-- undetectable case (engine deletes a PLAYING queue with no STOP
		-- and no further events) is accepted and self-heals at the next
		-- engine event via gen-proof re-adoption.
		local serial = gAdoptSerial
		gGraceDeleteRooms = rooms
		Debug.Trace ('id-less delete within the post-adoption grace; deferred')
		local function decide ()
			gGraceDeleteRooms = nil
			if (gAdoptSerial ~= serial or not gQueueId) then return end
			if (gLastPlayAt >= gAdoptAt and gPlayState == 'PLAY') then return end
			Debug.Trace ('grace expired without proof of life; applying the deferred delete')
			applyQueueDeleted ()
		end
		-- one second past the grace window so the deferral test has surely expired
		local tm = SetTimer ('c4plexGraceDelete', (DELETE_GRACE_S + 1) * ONE_SECOND, decide)
		if (not tm) then decide () end
		return
	end
	applyQueueDeleted ()
end

RFP.QUEUE_STREAM_STATUS_CHANGED = function (idBinding, strCommand, tParams)
	-- filter like every other queue notification; a replaced queue's dying
	-- stream commonly reports an error that is not this session's problem
	if (tParams.QUEUE_ID and not adoptOrFilterQueueId (tParams, false)) then return end
	local status = scrubToken (tParams.STATUS or '')
	Debug.Trace ('stream status', status)
	if (status:find ('ERR', 1, true)) then
		if (gAwaitQueueId) then return end -- torn-down stream during a select
		-- during the post-adoption grace an id-less ERR is usually the
		-- replaced queue's stream being torn down, not the new track failing
		if (not tParams.QUEUE_ID and os.time () < gDeleteGraceUntil and gLastPlayAt < gAdoptAt) then
			return
		end
		if (os.time () - gLastStreamErrAt < 10) then return end -- rate limit
		gLastStreamErrAt = os.time ()
		local t = currentTrack ()
		notifyUser ('Plex Music', 'Stream error on ' .. tostring (t and t.title or 'current track'))
	end
end

RFP.AUDIO_URL_SELECTED = function (idBinding, strCommand, tParams)
	-- The engine's direct answer to a SELECT_AUDIO_URL. Only the ack for the
	-- CURRENT select may adopt: with two selects in flight, the first ack's
	-- echoed QUEUE_INFO no longer matches gSelectGen/gIndex and is ignored.
	-- An ack with no parsable echo only counts while a select is in flight.
	local gen, idx = parseQI (tParams.QUEUE_INFO)
	if (gen and (gen ~= gSelectGen or idx ~= gIndex)) then
		Debug.Trace ('stale select ack (', tostring (gen), ':', tostring (idx), '); ignoring')
		return
	end
	if (not gen and not gAwaitQueueId) then
		Debug.Trace ('uncorrelated select ack with no select in flight; ignoring')
		return
	end
	if (tParams.QUEUE_ID) then
		closeAwaitWindow (tostring (tParams.QUEUE_ID))
		updateMediaInfo () -- re-send with QUEUEID attached
	end
	Debug.Trace ('url selected, queue', tostring (gQueueId))
end
RFP.INTERNET_RADIO_SELECTED = RFP.AUDIO_URL_SELECTED

local function selectError (idBinding, strCommand, tParams)
	-- The SELECT failed: nothing will answer the await window. Correlate
	-- first: an error echoing a stale gen:idx belongs to a superseded
	-- select, and an uncorrelated error with no select in flight is late
	-- noise; both must not disturb (or toast over) the live session.
	local gen, idx = parseQI (tParams and tParams.QUEUE_INFO)
	if (gen and (gen ~= gSelectGen or idx ~= gIndex)) then
		Debug.Trace ('stale select error (', tostring (gen), ':', tostring (idx), '); ignoring')
		return
	end
	if (not gen and not gAwaitQueueId) then
		Debug.Trace ('uncorrelated select error with no select in flight; ignoring')
		return
	end
	if (gen and not gAwaitQueueId) then
		if (not gSelectSentThisSession) then
			-- correlated but the window is gone AND no select was sent since
			-- this driver instance started: a reload happened mid-select
			-- (gen/gIndex were persisted before the failure). There is no
			-- restore target and the tap is long past; recover quietly.
			Debug.Warn ('select error after reload; clearing the arm quietly')
			gNextArmed = nil
			return
		end
		-- the window timed out before this late failure arrived: the user
		-- deserves the toast, and the arm sent with the failed select must
		-- not stand against whatever the timeout restored
		Debug.Error ('late SELECT_AUDIO_URL error:', scrubToken (tParams and tParams.ERROR))
		notifyUser ('Plex Music', 'Control4 could not start the stream')
		gNextArmed = nil
		armNext (true)
		return
	end
	-- The displaced queue may well still be playing (the engine rejected the
	-- replacement), so restore it as the live id instead of leaving its
	-- events filtered, and clear the next-arm sent alongside the failed
	-- select. If a deletion for our rooms was deferred into the window, the
	-- displaced queue is genuinely dead: apply the stop instead of restoring
	-- an id the engine already destroyed.
	local restore = gReplacedQueueId
	local pendingDelete = gPendingDeleteRooms
	closeAwaitWindow (nil)
	Debug.Error ('SELECT_AUDIO_URL error:', scrubToken (tParams and tParams.ERROR))
	notifyUser ('Plex Music', 'Control4 could not start the stream')
	if (pendingDelete and (pendingDelete == '' or gRooms == ''
			or roomsOverlap (pendingDelete, gRooms))) then
		applyQueueDeleted ()
		return
	end
	if (restore) then
		gDeadQueueIds [restore] = nil
		gQueueId = restore
	end
	gNextArmed = nil
	armNext (true) -- explicit clear/re-arm against whatever is actually live
end
RFP.SELECT_AUDIO_URL_ERROR = selectError
RFP.SELECT_INTERNET_RADIO_ERROR = selectError

RFP.DEVICE_SELECTED = function (idBinding, strCommand, tParams)
	-- the documented param here is idRoom (not ROOMID); LOCATION is a
	-- favorites path, never a room id, so it is deliberately not read
	local r = validRooms (tParams.idRoom) or validRooms (tParams.ROOMID or tParams.ROOM_ID)
	if (r) then gLastRoom = r end
	Debug.Trace ('device selected in room', tostring (gLastRoom))
end

RFP.DEVICE_DESELECTED = function (idBinding, strCommand, tParams)
	Debug.Trace ('device deselected')
end

local function destroyNav () end
RFP.DESTROY_NAV = destroyNav
RFP.DESTROY_NAVIGATOR = destroyNav

-- ---- server connection ----------------------------------------------------

local function setStatus (s)
	UpdateProperty ('Server Status', tostring (s))
end

-- fire the deferred "your account is linked" dialog once the connect that a
-- fresh link kicked off has actually resolved. Held until now (rather than
-- fired the instant the token lands) so the dialog's OK carries the user
-- straight to the finished "linked" screen instead of a buttonless "Linking,
-- please wait..." that an open settings screen will not refresh on its own.
-- No-op unless a link is waiting, so ordinary reconnects never trigger it.
local function fireLinkDone (isFault)
	if (not gLinkDoneNavs) then return end
	local navs = gLinkDoneNavs
	gLinkDoneNavs = nil
	closeLinkDialog () -- dismiss the "Linking, please wait..." progress box first
	local msg = isFault
		and 'Your account is linked, but the Plex server could not be reached yet. Press OK to review.'
		or 'Your account is linked and your server is ready. Press OK to finish.'
	for _, nav in ipairs (navs) do
		sendEvent ((nav ~= '*') and nav or nil, nil, 'DriverNotification',
			'<Id>LinkDone</Id><Title>Plex account linked</Title><Message>' .. esc (msg) .. '</Message>')
	end
end

-- a terminal connect failure: shows on the Composer Server Status property AND
-- replaces the transient "Linking, please wait..." text in the Navigator so a
-- linked-but-unreachable server does not spin forever
local function setFault (s)
	gConnectFault = tostring (s)
	setStatus (s)
	fireLinkDone (true) -- a link waiting on this connect gets its dialog now
end

-- commas would split a title into bogus dropdown entries; control chars and
-- absurd lengths have no business in a Composer property list either
local function cleanTitle (s)
	return (tostring (s or ''):gsub ('[%c,]', ' '):sub (1, 64))
end

-- write the Music Library display property unconditionally: the mirror in
-- UpdateProperty can go stale around UpdatePropertyList, so the change-check
-- there is not trustworthy for this one property
local function showLibrary (title)
	pcall (function ()
		C4:UpdateProperty ('Music Library', tostring (title or ''))
		if (Properties) then Properties ['Music Library'] = tostring (title or '') end
	end)
end

-- (assigned to the forward declaration above the setup/picker handlers)
-- optional Composer feature: rename the device "<ServerName> - <LibraryName>"
-- so a multi-instance / multi-library setup is self-labeling. Off by default;
-- re-applied whenever the server name or the selected library changes.
local function applyAutoRename ()
	if (tostring (Properties and Properties ['Auto Rename Driver'] or 'Off') ~= 'On') then return end
	local server = tostring (gServerName or '')
	if (server == '') then return end -- wait until the server name is known
	local lib
	for _, s in ipairs (gSections) do
		if (s.key == gSectionKey) then lib = s.title break end
	end
	lib = lib or tostring (PersistData.libTitle or '')
	local name = (lib ~= '') and (server .. ' - ' .. lib) or server
	-- ComposerPro (and Navigator) show the PROXY device, not the driver's
	-- protocol device; renaming C4:GetDeviceID() is a no-op. C4:GetProxyDevices()
	-- returns the proxy id (a number for this single-proxy driver). Fall back to
	-- the driver id if it can't be resolved. (Safe post-init; not called in OnDriverInit.)
	local pd = C4:GetProxyDevices ()
	local target = tonumber (pd)
	if (not target and type (pd) == 'table') then
		target = tonumber (pd [MSP] or pd [tostring (MSP)])
		if (not target) then
			for _, v in pairs (pd) do if (tonumber (v)) then target = tonumber (v) break end end
		end
	end
	target = target or C4:GetDeviceID ()
	pcall (function () C4:RenameDevice (target, name) end)
end

pickSection = function ()
	-- prefer the persisted selection; fall back to the first music section
	local want = PersistData.libTitle
	gSectionKey = nil
	for _, s in ipairs (gSections) do
		if (want and s.title == want) then
			gSectionKey = s.key
			break
		end
	end
	if (not gSectionKey and gSections [1]) then
		-- fall back to the first section WITHOUT overwriting a stored pick:
		-- a section transiently missing from one fetch must not permanently
		-- lose the user's choice
		gSectionKey = gSections [1].key
		if (not PersistData.libTitle) then
			PersistData.libTitle = gSections [1].title
		end
	end
	if (#gSections == 0 and gSectionsLoaded) then
		-- only a SUCCESSFUL fetch proving zero sections clears the stored
		-- pick; a pick made during an outage must survive the reconnect
		PersistData.libTitle = nil
	end
	-- gate Top Tracks / Similar Artists on the selected section's agent
	gModernAgent = false
	for _, s in ipairs (gSections) do
		if (s.key == gSectionKey and s.agent == 'tv.plex.agents.music') then
			gModernAgent = true
			break
		end
	end
	-- display the ACTIVE library, which may be the fallback: the stored pick
	-- survives for later restoration, but the property must not claim a
	-- library that browse is not actually serving
	local active
	for _, s in ipairs (gSections) do
		if (s.key == gSectionKey) then active = s.title break end
	end
	showLibrary (active or PersistData.libTitle)
	applyAutoRename () -- the active library just resolved/changed
end

local function refreshSections ()
	local gen = gConnectGen
	Plex.MusicSections (function (sections, err)
		if (gen ~= gConnectGen) then return end -- config changed mid-flight
		if (not sections) then
			setStatus ('Library list failed: ' .. friendlyErr (err))
			return
		end
		-- a hostile/broken server could return a huge section list; keep a sane
		-- prefix so the dropdown and alpha cache stay bounded like every other
		-- server-fed structure
		for i = #sections, SECTIONS_MAX + 1, -1 do sections[i] = nil end
		for _, s in ipairs (sections) do s.title = cleanTitle (s.title) end
		gSections = sections
		gSectionsLoaded = true
		local titles = {}
		for _, s in ipairs (sections) do titles[#titles + 1] = s.title end
		C4:UpdatePropertyList ('Music Library', ',' .. table.concat (titles, ','))
		pickSection ()
		if (#sections == 0) then
			setStatus ('Connected, but no music library on this server')
		end
	end)
end

-- Property edits and startup can fire connect() repeatedly with the async
-- Ping/ServerInfo/sections chain mid-flight; the generation counter makes
-- every stale callback drop out instead of writing an old config's results
-- over a new one's.
-- RFC1918 private IPv4 test, for LAN-only server auto-discovery: the token
-- travels to the server over plain http, so only a private address is ever
-- auto-adopted (a public/WAN server must be entered by hand in Composer).
local function isPrivateV4 (addr)
	local a, b = tostring (addr):match ('^(%d+)%.(%d+)%.')
	a, b = tonumber (a), tonumber (b)
	if (not a) then return false end
	if (a == 10) then return true end
	if (a == 192 and b == 168) then return true end
	if (a == 172 and b >= 16 and b <= 31) then return true end
	return false
end

local function connect ()
	gConnectGen = gConnectGen + 1
	local gen = gConnectGen
	local addr = tostring (Properties ['Plex Server Address'] or '')
	local port = tostring (Properties ['Plex Server Port'] or '32400')
	-- the real token lives in PersistData once masked; the property only ever
	-- shows the mask or a freshly-typed value
	local prop = tostring (Properties ['Plex Token'] or '')
	local token = (prop == TOKEN_MASK or prop == '') and tostring (PersistData.plexToken or '') or prop
	-- the C4 driver device id is a stable per-install client identifier
	Plex.Configure (addr, port, token, 'c4plex-' .. tostring (C4:GetDeviceID ()))
	gServerLabel = ''
	gServerName = ''
	gConnectFault = nil
	UpdateProperty ('Server', '')
	-- library state belongs to the PREVIOUS configuration; a section key
	-- from server A must never be queried against server B, and A's titles
	-- must not stay pickable in the dropdown while B connects
	gSections = {}
	gSectionKey = nil
	gSectionsLoaded = false
	clearBrowseCaches () -- cached pages belong to the previous configuration
	pcall (function () C4:UpdatePropertyList ('Music Library', ',') end)
	showLibrary ('') -- the old server's title must not sit over an empty list
	-- keep the Account Link property honest alongside the connection state;
	-- linked means "has a token", independent of the server address
	if (Plex.HasToken ()) then
		setLinkStatus ('Linked')
	elseif (not gLink) then
		setLinkStatus ('Not linked')
	end
	if (not Plex.HasHost ()) then
		-- Navigator-side setup: a linked account with no address yet gets
		-- the address discovered from plex.tv's server list, so the whole
		-- flow works without touching Composer. The property writes below
		-- re-enter connect() with the discovered server. Once per config
		-- generation: a failed discovery must not loop.
		if (addr == '' and Plex.HasToken () and gDiscoverGen ~= gConnectGen) then
			gDiscoverGen = gConnectGen
			setStatus ('Linked - finding your Plex server...')
			Plex.TvResources (function (list, derr)
				if (gen ~= gConnectGen) then return end
				if (not list or #list == 0) then
					setFault ('Linked, but no Plex server was found on your network - it may need manual setup')
					Debug.Warn ('server discovery failed:', tostring (derr))
					return
				end
				-- plex.tv can advertise addresses the controller cannot
				-- reach (a Docker bridge address like 172.17.0.1 when the
				-- server runs in a container). Probe candidates in order,
				-- isLocal-flagged first, and keep the first that answers
				-- /identity. Auto-discovery is restricted to private (RFC1918)
				-- addresses: the account token is sent to the server over plain
				-- http, so it must never auto-flow to a public address. A
				-- WAN-only server is configured by hand in Composer instead.
				local ordered, seen = {}, {}
				for pass = 1, 2 do
					for _, c in ipairs (list) do
						local key = c.address .. ':' .. c.port
						if (not seen [key] and isPrivateV4 (c.address)
								and ((pass == 1) == (c.isLocal == true))) then
							seen [key] = true
							ordered[#ordered + 1] = c
						end
					end
				end
				local i = 0
				local function tryNext ()
					i = i + 1
					local cand = ordered [i]
					if (not cand) then
						setFault ('Linked, but the Plex server could not be reached on your network - it may need manual setup')
						return
					end
					if (gen ~= gConnectGen) then return end
					Debug.Info ('probing discovered address', cand.address, ':', cand.port)
					Plex.ProbeIdentity (cand.address, cand.port, function (mid)
						if (gen ~= gConnectGen) then return end
						if (mid) then
							Debug.Info ('discovered Plex server at', cand.address, ':', cand.port)
							UpdateProperty ('Plex Server Port', tostring (cand.port))
							UpdateProperty ('Plex Server Address', cand.address, true)
						else
							tryNext ()
						end
					end)
				end
				tryNext ()
			end)
			return
		end
		-- setFault (not setStatus) so this terminal state shows on the Navigator
		-- and resolves any code box a fresh link left waiting on this connect
		setFault ((addr ~= '') and 'The server address looks invalid' or 'Not Configured')
		return
	end
	setStatus ('Connecting...')
	Plex.Ping (function (attrs, err)
		if (gen ~= gConnectGen) then return end
		if (not attrs) then
			err = tostring (err)
			if (err == 'not a Plex server') then
				setFault ('The address answered, but it does not look like a Plex server')
			elseif (err:find ('^HTTP')) then
				setFault ('The address answered with an error (' .. err .. ') - check the port')
			elseif (err == 'request failed to start' or err == 'C4:url unavailable') then
				setFault ('The controller could not open a network request')
			else
				setFault ('Server unreachable: ' .. friendlyErr (err))
			end
			return
		end
		if (not Plex.IsConfigured ()) then
			setStatus ('Server found - Plex token needed')
			fireLinkDone (true) -- resolve a waiting code box (no-op if none)
			return
		end
		Plex.ServerInfo (function (info, err2)
			if (gen ~= gConnectGen) then return end
			if (not info) then
				-- only claim a token problem when the server actually said so
				if (err2 == 'unauthorized') then
					setFault ('Connected, but the token was rejected')
				else
					setFault ('Server error: ' .. friendlyErr (err2))
				end
				return
			end
			-- a blank friendlyName must not surface the raw server IP to the
			-- Navigator ("Linked to 10.x.x.x"); a generic label keeps this
			-- non-empty (the connected-state signal) without leaking the address
			gServerName = (cleanTitle (info.friendlyName) ~= '' and cleanTitle (info.friendlyName) or 'your Plex server')
			gConnectFault = nil
			gServerLabel = gServerName
				.. ' (Plex ' .. cleanTitle (info.version or '?') .. ') at ' .. Plex.Endpoint ()
			-- Plex Pass gate for Play Mix; detected silently from the server
			-- root, no user prompt. Drop any pages cached during this fetch:
			-- they were built with the default gPlexPass=false and would show
			-- artist rows without the Play Mix action until their TTL expired.
			local hadPass = gPlexPass
			gPlexPass = (tostring (info.myPlexSubscription) == '1')
			if (gPlexPass ~= hadPass) then clearBrowseCaches () end
			UpdateProperty ('Server', gServerLabel)
			setStatus ('Connected')
			fireLinkDone (false) -- server found: a waiting link gets its dialog
			refreshSections ()
		end)
	end)
end

-- ---- properties / actions -------------------------------------------------

OPC.Plex_Server_Address = connect
OPC.Plex_Server_Port = connect
-- Token masking: the token is secret, so the Composer property must not
-- display it. A freshly entered (or link-obtained) token is stashed in
-- PersistData and the visible property is replaced with a fixed mask; a
-- blank clears it. connect() reads the real token from PersistData.
OPC.Plex_Token = function (value)
	value = tostring (value or '')
	if (value == TOKEN_MASK) then
		-- our own mask write; the stored token is unchanged
		connect ()
		return
	end
	if (value == '') then
		PersistData.plexToken = nil
	else
		PersistData.plexToken = value
		-- replace the visible value with the mask (only when there is
		-- something to hide)
		UpdateProperty ('Plex Token', TOKEN_MASK)
	end
	connect ()
end

OPC.Music_Library = function (value)
	if (value == '') then
		-- the blank list entry is not a selection; re-run the pick so the
		-- display shows the ACTIVE library (which may be the fallback)
		pickSection ()
		return
	end
	PersistData.libTitle = value
	-- the connect generation doubles as the cache epoch: bumping it makes an
	-- in-flight old-section reply skip its cache write instead of reseeding
	gConnectGen = gConnectGen + 1
	clearBrowseCaches () -- cached pages and alpha maps belong to the old section
	pickSection ()
end

OPC.Auto_Rename_Driver = function () applyAutoRename () end -- apply on toggle-on

OPC.Playback = function ()
	-- an armed next URL was built with the old mode/bitrate; re-arm so the
	-- upcoming track honors the new setting
	if (gPlayState == 'PLAY') then armNext (true) end
end

EC.TestConnection = function () connect () end
EC.RefreshLibraries = function ()
	clearBrowseCaches () -- a manual refresh means "the library changed"
	refreshSections ()
end
EC.LinkPlexAccount = function () startLinkFlow (nil) end

-- clear the stored address and re-run discovery (probe-based): the way out
-- when a previous discovery stored an unreachable address
EC.RediscoverServer = function ()
	UpdateProperty ('Plex Server Address', '', true)
end

-- ---- lifecycle ------------------------------------------------------------

-- log every command the proxy sends us (transport, browse, select,
-- settings, engine notifications), so a debug capture shows the full flow
RFP_TRACE = function (binding, command, params)
	if (not Debug.Wants (4)) then return end
	local a = params and params.ARGS
	Debug.Trace ('<= proxy', tostring (command),
		'bind=', tostring (binding),
		'room=', tostring (params and (params.ROOMID or params.ROOM_ID)),
		'nav=', tostring (params and params.NAVID),
		'state=', tostring (params and params.STATE),
		a and ('args=' .. tostring (a)) or '')
end

-- token redaction hook for c4handlers' error path (see its dispatch): the shared
-- module cannot see the driver's scrubber directly, so expose it as a global
SCRUB = scrubToken

-- ---- opt-in GitHub update check (default Off) ------------------------------
-- When On, one HTTPS GET per day to api.github.com for the latest release, and
-- the result is shown as a suffix on Driver Version. Nothing about the system is
-- sent and nothing is downloaded. Ported from openhac4; works only against a
-- public repo (404 while private). The token is never involved here.
local UPDATE_API = 'https://api.github.com/repos/cajunflavoredbob/c4plex-music/releases/latest'
local UPDATE_RELEASES = 'https://github.com/cajunflavoredbob/c4plex-music/releases'
local UPDATE_UA = 'c4plex-music' -- static, non-identifying User-Agent (Rule Zero)
local gUpdateStatus -- suffix after the version in Driver Version, or nil

local function jsonDecode (s)
	local ok, t = pcall (function () return C4:JsonDecode (s) end)
	return (ok and type (t) == 'table') and t or nil
end

local function driverSemver ()
	local semver
	pcall (function () semver = C4:GetDriverConfigInfo ('semver') end)
	if (not semver or semver == '') then
		pcall (function () semver = tostring (C4:GetDriverConfigInfo ('version')) end)
	end
	return tostring (semver or '')
end

local function showDriverVersion ()
	UpdateProperty ('Driver Version', driverSemver () .. (gUpdateStatus or ''))
end

-- true when remote x.y.z is strictly newer than current, compared component-wise
local function isNewerVersion (remote, current)
	local r = {remote:match ('^(%d+)%.(%d+)%.(%d+)')}
	local c = {current:match ('^(%d+)%.(%d+)%.(%d+)')}
	if (#r < 3 or #c < 3) then return false end
	for i = 1, 3 do
		local rn, cn = tonumber (r [i]), tonumber (c [i])
		if (rn > cn) then return true end
		if (rn < cn) then return false end
	end
	return false
end

local function checkForUpdate ()
	if (Properties ['Check for Updates'] ~= 'On') then return end
	-- pcall guards a controller whose firmware lacks C4:urlGet
	local ok = pcall (function ()
		C4:urlGet (UPDATE_API, {
			['User-Agent'] = UPDATE_UA, -- api.github.com rejects a UA-less request
			['Accept'] = 'application/vnd.github+json',
		}, false, function (ticket, data, responseCode)
			-- a reply landing after the operator turned the check off: discard
			if (Properties ['Check for Updates'] ~= 'On') then return end
			local tag
			if (responseCode == 200 and type (data) == 'string') then
				local msg = jsonDecode (data)
				tag = msg and type (msg.tag_name) == 'string'
					and msg.tag_name:gsub ('^v', '') or nil
			end
			if (not tag) then
				gUpdateStatus = ' (Update check failed)'
				Debug.Warn ('update check failed: HTTP', tostring (responseCode))
			elseif (isNewerVersion (tag, driverSemver ())) then
				gUpdateStatus = ' (Update available: ' .. tag .. ')'
				Debug.Info ('update available:', tag, '- download from', UPDATE_RELEASES)
			else
				gUpdateStatus = ' (Up to Date)'
			end
			showDriverVersion ()
		end)
	end)
	if (not ok) then
		gUpdateStatus = ' (Update check unavailable)'
		showDriverVersion ()
	end
end

-- enable: immediate check + daily repeat; disable: cancel, restore plain version
local function armUpdateCheck ()
	if (Properties ['Check for Updates'] == 'On') then
		checkForUpdate ()
		SetTimer ('UpdateCheck', ONE_DAY, checkForUpdate, true)
	else
		CancelTimer ('UpdateCheck')
		gUpdateStatus = nil
		showDriverVersion ()
	end
end

OPC.Check_for_Updates = function ()
	armUpdateCheck ()
end

function OnDriverInit ()
	PersistData = PersistData or {}
	math.randomseed (os.time ())
end

function OnDriverLateInit ()
	Debug.SyncFromProperties ()
	-- show the plain version immediately, then arm the opt-in update check (a
	-- saved On survives reloads and re-checks; Off just leaves the plain version)
	showDriverVersion ()
	armUpdateCheck ()
	-- DYNAMIC_LIST declares no default, so its Properties slot may be nil,
	-- which would silently disable UpdateProperty's guard for it
	if (Properties and Properties ['Music Library'] == nil) then
		Properties ['Music Library'] = ''
	end
	-- a token stored from a prior session must display as the mask, not be
	-- re-shown in the clear (and a leftover plaintext token in the property
	-- gets absorbed into PersistData and masked)
	local prop = tostring (Properties and Properties ['Plex Token'] or '')
	if (prop ~= '' and prop ~= TOKEN_MASK) then
		PersistData.plexToken = prop
		UpdateProperty ('Plex Token', TOKEN_MASK)
	elseif (PersistData.plexToken and prop ~= TOKEN_MASK) then
		UpdateProperty ('Plex Token', TOKEN_MASK)
	end
	restoreQueue ()
	connect ()
end

function OnDriverDestroyed ()
	KillAllTimers ()
end
