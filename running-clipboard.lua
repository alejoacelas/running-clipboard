-- running-clipboard: Option+C quotes the selected text, asks for a comment,
-- and adds both to a set of notes that the clipboard holds as one paste.

local M = {}

local pb = hs.pasteboard
local HOTKEY_MODS, HOTKEY_KEY = { "alt" }, "c"

-- Every set we have written, keyed by its text, valued by its note count.
-- The clipboard continues a set whenever it holds that set's exact text,
-- including when the set is picked again from clipboard history.
local knownSets = {}
-- changeCount at the moment a set was pasted with Cmd+V. The next note
-- after a paste starts a new set until the clipboard changes again.
local pastedAtChange = nil

local panel, previousWindow, pending -- pending = { quote, appendTo, previousClipboard, grabbed }

local function quoteBlock(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    table.insert(lines, (line == "" and ">" or ("> " .. line)))
  end
  while #lines > 0 and lines[#lines] == ">" do table.remove(lines) end
  return table.concat(lines, "\n")
end

local function formatNote(quote, comment)
  local parts = {}
  if quote and quote:match("%S") then table.insert(parts, quoteBlock(quote)) end
  if comment and comment:match("%S") then table.insert(parts, (comment:gsub("%s+$", ""))) end
  return table.concat(parts, "\n")
end

-- The set the next note would join, or nil when it would start a new set.
local function currentSet()
  if pb.changeCount() == pastedAtChange then return nil end
  local text = pb.getContents()
  if text and knownSets[text] then return text end
  return nil
end

-- Read the selection through Accessibility; fall back to a simulated Cmd+C.
local function grabSelection()
  local ok, el = pcall(hs.uielement.focusedElement)
  if ok and el then
    local okSel, sel = pcall(function() return el:selectedText() end)
    if okSel and sel and sel ~= "" then return sel, false end
  end
  local before = pb.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)
  local deadline = hs.timer.secondsSinceEpoch() + 0.4
  while pb.changeCount() == before and hs.timer.secondsSinceEpoch() < deadline do
    hs.timer.usleep(10000)
  end
  if pb.changeCount() == before then return nil, false end
  return pb.getContents(), true
end

local function closePanel()
  if panel then panel:delete(); panel = nil end
  -- Hand focus back to the window the note came from.
  if previousWindow then previousWindow:focus(); previousWindow = nil end
end

local function finish(msg)
  print("running-clipboard: " .. hs.inspect(msg))
  local p = pending
  pending = nil
  closePanel()
  if not p then return end
  if msg.action == "cancel" then
    -- Put back what the clipboard held before a simulated copy replaced it.
    if p.grabbed and p.previousClipboard then pb.setContents(p.previousClipboard) end
    return
  end
  local note = formatNote(p.quote, msg.comment)
  if note == "" then
    if p.grabbed and p.previousClipboard then pb.setContents(p.previousClipboard) end
    return
  end
  local base = (not msg.newSet) and p.appendTo or nil
  local text = base and (base .. "\n\n" .. note) or note
  knownSets[text] = (base and knownSets[base] or 0) + 1
  pb.setContents(text)
end

