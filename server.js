const WebSocket = require('ws');

const port = process.env.PORT || 3000;

const wss = new WebSocket.Server({ port });

let clients = [];

wss.on('connection', (ws) => {
  console.log("Client connected");

  clients.push(ws);

  ws.on('message', (message) => {
    clients.forEach(client => {
      if (client !== ws && client.readyState === WebSocket.OPEN) {
        client.send(message.toString());
      }
    });
  });

  ws.on('close', () => {
    clients = clients.filter(c => c !== ws);
    console.log("Client disconnected");
  });
});

console.log(`WebSocket running on port ${port}`);
