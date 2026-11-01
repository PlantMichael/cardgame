extends Node

## The browser build runs inside the website's /play/ page. The website owns
## the account (sign-in, session, profile); this node is the game's side of the
## small postMessage contract between the two. Version 1:
##
##   game -> page   {cg: 1, type: "ready"}            the game is up and wants a session
##                  {cg: 1, type: "account-dirty"}    balances/rank changed; refresh from the server
##                  {cg: 1, type: "session-invalid"}  the page's token no longer works
##   page -> game   {cg: 1, type: "session", token}   the account to resume as
##                  {cg: 1, type: "account-changed", pfp_id}  the portrait changed on the site
##
## Messages only count when they come from this window's parent and from this
## page's own origin; the check happens in JavaScript, before Godot sees them.
## The game never sends the token anywhere, and nothing is placed in a URL.
## Incoming messages are queued in JS and polled here, so no JavaScript
## callback has to be kept alive.

signal session_received(token: String)
signal account_changed(pfp_id: String)

const VERSION := 1
const POLL_SEC := 0.1
const DIRTY_DEBOUNCE_SEC := 0.4

## True only in a web export that is running inside the website's page.
var embedded: bool = false

var _poll_left: float = 0.0
var _dirty_left: float = -1.0

const _INSTALL_JS := """
(function () {
  if (window.__cgBridge) return;
  var inbox = [];
  window.__cgBridge = { inbox: inbox };
  window.addEventListener('message', function (e) {
    if (e.origin !== window.location.origin || e.source !== window.parent) return;
    var d = e.data;
    if (!d || d.cg !== 1 || typeof d.type !== 'string') return;
    if (d.type === 'session' && typeof d.token === 'string' && d.token.length > 0 && d.token.length <= 128) {
      inbox.push(JSON.stringify({ type: 'session', token: d.token }));
    } else if (d.type === 'account-changed') {
      inbox.push(JSON.stringify({ type: 'account-changed', pfp_id: typeof d.pfp_id === 'string' ? d.pfp_id.slice(0, 80) : '' }));
    }
    if (inbox.length > 20) inbox.shift();
  });
})();
"""

func _ready() -> void:
	set_process(false)
	if not OS.has_feature("web"):
		return
	embedded = bool(JavaScriptBridge.eval("window.parent !== window"))
	if not embedded:
		return
	JavaScriptBridge.eval(_INSTALL_JS)
	set_process(true)
	announce_ready()

## Asks the page for the session (again, if the first request was missed).
func announce_ready() -> void:
	_post({"type": "ready"})

func notify_account_dirty() -> void:
	if embedded:
		_dirty_left = DIRTY_DEBOUNCE_SEC

func notify_session_invalid() -> void:
	_post({"type": "session-invalid"})

func _post(message: Dictionary) -> void:
	if not embedded:
		return
	var payload := message.duplicate()
	payload["cg"] = VERSION
	# The payload is built here from fixed strings; JSON text is a valid JS
	# expression. The target is this page's own origin, never "*".
	JavaScriptBridge.eval("window.parent.postMessage(%s, window.location.origin)" % JSON.stringify(payload))

func _process(delta: float) -> void:
	if _dirty_left >= 0.0:
		_dirty_left -= delta
		if _dirty_left < 0.0:
			_dirty_left = -1.0
			_post({"type": "account-dirty"})
	_poll_left -= delta
	if _poll_left > 0.0:
		return
	_poll_left = POLL_SEC
	for _i in 8:
		var raw = JavaScriptBridge.eval("(window.__cgBridge && window.__cgBridge.inbox.length) ? window.__cgBridge.inbox.shift() : ''")
		if raw == null or str(raw) == "":
			return
		var message = JSON.parse_string(str(raw))
		if not message is Dictionary:
			continue
		match str(message.get("type", "")):
			"session":
				session_received.emit(str(message.get("token", "")))
			"account-changed":
				account_changed.emit(str(message.get("pfp_id", "")))