local function htmlEscape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local PAGE = [[
<!doctype html><html><head><meta charset="utf-8"><style>
:root{color-scheme:light dark;--bg:#fbfbfa;--fg:#1d1d1f;--muted:#6e6e73;--line:#d9d9de;--quote:#f0f0ee;--accent:#0a66d8}
@media (prefers-color-scheme:dark){:root{--bg:#232325;--fg:#f2f2f4;--muted:#9a9aa0;--line:#3a3a3e;--quote:#2d2d30;--accent:#5aa2ff}}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif}
body{display:flex;flex-direction:column;padding:12px;gap:8px;border:1px solid var(--line);border-radius:10px;overflow:hidden}
#quote{max-height:140px;overflow:auto;white-space:pre-wrap;background:var(--quote);border-left:3px solid var(--line);padding:6px 10px;border-radius:4px;color:var(--muted)}
#quote.empty{display:none}
textarea{flex:1;resize:none;border:1px solid var(--line);border-radius:6px;padding:8px;background:transparent;color:var(--fg);font:inherit;outline:none}
textarea:focus{border-color:var(--accent)}
#foot{display:flex;justify-content:space-between;color:var(--muted);font-size:12px}
#mode{color:var(--fg);font-weight:600}
</style></head><body>
<div id="quote" class="%QUOTECLASS%">%QUOTE%</div>
<textarea id="c" placeholder="Comment (optional)" autofocus autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" writingsuggestions="false"></textarea>
<div id="foot"><span id="mode"></span><span>Enter add · Shift+Enter new line · Tab switch · Esc cancel</span></div>
<script>
const count=%COUNT%; let newSet=count===0;
const mode=document.getElementById('mode'), c=document.getElementById('c');
function render(){mode.textContent = newSet ? 'New set' : ('Add to set (' + count + ' note' + (count===1?'':'s') + ')');}
function send(m){webkit.messageHandlers.rc.postMessage(m);}
render();
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'){e.preventDefault();send({action:'cancel'});}
  else if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();send({action:'add',comment:c.value,newSet});}
  else if(e.key==='Tab'){e.preventDefault(); if(count>0){newSet=!newSet;render();}}
});
setTimeout(()=>c.focus(),30);
</script></body></html>]]

function M.capture()
  if panel then return end
  previousWindow = hs.window.frontmostWindow()
  local appendTo = currentSet()
  local previous = pb.getContents()
  local quote, grabbed = grabSelection()

  print("running-clipboard: grabbed=" .. tostring(grabbed) .. " quote=" .. tostring(quote) .. " appendTo=" .. tostring(appendTo ~= nil))
  pending = { quote = quote, appendTo = appendTo, previousClipboard = previous, grabbed = grabbed }

  local count = appendTo and knownSets[appendTo] or 0
  local html = PAGE
    :gsub("%%QUOTECLASS%%", (quote and quote:match("%S")) and "" or "empty")
    :gsub("%%QUOTE%%", function() return htmlEscape(quote or "") end)
    :gsub("%%COUNT%%", tostring(count))

  local w, h = 460, (quote and quote:match("%S")) and 300 or 170
  local screen = hs.mouse.getCurrentScreen():frame()
  local mp = hs.mouse.absolutePosition()
  local x = math.min(math.max(mp.x - w / 2, screen.x + 8), screen.x + screen.w - w - 8)
  local y = math.min(mp.y + 20, screen.y + screen.h - h - 8)

  local uc = hs.webview.usercontent.new("rc")
  uc:setCallback(function(m) hs.timer.doAfter(0, function() finish(m.body) end) end)
  panel = hs.webview.new({ x = x, y = y, w = w, h = h }, { developerExtrasEnabled = false }, uc)
    :windowStyle({ "borderless" })
    :level(hs.drawing.windowLevels.modalPanel)
    :allowTextEntry(true)
    :transparent(true)
    :shadow(true)
    :html(html)
    :show()
  hs.focus()
  panel:hswindow():focus()
end

M.appWatcher = hs.application.watcher.new(function(name, event)
  if panel and event == hs.application.watcher.activated and name ~= "Hammerspoon" then
    finish({ action = "cancel" })
  end
end)
M.appWatcher:start()

-- Watch Cmd+V so the next note after pasting a set starts a new set.
M.pasteTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  local f = e:getFlags()
  if f.cmd and not (f.alt or f.ctrl or f.shift)
      and e:getKeyCode() == hs.keycodes.map["v"] then
    local text = pb.getContents()
    if text and knownSets[text] then pastedAtChange = pb.changeCount() end
  end
  return false
end)
M.pasteTap:start()

M.hotkey = hs.hotkey.bind(HOTKEY_MODS, HOTKEY_KEY, M.capture)

return M
