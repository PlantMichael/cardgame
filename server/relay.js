const WebSocket = require('ws');
const PORT = process.env.PORT || 8080;
const wss = new WebSocket.Server({ port: PORT });

// lobby_id -> { id, name, host_ws, guest_ws, host_name, guest_name, status }
const lobbies = new Map();
// ws -> { lobby_id, role }
const clients = new Map();

function sendTo(ws, obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

function lobbyList() {
  return Array.from(lobbies.values())
    .filter(l => l.status === 'waiting')
    .map(l => ({ id: l.id, name: l.name, host_name: l.host_name }));
}

wss.on('connection', (ws) => {
  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    switch (msg.type) {
      case 'create_lobby': {
        const id = Math.random().toString(36).slice(2, 8).toUpperCase();
        const lobby = {
          id,
          name: msg.name || (msg.host_name + "'s Lobby"),
          host_ws: ws,
          guest_ws: null,
          host_name: msg.host_name || 'Host',
          guest_name: '',
          status: 'waiting',
        };
        lobbies.set(id, lobby);
        clients.set(ws, { lobby_id: id, role: 'host' });
        sendTo(ws, { type: 'lobby_created', lobby_id: id });
        break;
      }

      case 'list_lobbies': {
        sendTo(ws, { type: 'lobby_list', lobbies: lobbyList() });
        break;
      }

      case 'join_lobby': {
        const lobby = lobbies.get(msg.lobby_id);
        if (!lobby || lobby.status !== 'waiting') {
          sendTo(ws, { type: 'error', message: 'Lobby not found or already full.' });
          return;
        }
        lobby.guest_ws = ws;
        lobby.guest_name = msg.guest_name || 'Guest';
        lobby.status = 'full';
        clients.set(ws, { lobby_id: lobby.id, role: 'guest' });
        sendTo(ws, { type: 'joined_lobby', lobby_id: lobby.id, host_name: lobby.host_name });
        sendTo(lobby.host_ws, { type: 'player_joined', guest_name: lobby.guest_name });
        break;
      }

      case 'relay': {
        const info = clients.get(ws);
        if (!info) return;
        const lobby = lobbies.get(info.lobby_id);
        if (!lobby) return;
        const target_ws = info.role === 'host' ? lobby.guest_ws : lobby.host_ws;
        sendTo(target_ws, { type: 'relay', payload: msg.payload, from_role: info.role });
        break;
      }

      case 'leave_lobby': {
        _handleDisconnect(ws);
        break;
      }
    }
  });

  ws.on('close', () => _handleDisconnect(ws));
});

function _handleDisconnect(ws) {
  const info = clients.get(ws);
  if (!info) return;
  const lobby = lobbies.get(info.lobby_id);
  if (lobby) {
    const other_ws = info.role === 'host' ? lobby.guest_ws : lobby.host_ws;
    sendTo(other_ws, { type: 'opponent_left' });
    lobbies.delete(lobby.id);
  }
  clients.delete(ws);
}

console.log('Relay server listening on port', PORT);
