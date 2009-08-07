#!/usr/bin/env lua
-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

package.path = package.path ..";../?.lua";
local serialize = require "util.serialization".serialize;
local st = require "util.stanza";
package.loaded["util.logger"] = {init = function() return function() end; end}
local dm = require "util.datamanager"
dm.set_data_path("data");

function parseFile(filename)
------

local file = nil;
local last = nil;
local function read(expected)
	local ch;
	if last then
		ch = last; last = nil;
	else ch = file:read(1); end
	if expected and ch ~= expected then error("expected: "..expected.."; got: "..(ch or "nil")); end
	return ch;
end
local function pushback(ch)
	if last then error(); end
	last = ch;
end
local function peek()
	if not last then last = read(); end
	return last;
end

local escapes = {
	["\\0"] = "\0";
	["\\'"] = "'";
	["\\\""] = "\"";
	["\\b"] = "\b";
	["\\n"] = "\n";
	["\\r"] = "\r";
	["\\t"] = "\t";
	["\\Z"] = "\26";
	["\\\\"] = "\\";
	["\\%"] = "%";
	["\\_"] = "_";
}
local function unescape(s)
	return escapes[s] or error("Unknown escape sequence: "..s);
end
local function readString()
	read("'");
	local s = "";
	while true do
		local ch = peek();
		if ch == "\\" then
			s = s..unescape(read()..read());
		elseif ch == "'" then
			break;
		else
			s = s..read();
		end
	end
	read("'");
	return s;
end
local function readNonString()
	local s = "";
	while true do
		if peek() == "," or peek() == ")" then
			break;
		else
			s = s..read();
		end
	end
	return tonumber(s);
end
local function readItem()
	if peek() == "'" then
		return readString();
	else
		return readNonString();
	end
end
local function readTuple()
	local items = {}
	read("(");
	while peek() ~= ")" do
		table.insert(items, readItem());
		if peek() == ")" then break; end
		read(",");
	end
	read(")");
	return items;
end
local function readTuples()
	if peek() ~= "(" then read("("); end
	local tuples = {};
	while true do
		table.insert(tuples, readTuple());
		if peek() == "," then read() end
		if peek() == ";" then break; end
	end
	return tuples;
end
local function readTableName()
	local tname = "";
	while peek() ~= "`" do tname = tname..read(); end
	return tname;
end
local function readInsert()
	if peek() == nil then return nil; end
	for ch in ("INSERT INTO `"):gmatch(".") do -- find line starting with this
		if peek() == ch then
			read(); -- found
		else -- match failed, skip line
			while peek() and read() ~= "\n" do end
			return nil;
		end
	end
	local tname = readTableName();
	for ch in ("` VALUES "):gmatch(".") do read(ch); end -- expect this
	local tuples = readTuples();
	read(";"); read("\n");
	return tname, tuples;
end

local function readFile(filename)
	file = io.open(filename);
	if not file then error("File not found: "..filename); os.exit(0); end
	local t = {};
	while true do
		local tname, tuples = readInsert();
		if tname then
			if t[name] then
				local t_name = t[name];
				for i=1,#tuples do
					table.insert(t_name, tuples[i]);
				end
			else
				t[tname] = tuples;
			end
		elseif peek() == nil then
			break;
		end
	end
	return t;
end

return readFile(filename);

------
end

-- XML parser
local parse_xml = (function()
	local entity_map = setmetatable({
		["amp"] = "&";
		["gt"] = ">";
		["lt"] = "<";
		["apos"] = "'";
		["quot"] = "\"";
	}, {__index = function(_, s)
			if s:sub(1,1) == "#" then
				if s:sub(2,2) == "x" then
					return string.char(tonumber(s:sub(3), 16));
				else
					return string.char(tonumber(s:sub(2)));
				end
			end
		end
	});
	local function xml_unescape(str)
		return (str:gsub("&(.-);", entity_map));
	end
	local function parse_tag(s)
		local name,sattr=(s):gmatch("([^%s]+)(.*)")();
		local attr = {};
		for a,b in (sattr):gmatch("([^=%s]+)=['\"]([^'\"]*)['\"]") do attr[a] = xml_unescape(b); end
		return name, attr;
	end
	return function(xml)
		local stanza = st.stanza("root");
		local regexp = "<([^>]*)>([^<]*)";
		for elem, text in xml:gmatch(regexp) do
			if elem:sub(1,1) == "!" or elem:sub(1,1) == "?" then -- neglect comments and processing-instructions
			elseif elem:sub(1,1) == "/" then -- end tag
				elem = elem:sub(2);
				stanza:up(); -- TODO check for start-end tag name match
			elseif elem:sub(-1,-1) == "/" then -- empty tag
				elem = elem:sub(1,-2);
				local name,attr = parse_tag(elem);
				stanza:tag(name, attr):up();
			else -- start tag
				local name,attr = parse_tag(elem);
				stanza:tag(name, attr);
			end
			if #text ~= 0 then -- text
				stanza:text(xml_unescape(text));
			end
		end
		return stanza.tags[1];
	end
end)();
-- end of XML parser

