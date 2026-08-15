-- c4plex Plex Media Server HTTP client
-- Copyright (c) 2026 cajunflavoredbob. Licensed under the MIT License.
--
-- Thin async client over the Control4 C4:url() API for the slice of the Plex
-- server API a music source needs: identity ping, library sections, browse,
-- search, playlists, and stream/artwork URL construction. Everything is plain
-- HTTP GET against a LAN server with an X-Plex-Token; responses are XML and
-- parsed with C4:ParseXml into a flat {attrs, children} shape.
--
-- The Plex server API has no official public reference; this module is written
-- from the community OpenAPI spec (github.com/LukeHagar/plex-api-spec),
-- Plexopedia, and the python-plexapi source.

local Debug = require ('c4plex.debug')

local Plex = {}

-- connection config; Configure() fills these from driver properties
local gHost, gPort, gToken = nil, 32400, nil
-- stable per-install identifier; per-track transcode sessions are derived
-- from it (see TranscodeUrl)
local gClientId = 'c4plex-unconfigured'
local gMachineId = '' -- server machineIdentifier, learned from ServerInfo; needed
                      -- to build the station play-queue uri

local REQUEST_TIMEOUT_S = 15

-- hostile-response budgets: a server that ignores the container-size params
-- must not balloon the driver's Lua state
local MAX_BODY_BYTES = 4 * 1024 * 1024
local MAX_XML_DEPTH = 16
local MAX_XML_NODES = 20000
local MAX_ATTR_CHARS = 1024

