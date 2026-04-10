const WebSocket = require('ws');

const port = process.env.PORT || 3000;
const wss = new WebSocket.Server({ port });

let clients = {};

function printUsers() {
  console.log("🟢 Connected users:", Object.keys(clients));
  console.log("👥 Total:", Object.keys(clients).length);
}

wss.on('connection', (ws) => {
  console.log("🔌 New socket connected");

  ws.on('message', (message) => {
    const data = JSON.parse(message);

    // User joins
    if (data.type === 'join') {
      clients[data.id] = ws;
      ws.id = data.id;

      console.log(`✅ User joined: ${data.id}`);
      printUsers();
    }

    // Forward message
    if (data.to && clients[data.to]) {
      console.log(`📨 ${ws.id} → ${data.to} (${data.type})`);
      clients[data.to].send(JSON.stringify(data));
    } else if (data.to) {
      console.log(`❌ Target not found: ${data.to}`);
    }
  });

  ws.on('close', () => {
    if (ws.id) {
      console.log(`❌ User disconnected: ${ws.id}`);
      delete clients[ws.id];
      printUsers();
    } else {
      console.log("❌ Unknown client disconnected");
    }
  });
});

console.log(`🚀 WebSocket running on port ${port}`);
