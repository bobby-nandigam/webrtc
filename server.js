const WebSocket = require('ws');

const port = process.env.PORT || 3000;
const wss = new WebSocket.Server({ port });

let clients = {};

function printUsers() {
  console.log("🟢 Connected users:", Object.keys(clients));
  console.log("👥 Total:", Object.keys(clients).length);
}

// Heartbeat mechanism to detect dead connections
function heartbeat() {
  this.isAlive = true;
}

const interval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) {
      console.log(`💀 Terminating dead connection: ${ws.id}`);
      return ws.terminate();
    }

    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

wss.on('connection', (ws) => {
  console.log("🔌 New socket connected");
  ws.isAlive = true;
  ws.on('pong', heartbeat);

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);

      // Handle ping/pong
      if (data.type === 'ping') {
        ws.send(JSON.stringify({ type: 'pong' }));
        print(`💓 Ping from ${ws.id} → Pong sent`);
        return;
      }
      
      // Handle ICE restart requests
      if (data.type === 'ice_restart') {
        if (clients[data.to]) {
          console.log(`🔄 Forwarding ICE_RESTART: ${data.from} → ${data.to}`);
          clients[data.to].send(JSON.stringify(data));
        } else {
          console.log(`❌ ICE_RESTART target not found: ${data.to}`);
        }
        return;
      }

      // User joins
      if (data.type === 'join') {
        clients[data.id] = ws;
        ws.id = data.id;

        console.log(`✅ User joined: ${data.id}`);
        printUsers();
        
        // Broadcast active users list to ALL clients
        const activeUsers = Object.keys(clients).filter(id => id !== data.id);
        const userListPayload = {
          type: 'users_list',
          users: activeUsers,
          total: activeUsers.length
        };
        
        // Send to the new user
        ws.send(JSON.stringify(userListPayload));
        console.log(`📤 Sent user list to ${data.id}: ${activeUsers.join(', ') || 'none'}`);
        
        // Notify all other clients about the new user
        wss.clients.forEach((client) => {
          if (client.id && client.id !== data.id) {
            client.send(JSON.stringify({
              type: 'user_joined',
              userId: data.id,
              activeUsers: Object.keys(clients).filter(id => id !== client.id)
            }));
          }
        });
        
        return;
      }

      // Forward message to specific user
      if (data.to && clients[data.to]) {
        console.log(`📨 ${ws.id} → ${data.to} (${data.type})`);
        clients[data.to].send(JSON.stringify(data));
      } else if (data.to) {
        console.log(`❌ Target not found: ${data.to} (available: ${Object.keys(clients).join(', ')})`);
      }
    } catch (e) {
      console.error(`❌ Error parsing message: ${e.message}`);
    }
  });

  ws.on('close', () => {
    if (ws.id) {
      const disconnectedUser = ws.id;
      console.log(`❌ User disconnected: ${disconnectedUser}`);
      delete clients[disconnectedUser];
      printUsers();
      
      // Notify all remaining clients about the departure
      wss.clients.forEach((client) => {
        if (client.id) {
          client.send(JSON.stringify({
            type: 'user_left',
            userId: disconnectedUser,
            activeUsers: Object.keys(clients).filter(id => id !== client.id)
          }));
        }
      });
    } else {
      console.log("❌ Unknown client disconnected");
    }
  });

  ws.on('error', (error) => {
    console.error(`⚠️ WebSocket error from ${ws.id}: ${error.message}`);
  });
});

// Cleanup on server shutdown
process.on('SIGTERM', () => {
  console.log('\n🛑 Shutting down server...');
  clearInterval(interval);
  wss.close(() => {
    console.log('✅ Server closed');
    process.exit(0);
  });
});

console.log(`🚀 WebSocket running on port ${port}`);