-- media type integers used in section type= filters. The community spec's
-- MediaType schema block claims 5/6/7 here; that block is wrong. 8/9/10 is
-- what real servers use (python-plexapi SEARCHTYPES, Plexopedia, and the
-- spec's own /library/sections description agree).
Plex.TYPE_ARTIST = 8
Plex.TYPE_ALBUM = 9
Plex.TYPE_TRACK = 10

local function trim (s)
	return (tostring (s or ''):gsub ('^%s+', ''):gsub ('%s+$', ''))
end

function Plex.Configure (host, port, token, clientId)
	-- clean a pasted address: trim, strip an accidental scheme, and accept a
	-- host:port form (the port in the address wins over the port property,
	-- since address:port is exactly what people copy out of a browser bar)
	host = trim (host):gsub ('^[hH][tT][tT][pP][sS]?://', ''):gsub ('/+$', '')
	gPort = tonumber (port) or 32400
	local h, p = host:match ('^(.+):(%d+)$')
	if (h and not h:find (':')) then
		p = tonumber (p)
		if (p and p >= 1 and p <= 65535) then
			host = h
			gPort = p
		else
			host = '' -- out-of-range embedded port: reject the whole address
		end
	end
	-- reject anything that could corrupt the URL authority or query: control
	-- chars, whitespace, path/query/fragment/userinfo characters, and a
	-- remaining ':' (an unbracketed IPv6 literal cannot form a valid URL here)
	gHost = (host ~= '' and not host:find ('[%c%s/@?#:]')) and host or nil
	gToken = trim (token)
	if (gToken == '') then gToken = nil end
	clientId = trim (clientId)
	if (clientId ~= '') then gClientId = clientId end
end

function Plex.IsConfigured ()
	return (gHost ~= nil and gToken ~= nil)
end

function Plex.HasHost ()
	return (gHost ~= nil)
end

-- account-link state must key off the token alone: a token obtained before
-- the server address is entered is still a valid link
function Plex.HasToken ()
	return (gToken ~= nil)
end

-- the effective target after address parsing; an embedded host:port wins
-- over the port property, so the UI must be able to show what is in use
function Plex.Endpoint ()
	if (not gHost) then return '' end
	return gHost .. ':' .. tostring (gPort)
end

-- RFC 3986 escaping. Plex 400s on an unencoded path= value, and titles with
-- '&' or '#' would silently truncate the query, so everything outside the
-- unreserved set is escaped.
local function urlencode (s)
	return (tostring (s or ''):gsub ('[^%w%-%._~]', function (c)
		return string.format ('%%%02X', string.byte (c))
	end))
end
Plex.UrlEncode = urlencode

-- the token must never reach a log line, even inside a transport error
-- message that may echo the failing URL
local function scrub (s)
	return (tostring (s or ''):gsub ('X%-Plex%-Token=[^&%s]*', 'X-Plex-Token=REDACTED'))
end

-- Server-supplied paths (Directory/Playlist/Part keys, thumb attributes) are
-- attacker-influenced. Anything that does not look like a plain absolute
-- path is rejected so a crafted key can never rewrite the URL authority
-- (e.g. '@host/...' turning the configured host into userinfo). '?' is
-- deliberately allowed: some legitimate Plex keys carry their own query
-- string, and a query cannot escape the pinned authority.
local function safePath (path)
	path = tostring (path or '')
	if (path:match ('^/[^%c%s\\]*$')) then return path end
	return nil
end

local function baseUrl ()
	return 'http://' .. tostring (gHost) .. ':' .. tostring (gPort)
end

-- Build a full URL: path + params + auth. `path` may already carry a query
-- string, so the separator adapts. The identity endpoint is the one place
-- auth must NOT be appended (works tokenless; keeps the token out of any
-- logged ping URL). Returns nil when unconfigured or the path is unsafe.
local function buildUrl (path, params, noAuth)
	if (not gHost) then return nil end
	path = safePath (path)
	if (not path) then return nil end
	local q = {}
	for k, v in pairs (params or {}) do
		q[#q + 1] = urlencode (k) .. '=' .. urlencode (v)
	end
	if (not noAuth) then
		if (not gToken) then return nil end
		q[#q + 1] = 'X-Plex-Token=' .. urlencode (gToken)
		q[#q + 1] = 'X-Plex-Client-Identifier=' .. urlencode (gClientId)
		q[#q + 1] = 'X-Plex-Product=c4plex'
	end
	local url = baseUrl () .. path
	if (#q > 0) then
		url = url .. ((path:find ('?', 1, true)) and '&' or '?') .. table.concat (q, '&')
	end
	return url
end

-- ---- XML -> table ---------------------------------------------------------

-- Collapse C4:ParseXml's node shape into {tag, attrs, children}: attributes as
-- a plain map (values length-capped), children as an array of collapsed nodes.
-- Depth and total node count are budgeted so pathological nesting cannot blow
-- the Lua stack and an oversized response cannot balloon memory; past-budget
-- content is dropped. ChildNodes is walked with ipairs when it is array-shaped
-- (child order is track order and must be preserved), falling back to pairs
-- otherwise; a non-contiguous array would be truncated at the first hole,
-- which is accepted (ParseXml emits contiguous arrays).
local function collapse (node, depth, budget)
	if (type (node) ~= 'table' or depth > MAX_XML_DEPTH) then return nil end
	budget.nodes = budget.nodes + 1
	if (budget.nodes > MAX_XML_NODES) then return nil end
	local out = {tag = node.Name, attrs = {}, children = {}}
	if (type (node.Attributes) == 'table') then
		for k, v in pairs (node.Attributes) do
			out.attrs [k] = tostring (v):sub (1, MAX_ATTR_CHARS)
		end
	end
	local kids = node.ChildNodes
	if (type (kids) == 'table') then
		local walked = false
		for _, child in ipairs (kids) do
			walked = true
			local c = collapse (child, depth + 1, budget)
			if (c and c.tag) then out.children [#out.children + 1] = c end
		end
		if (not walked) then
			for _, child in pairs (kids) do
				local c = collapse (child, depth + 1, budget)
				if (c and c.tag) then out.children [#out.children + 1] = c end
			end
		end
	end
	return out
end

-- Parse a response body expected to be <MediaContainer>. Returns the collapsed
-- container or nil+error. 401/404 bodies are text/html, so "parse failed" and
-- "not a MediaContainer" both surface as errors rather than empty results.
local function parseContainer (body)
	if (#body > MAX_BODY_BYTES) then return nil, 'response too large' end
	local root
	local ok = pcall (function ()
		local parsed = C4:ParseXml (body)
		if (type (parsed) == 'table') then
			root = collapse (parsed, 1, {nodes = 0})
		end
	end)
	if (not ok or type (root) ~= 'table') then return nil, 'unparseable response' end
	if (root.tag ~= 'MediaContainer') then
		-- tag capped: a hostile responder's multi-megabyte root tag must not
		-- balloon the error string that lands in logs
		return nil, 'unexpected response root: ' .. tostring (root.tag):sub (1, 64)
	end
	return root
end

-- ---- async GET ------------------------------------------------------------

-- invoke a callback under pcall; a throwing callback must never escape into
-- the C4 transfer/timer context. print, not Debug: a swallowed callback
-- error with logging off would be an invisible dead Navigator request.
local function safeCb (cb, a, b)
	local ok, err = pcall (cb, a, b)
	if (not ok) then print ('c4plex: plex callback error: ' .. scrub (err)) end
end

-- one-shot wrapper: the single-callback contract must hold even if the C4
-- transfer object both throws from Get and later fires OnDone
local function oneShot (cb)
	local fired = false
	return function (a, b)
		if (fired) then return end
		fired = true
		safeCb (cb, a, b)
	end
end

-- always-async error delivery; if the platform refuses the timer, a
-- synchronous delivery beats a Navigator spinning on a reply that never comes
local function deferError (once, msg)
	local t = C4:SetTimer (1, function () once (nil, msg) end)
	if (not t) then once (nil, msg) end
end

-- GET path+params, parse the MediaContainer, call cb(container, err).
-- Exactly one cb call per request, always asynchronous. The token never
-- appears in an error message or log line: errors carry the path only, and
-- transport messages are scrubbed in case the runtime echoes the URL.
local function doRequest (method, path, params, cb)
	local once = oneShot (cb or function () end)
	if (not Plex.IsConfigured ()) then
		deferError (once, 'not configured')
		return
	end
	local url = buildUrl (path, params)
	if (not url) then
		deferError (once, 'invalid request path')
		return
	end
	local t = C4:url ()
	if (not t) then
		deferError (once, 'C4:url unavailable')
		return
	end
	-- one pcall over the whole transfer setup: a throw from SetOptions or
	-- OnDone registration (API-shape drift) must reach the callback as an
	-- error, never escape as a silent dead request. fail_on_error must be
	-- off: it defaults to true, which turns every 4xx/5xx into a generic
	-- transfer error before the status-code branches below can run.
	local ok = pcall (function ()
		t:SetOptions ({timeout = REQUEST_TIMEOUT_S, fail_on_error = false})
		t:OnDone (function (transfer, responses, errCode, errMsg)
			local reply = responses and responses [#responses]
			if (errMsg == '') then errMsg = nil end
			if (errCode ~= 0 or not reply) then
				Debug.Warn ('plex:', method, path, 'transfer error:', scrub (errMsg))
				once (nil, 'transfer error: ' .. scrub (errMsg or errCode))
				return
			end
			local code = tonumber (reply.code) or 0
			if (code == 401) then once (nil, 'unauthorized') return end
			if (code < 200 or code > 299) then once (nil, 'HTTP ' .. code .. ' on ' .. path) return end
			local container, err = parseContainer (reply.body or '')
			if (not container) then once (nil, err) return end
			once (container)
		end)
		if (method == 'POST') then t:Post (url, '') else t:Get (url) end
	end)
	if (not ok) then deferError (once, 'request failed to start') end
end

function Plex.Get (path, params, cb)
	doRequest ('GET', path, params, cb)
end

-- POST with params in the query string and an empty body (the playQueues
-- creation shape). Same response handling as Plex.Get.
function Plex.Post (path, params, cb)
	doRequest ('POST', path, params, cb)
end

-- ---- endpoints ------------------------------------------------------------

-- Liveness: /identity needs no token, so a failure here is network/address,
-- not auth. cb(attrs, err) with attrs = {machineIdentifier=..., version=...}.
-- An HTTP 200 that is not a MediaContainer (a captive portal, some other web
-- server on the address) is reported distinctly so the installer chases the
-- address, not the token.
function Plex.Ping (cb)
	local once = oneShot (cb or function () end)
	if (not gHost) then
		-- guard for direct callers; the driver's connect() pre-checks HasHost
		deferError (once, 'no server address')
		return
	end
	local t = C4:url ()
	if (not t) then
		deferError (once, 'C4:url unavailable')
		return
	end
	local ok = pcall (function ()
		t:SetOptions ({timeout = REQUEST_TIMEOUT_S, fail_on_error = false})
		t:OnDone (function (transfer, responses, errCode, errMsg)
			local reply = responses and responses [#responses]
			if (errMsg == '') then errMsg = nil end
			if (errCode ~= 0 or not reply) then
				once (nil, scrub (errMsg or 'no response'))
				return
			end
			local code = tonumber (reply.code) or 0
			if (code ~= 200) then
				-- something answered on the address but refused /identity: a
				-- reachability truth the status ladder can name (a proxy, a
				-- different service on the port)
				once (nil, 'HTTP ' .. code)
				return
			end
			local container = parseContainer (reply.body or '')
			if (not container) then
				once (nil, 'not a Plex server')
				return
			end
			once (container.attrs, nil)
		end)
		t:Get (buildUrl ('/identity', nil, true))
	end)
	if (not ok) then deferError (once, 'request failed to start') end
end

-- Server info (friendlyName for the UI, transcoderAudio to sanity-check the
-- transcode path). cb(attrs, err).
function Plex.ServerInfo (cb)
	Plex.Get ('/', nil, function (container, err)
		if (not container) then cb (nil, err) return end
		gMachineId = tostring (container.attrs.machineIdentifier or '')
		cb (container.attrs)
	end)
end

-- Music sections: Directory rows with type="artist". cb(sections, err) where
-- each section is {key=..., title=...}.
function Plex.MusicSections (cb)
	Plex.Get ('/library/sections/', nil, function (container, err)
		if (not container) then cb (nil, err) return end
		local sections = {}
		for _, row in ipairs (container.children) do
			if (row.tag == 'Directory' and row.attrs.type == 'artist') then
				sections [#sections + 1] = {key = row.attrs.key, title = row.attrs.title or 'Music',
					agent = tostring (row.attrs.agent or '')}
			end
		end
		cb (sections)
	end)
end

-- Radio stations for a music section (a Plex Pass feature). cb(list, err) with
-- each = {title=..., key=...}; the list is empty when the account has no
-- stations (non-Pass), so the caller simply omits the section.
function Plex.Stations (sectionKey, cb)
	Plex.Get ('/hubs/sections/' .. tostring (sectionKey), {includeStations = '1', count = '12'},
			function (container, err)
		if (not container) then cb (nil, err) return end
		local out = {}
		for _, hub in ipairs (container.children) do
			if (hub.tag == 'Hub' and tostring (hub.attrs.hubIdentifier or ''):find ('stations', 1, true)) then
				for _, row in ipairs (hub.children) do
					local a = row.attrs
					if (a and a.key and a.title) then
						out[#out + 1] = {title = tostring (a.title), key = tostring (a.key)}
					end
				end
			end
		end
		cb (out)
	end)
end

-- Start (or refill) a station: POST /playQueues seeds a big random radio queue;
-- we take the returned window of tracks. cb(container, err) with Track children,
-- like any other track listing. Re-calling yields a fresh random batch, which is
-- exactly how the radio keeps going.
function Plex.StationTracks (stationKey, cb)
	if (gMachineId == '') then cb (nil, 'server identity not known yet') return end
	local uri = 'server://' .. gMachineId .. '/com.plexapp.plugins.library' .. tostring (stationKey)
	Plex.Post ('/playQueues', {type = 'audio', continuous = '1', uri = uri}, function (container, err)
		if (not container) then cb (nil, err) return end
		local tracks = {tag = 'MediaContainer', attrs = {}, children = {}}
		for _, row in ipairs (container.children) do
			if (row.tag == 'Track') then tracks.children[#tracks.children + 1] = row end
		end
		cb (tracks)
	end)
end

-- The per-artist radio "mix" (Plex Pass): GET metadata?includeStations=1 exposes
-- a station whose key is /library/metadata/{rk}/station/{uuid}. cb(stationKey) or
-- cb(nil, err) when the artist has no station (non-Pass / not analyzed). Feed the
-- returned key to Plex.StationTracks like any other station.
function Plex.ArtistStation (artistRk, cb)
	local rk = tostring (artistRk):match ('^%d+$')
	if (not rk) then cb (nil, 'bad rating key') return end
	Plex.Get ('/library/metadata/' .. rk, {includeStations = '1'}, function (container, err)
		if (not container) then cb (nil, err) return end
		-- the station key may sit on a top-level node or one level down (inside a
		-- Related/Stations hub); scan both for the first '/station/' key
		local function stationKey (node)
			if (node.attrs and node.attrs.key
					and tostring (node.attrs.key):find ('/station/', 1, true)) then
				return tostring (node.attrs.key)
			end
		end
		for _, node in ipairs (container.children) do
			local k = stationKey (node)
			if (k) then cb (k) return end
			if (node.children) then
				for _, sub in ipairs (node.children) do
					k = stationKey (sub)
					if (k) then cb (k) return end
				end
			end
		end
		cb (nil, 'no station')
	end)
end

-- A secondary browse dimension for a section: genre / decade tag list.
-- cb(list, err) with each = {title=..., id=...}; the id filters albums via
-- SectionAll {genre=id} / {decade=id}. Works for any account (not Plex Pass).
function Plex.TagList (sectionKey, dim, cb)
	Plex.Get ('/library/sections/' .. tostring (sectionKey) .. '/' .. tostring (dim), nil,
			function (container, err)
		if (not container) then cb (nil, err) return end
		local out = {}
		for _, row in ipairs (container.children) do
			if (row.tag == 'Directory') then
				local a = row.attrs
				if (a and a.key and a.title) then
					out[#out + 1] = {title = tostring (a.title), id = tostring (a.key)}
				end
			end
		end
		cb (out)
	end)
end

-- Paged section listing: /library/sections/{key}/all?type=N.
-- extra: optional additional filter params (e.g. title= for search).
-- cb(container, err); rows are container.children, total in
-- container.attrs.totalSize when paginating.
function Plex.SectionAll (sectionKey, mediaType, start, count, extra, cb)
	local params = {
		type = mediaType,
		['X-Plex-Container-Start'] = tostring (start or 0),
		['X-Plex-Container-Size'] = tostring (count or 100),
	}
	for k, v in pairs (extra or {}) do params [k] = v end
	Plex.Get ('/library/sections/' .. tostring (sectionKey) .. '/all', params, cb)
end

-- Drill-down: follow a row's own key (already a full path like
-- "/library/metadata/56654/children"), paged the same way.
function Plex.Children (key, start, count, cb)
	Plex.Get (key, {
		['X-Plex-Container-Start'] = tostring (start or 0),
		['X-Plex-Container-Size'] = tostring (count or 100),
	}, cb)
end

-- Audio playlists. cb(container, err); rows are Playlist elements whose key
-- ("/playlists/{rk}/items") feeds Plex.Children for the track list.
function Plex.Playlists (start, count, cb)
	Plex.Get ('/playlists', {
		playlistType = 'audio',
		['X-Plex-Container-Start'] = tostring (start or 0),
		['X-Plex-Container-Size'] = tostring (count or 100),
	}, cb)
end

-- Scoped search: all?type=N&title= is what python-plexapi does; one endpoint,
-- one response shape, music-only by construction.
function Plex.Search (sectionKey, mediaType, query, start, count, cb)
	Plex.SectionAll (sectionKey, mediaType, start, count, {title = tostring (query or '')}, cb)
end

-- A-Z bucket index for a section listing: Directory rows carrying title (the
-- character) and size (items in the bucket), in listing order under the
-- default title sort. One cheap call backs the whole AlphaMap scrubber.
function Plex.FirstCharacters (sectionKey, mediaType, cb)
	Plex.Get ('/library/sections/' .. tostring (sectionKey) .. '/firstCharacter',
			{type = mediaType}, function (container, err)
		if (not container) then cb (nil, err) return end
		local buckets = {}
		for _, row in ipairs (container.children) do
			if (row.tag == 'Directory') then
				local size = tonumber (row.attrs.size)
				if (size and size > 0) then
					buckets [#buckets + 1] = {title = tostring (row.attrs.title or '?'), size = math.floor (size)}
				end
			end
		end
		cb (buckets)
	end)
end

-- ---- plex.tv account linking (PIN flow) -----------------------------------
-- The one HTTPS dependency: plex.tv/api/v2 is TLS-only. The 4-character
-- plex.tv/link code comes from a plain POST /pins (no strong param); the
-- token appears on the poll once the user enters the code. The client
-- identifier MUST be identical on create and poll.

local PLEXTV = 'https://plex.tv/api/v2'

-- withToken must stay OFF for the pin calls: a token on the pin create could
-- associate the pin with the account instead of leaving it for plex.tv/link
local function tvHeaders (withToken)
	local h = {
		['X-Plex-Client-Identifier'] = gClientId,
		['X-Plex-Product'] = 'c4plex',
	}
	if (withToken and gToken) then h ['X-Plex-Token'] = gToken end
	return h
end

-- shared transfer runner for the plex.tv calls: cb(root, err) with the
-- collapsed response root ({tag, attrs, children}; root name varies)
local function tvCall (method, url, withToken, cb)
	local once = oneShot (cb or function () end)
	local t = C4:url ()
	if (not t) then
		deferError (once, 'C4:url unavailable')
		return
	end
	local ok = pcall (function ()
		t:SetOptions ({timeout = REQUEST_TIMEOUT_S, fail_on_error = false})
		t:OnDone (function (transfer, responses, errCode, errMsg)
			local reply = responses and responses [#responses]
			if (errMsg == '') then errMsg = nil end
			if (errCode ~= 0 or not reply) then
				once (nil, 'transfer error: ' .. scrub (errMsg or errCode))
				return
			end
			local code = tonumber (reply.code) or 0
			-- 404 means "pin unknown/expired" only on the poll; a 404 on the
			-- create call is a plain HTTP failure
			if (code == 404 and method == 'GET') then once (nil, 'pin expired') return end
			if (code < 200 or code > 299) then once (nil, 'HTTP ' .. code) return end
			local root
			local pok = pcall (function ()
				local parsed = C4:ParseXml (reply.body or '')
				if (type (parsed) == 'table') then
					root = collapse (parsed, 1, {nodes = 0})
				end
			end)
			if (not pok or type (root) ~= 'table') then once (nil, 'unparseable response') return end
			once (root)
		end)
		if (method == 'POST') then
			t:Post (url, '', tvHeaders (withToken))
		else
			t:Get (url, tvHeaders (withToken))
		end
	end)
	if (not ok) then deferError (once, 'request failed to start') end
end

-- request a link code. cb({id=, code=, expiresIn=}, err)
function Plex.TvRequestPin (cb)
	tvCall ('POST', PLEXTV .. '/pins', false, function (root, err)
		if (not root) then cb (nil, err) return end
		local id = tostring (root.attrs.id or '')
		local code = tostring (root.attrs.code or '')
		if (id == '' or code == '') then cb (nil, 'unparseable response') return end
		cb ({id = id, code = code:upper (), expiresIn = tonumber (root.attrs.expiresIn)})
	end)
end

-- poll a pin. cb({authToken=...}, err): authToken empty until the user
-- enters the code on plex.tv/link; 'pin expired' once plex.tv forgets it.
function Plex.TvCheckPin (pinId, cb)
	tvCall ('GET', PLEXTV .. '/pins/' .. Plex.UrlEncode (tostring (pinId)), false, function (root, err)
		if (not root) then cb (nil, err) return end
		cb ({authToken = tostring (root.attrs.authToken or '')})
	end)
end

-- Discover the account's servers so Navigator-side setup needs no typed
-- address: plex.tv lists each owned PMS with its connections. cb(list, err)
-- where each entry is {name, address, port, machineId, isLocal}, owned
-- servers only, ALL usable connections (multiple per server), so the caller
-- can probe for one the controller can actually reach.
function Plex.TvResources (cb)
	if (not gToken) then
		C4:SetTimer (1, function () safeCb (cb, nil, 'not configured') end)
		return
	end
	tvCall ('GET', PLEXTV .. '/resources?includeHttps=1&includeRelay=0', true, function (root, err)
		if (not root) then cb (nil, err) return end
		local out = {}
		for _, res in ipairs (root.children) do
			local a = res.attrs
			if (tostring (a.provides or ''):find ('server', 1, true)
					and (a.owned == '1' or a.owned == 'true')) then
				for _, kid in ipairs (res.children) do
					if (kid.tag == 'connections' or kid.tag == 'Connection' or kid.tag == 'connection') then
						-- shape varies: connections wrapper with connection
						-- children, or connection rows directly
						local rows = (kid.tag == 'connections') and kid.children or {kid}
						for _, c in ipairs (rows) do
							local ca = c.attrs
							-- collect every plausible IP connection; the caller
							-- probes them over plain http regardless of the
							-- advertised protocol (plex.tv marks nearly all
							-- entries https). "local" is a hint, not a
							-- guarantee: a container-internal bridge address
							-- only answers inside the host.
							if (ca.address and ca.address ~= ''
									and tostring (ca.address):match ('^%d+%.%d+%.%d+%.%d+$')) then
								out[#out + 1] = {
									name = tostring (a.name or ''),
									address = tostring (ca.address),
									port = tonumber (ca.port) or 32400,
									machineId = tostring (a.clientIdentifier or ''),
									isLocal = (ca ['local'] == '1'),
								}
							end
						end
					end
				end
			end
		end
		cb (out)
	end)
end

-- Tokenless /identity probe against a SPECIFIC address (not the configured
-- one), for discovery reachability testing. cb(machineId or nil). Short
-- timeout so probing several candidates stays quick.
function Plex.ProbeIdentity (host, port, cb)
	-- one-shot: like every other transfer here, the C4 url object can both throw
	-- from Get and later fire OnDone; without this the callback double-fires and
	-- discovery advances tryNext twice (overlapping probe chains, a spurious adopt)
	local once = oneShot (cb or function () end)
	host = tostring (host or '')
	if (not host:match ('^[%w%.%-]+$')) then
		C4:SetTimer (1, function () once (nil) end)
		return
	end
	local t = C4:url ()
	if (not t) then
		C4:SetTimer (1, function () once (nil) end)
		return
	end
	local url = 'http://' .. host .. ':' .. tostring (tonumber (port) or 32400) .. '/identity'
	local ok = pcall (function ()
		t:SetOptions ({timeout = 4, fail_on_error = false})
		t:OnDone (function (transfer, responses, errCode)
			local reply = responses and responses [#responses]
			if (errCode ~= 0 or not reply or (tonumber (reply.code) or 0) ~= 200) then
				once (nil)
				return
			end
			local mid
			pcall (function ()
				local parsed = C4:ParseXml (reply.body or '')
				local root = (type (parsed) == 'table') and collapse (parsed, 1, {nodes = 0})
				mid = root and root.attrs and root.attrs.machineIdentifier
			end)
			once (mid)
		end)
		t:Get (url)
	end)
	if (not ok) then C4:SetTimer (1, function () once (nil) end) end
end

-- Artist "Top Tracks": the modern Plex music agent attaches a popularity
-- set to the artist metadata. cb(container, err); the popular tracks are
-- <Track> rows under a <PopularLeaves> child of the returned artist.
function Plex.PopularTracks (artistRk, cb)
	local rk = tostring (artistRk):match ('^%d+$')
	if (not rk) then cb (nil, 'bad rating key') return end
	Plex.Get ('/library/metadata/' .. rk, {includePopularLeaves = '1'}, function (container, err)
		if (not container) then cb (nil, err) return end
		-- pull the Track rows out of PopularLeaves so the caller gets a flat
		-- container of tracks like any other listing. Plex nests PopularLeaves
		-- one level down, inside the artist's own <Directory>, not at the
		-- MediaContainer top level; scan both so we are robust to either shape
		local tracks = {tag = 'MediaContainer', attrs = {}, children = {}}
		local function harvest (node)
			if (node.tag == 'PopularLeaves') then
				for _, t in ipairs (node.children) do
					if (t.tag == 'Track') then tracks.children[#tracks.children + 1] = t end
				end
			end
		end
		for _, node in ipairs (container.children) do
			harvest (node)
			if (node.children) then
				for _, sub in ipairs (node.children) do harvest (sub) end
			end
		end
		cb (tracks)
	end)
end

-- In-library similar artists (the modern agent resolves these to artists the
-- server actually holds, so every one is playable). cb(container, err) with
-- Directory artist rows.
function Plex.SimilarArtists (artistRk, count, cb)
	local rk = tostring (artistRk):match ('^%d+$')
	if (not rk) then cb (nil, 'bad rating key') return end
	Plex.Get ('/library/metadata/' .. rk .. '/similar',
		{count = tostring (count or 24)}, cb)
end

-- ---- URL builders (no I/O) ------------------------------------------------

-- Direct play: the original file bytes from Part@key. Playable only if the
-- renderer decodes the container/codec; callers decide via Media@audioCodec.
function Plex.DirectUrl (partKey)
	return buildUrl (partKey)
end

-- Universal transcode: a single progressive MP3 stream, the safe choice for a
-- dumb URL player. protocol=http + start.mp3 is community-documented (the
-- OpenAPI spec only lists the segmented m3u8/mpd variants) and is what the
-- open-source PlexFlux and hibiki clients ship. directPlay/directStream are
-- forced off so the output really is MP3 regardless of the source codec.
-- offsetSec restarts the stream mid-track (progressive transcodes do not
-- byte-range seek reliably).
function Plex.TranscodeUrl (ratingKey, maxKbps, offsetSec)
	if (not ratingKey or ratingKey == '') then return nil end
	local params = {
		path = '/library/metadata/' .. tostring (ratingKey),
		mediaIndex = '0',
		partIndex = '0',
		protocol = 'http',
		directPlay = '0',
		directStream = '0',
		hasMDE = '1',
		audioCodec = 'mp3',
		maxAudioBitrate = tostring (maxKbps or 320),
		-- session id is per TRACK: the server holds one transcoder job per
		-- session, so if the current track and the engine's pre-fetched next
		-- URL shared one session, opening the next would kill the current
		-- stream mid-play. Stale per-track sessions expire server-side.
		session = gClientId .. '-' .. tostring (ratingKey),
	}
	if (tonumber (offsetSec) and tonumber (offsetSec) > 0) then
		params.offset = tostring (math.floor (tonumber (offsetSec)))
	end
	return buildUrl ('/music/:/transcode/universal/start.mp3', params)
end

-- Artwork resized server-side; thumb is the row's server-relative thumb/art
-- path. Navigators fetch this URL directly, so it must be absolute and carry
-- the token itself.
function Plex.ArtUrl (thumb, size)
	if (not thumb or thumb == '' or not safePath (thumb)) then return nil end
	size = tostring (size or 400)
	return buildUrl ('/photo/:/transcode', {
		width = size, height = size, minSize = '1', upscale = '1',
		url = thumb,
	})
end

return Plex
