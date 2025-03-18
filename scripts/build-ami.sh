
# build-ami.sh
#!/bin/bash
sudo yum update -y
sudo yum install -y nginx
sudo yum install -y nodejs
sudo mkdir -p /opt/payment-api
sudo echo 'const http = require("http");
const server = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "Payment Processed", timestamp: new Date().toISOString() }));
});
server.listen(3000, "0.0.0.0", () => {
    console.log("Server running at http://0.0.0.0:3000/");
});' > /opt/payment-api/server.js
sudo systemctl enable nginx
sudo systemctl start nginx
sudo echo 'server {
    listen 80;
    location / {
        proxy_pass http://0.0.0.0:3000;
    }
}' > /etc/nginx/conf.d/payment-api.conf
sudo systemctl restart nginx