local arg, host = ...;
local help = "/? -? ? /h -h /help -help --help";
if not(arg and host) or help:find(arg, 1, true) then
	print([[ejabberd SQL DB dump importer for Prosody

  Usage: ejabberdsql2prosody.lua filename.txt hostname

The file can be generated using mysqldump:
  mysqldump db_name > filename.txt]]);
	os.exit(1);
end
local map = {
	["last"] = {"username", "seconds", "state"};
	["privacy_default_list"] = {"username", "name"};
	["privacy_list"] = {"username", "name", "id"};
	["privacy_list_data"] = {"id", "t", "value", "action", "ord", "match_all", "match_iq", "match_message", "match_presence_in", "match_presence_out"};
	["private_storage"] = {"username", "namespace", "data"};
	["rostergroups"] = {"username", "jid", "grp"};
	["rosterusers"] = {"username", "jid", "nick", "subscription", "ask", "askmessage", "server", "subscribe", "type"};
	["spool"] = {"username", "xml", "seq"};
	["users"] = {"username", "password"};
	["vcard"] = {"username", "vcard"};
	--["vcard_search"] = {};
}
local NULL = {};
local t = parseFile(arg);
for name, data in pairs(t) do
	local m = map[name];
	if m then
		if #data > 0 and #data[1] ~= #m then
			print("[warning] expected "..#m.." columns for table `"..name.."`, found "..#data[1]);
		end
		for i=1,#data do
			local row = data[i];
			for j=1,#m do
				row[m[j]] = row[j];
				row[j] = nil;
			end
		end
	end
end
--print(serialize(t));

for i, row in ipairs(t["users"] or NULL) do
	local node, password = row.username, row.password;
	local ret, err = dm.store(node, host, "accounts", {password = password});
	print("["..(err or "success").."] accounts: "..node.."@"..host.." = "..password);
end

function roster(node, host, jid, item)
	local roster = dm.load(node, host, "roster") or {};
	roster[jid] = item;
	local ret, err = dm.store(node, host, "roster", roster);
	print("["..(err or "success").."] roster: " ..node.."@"..host.." - "..jid);
end
function roster_pending(node, host, jid)
	local roster = dm.load(node, host, "roster") or {};
	roster.pending = roster.pending or {};
	roster.pending[jid] = true;
	local ret, err = dm.store(node, host, "roster", roster);
	print("["..(err or "success").."] roster-pending: " ..node.."@"..host.." - "..jid);
end
function roster_group(node, host, jid, group)
	local roster = dm.load(node, host, "roster") or {};
	local item = roster[jid];
	if not item then print("Warning: No roster item "..jid.." for user "..node..", can't put in group "..group); return; end
	item.groups[group] = true;
	local ret, err = dm.store(node, host, "roster", roster);
	print("["..(err or "success").."] roster-group: " ..node.."@"..host.." - "..jid.." - "..group);
end
function private_storage(node, host, xmlns, stanza)
	local private = dm.load(node, host, "private") or {};
	private[stanza.name..":"..xmlns] = st.preserialize(stanza);
	local ret, err = dm.store(node, host, "private", private);
	print("["..(err or "success").."] private: " ..node.."@"..host.." - "..xmlns);
end
for i, row in ipairs(t["rosterusers"] or NULL) do
	local node, contact = row.username, row.jid;
	local name = row.nick;
	if name == "" then name = nil; end
	local subscription = row.subscription;
	if subscription == "N" then
		subscription = "none"
	elseif subscription == "B" then
		subscription = "both"
	elseif subscription == "F" then
		subscription = "from"
	elseif subscription == "T" then
		subscription = "to"
	else error("Unknown subscription type: "..subscription) end;
	local ask = row.ask;
	if ask == "N" then
		ask = nil;
	elseif ask == "O" then
		ask = "subscribe";
	elseif ask == "I" then
		roster_pending(node, host, contact);
		ask = nil;
	elseif ask == "B" then
		roster_pending(node, host, contact);
		ask = "subscribe";
	else error("Unknown ask type: "..ask); end
	local item = {name = name, ask = ask, subscription = subscription, groups = {}};
	roster(node, host, contact, item);
end
for i, row in ipairs(t["rostergroups"] or NULL) do
	roster_group(row.username, host, row.jid, row.grp);
end
for i, row in ipairs(t["vcard"] or NULL) do
	local ret, err = dm.store(row.username, host, "vcard", st.preserialize(parse_xml(row.vcard)));
	print("["..(err or "success").."] vCard: "..row.username.."@"..host);
end
for i, row in ipairs(t["private_storage"] or NULL) do
	private_storage(row.username, host, row.namespace, st.preserialize(parse_xml(row.data)));
end