#!/bin/sh
# this file is intended of setting up a kryptokrona node on a vps
# copy this file to your vps and make it executable

NGINX_PROJECT_DIR="/etc/nginx/sites-enabled"
CURRENT_DIR=$(pwd)
DOMAIN="example.com"
EMAIL="foo@bar.com"
TOR_HIDDEN_SERVICE_NAME="your-hidden-service-name-here"

echo ""
echo "###### UPDATING HEADERS ######"
echo ""
sudo apt update
sudo apt upgrade

echo ""
echo "###### INSTALLING DEPENDENCIES ######"
echo ""
sudo apt-get -y install \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    curl \
    python3-certbot-nginx \
    p7zip-full

echo ""
echo "###### SETUP KEYRING FOR DOCKER ######"
echo ""
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo ""
echo "###### UPDATING SOURCES LIST FOR DOCKER ######"
echo ""
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo ""
echo "###### INSTALLING DOCKER ######"
echo ""
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

echo ""
echo "###### CLONE KRYPTOKRONA REPOSITORY ######"
echo ""
if [ -f "kryptokrona" ]; then
    echo "kryptokrona repository exists. Skipping..."
    (cd kryptokrona && git pull)
else
    git clone https://github.com/kryptokrona/kryptokrona.git
fi

echo ""
echo "###### DOWNLOADING EXISTING BLOCKS FROM BOOTSTRAP ######"
echo ""
if [ -f "bootstrap.7z" ]; then
    echo "bootstrap.7z exists. No need to download. Skipping..."
elif [ -d "bootstrap" ]; then
    echo "boostrap directory exists. No need to extract it. Skipping..."
else
    curl http://wasa.kryptokrona.se/xkr-bootstrap/bootstrap-20220426.7z --output bootstrap.7z

    echo ""
    echo "###### EXTRACING BOOSTRAP ######"
    echo ""
    7za x bootstrap.7z -o./bootstrap
fi

echo ""
echo "###### BULDING DOCKER IMAGE ######"
echo ""
(cd ./kryptokrona && git checkout docker-prod) # remove this line after when finished
(cd ./kryptokrona && docker build -f ./deploy/Dockerfile -t kryptokrona/kryptokrona-node .)

echo ""
echo "###### CREATING DOCKER NETWORK ######"
echo ""
docker network create kryptokrona

echo ""
echo "###### RUNNING DOCKER CONTAINER ######"
echo ""
docker run -d -p 11898:11898 --volume=$CURRENT_DIR/boostrap/.kryptokrona:/usr/src/kryptokrona/build/src/blockloc --network=kryptokrona kryptokrona/kryptokrona-node 

echo ""
echo "###### SETTING UP NGINX AND LET'S ENCRYPT ######"
echo ""

while true; do
    read -p "Do you wish to install your node with Tor? " yn
    case $yn in
        [Yy]* ) install_nginx_tor; break;;
        [Nn]* ) install_nginx;;
        * ) echo "Please answer yes or no.";;
    esac
done

function install_nginx_tor
{
	SOFTWARE="tor"
	QUERY="$(sudo dpkg-query -l | grep ${SOFTWARE} | wc -l)"

	if [ "$QUERY" -eq 0 ]; then
		echo ""
		echo "INSTALLING NGINX WITH TOR..."
		echo ""
        sudo apt install -y nftables apt-transport-https

        echo ""
        echo "###### SETUP NFTABLES RULES ######"
        echo ""
        sudo nft add rule inet filter input ct state related,established counter accept
        sudo nft add rule inet filter input iif lo counter accept
        sudo nft add rule inet filter input tcp dport 22 counter accept
        sudo nft add rule inet filter input counter drop
        sudo nft list ruleset > /etc/nftables.conf

        # add tor repositories to sources.list
        sudo sed '$a\\n\ndeb https://deb.torproject.org/torproject.org focal main' /etc/apt/sources.list
        sudo sed '$a\\n\ndeb-src https://deb.torproject.org/torproject.org focal main' /etc/apt/sources.list

        # add the GNU privacy guard (gpg) key used to sign the tor packages
        sudo apt install -y gpg curl
        curl https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | gpg --import
        gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | apt-key add -
        
        # update and install tor, deb.torproject.org-keyring and nginx
        sudo apt update
        sudo apt install -y tor deb.torproject.org-keyring nginx

        # replace tor configuration file
        sudo tee -a torrc > /dev/null <<EOT
        Log notice file /var/log/tor/log
        RunAsDaemon 1
        DataDirectory /var/lib/tor
        HiddenServiceDir /var/lib/tor/$TOR_HIDDEN_SERVICE_NAME/
        HiddenServicePort 80 unix:/var/run/nginx.sock
        EOT
        sudo cp $CURRENT_DIR/torrc /etc/tor/torrc

        # restart tor
        sudo systemctl restart tor

        # get onion address
        ONION_ADDRESS=$(cat /var/lib/tor/hiddenservicename/hostname)

        # setup nginx.conf
        sudo tee -a nginx.conf > /dev/null <<EOT
        user www-data;
        worker_processes auto;
        pid /run/nginx.pid;
        include /etc/nginx/modules-enabled/*.conf;

        events {
            worker_connections 768;
            # multi_accept on;
        }

        http {
            sendfile on;
            tcp_nopush on;
            tcp_nodelay on;
            keepalive_timeout 65;
            types_hash_max_size 2048;
            
            # Tor settings
            server_tokens off;
            add_header X-Frame-Options "SAMEORIGIN";
            add_header X-XSS-Protection "1; mode=block";
            client_body_buffer_size 1k;
            client_header_buffer_size 1k;
            client_max_body_size 1k;
            large_client_header_buffers 2 1k;

            include /etc/nginx/mime.types;
            default_type application/octet-stream;

            ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3; # Dropping SSLv3, ref: POODLE
            ssl_prefer_server_ciphers on;

            access_log /var/log/nginx/access.log;
            error_log /var/log/nginx/error.log;

            gzip on;

            include /etc/nginx/conf.d/*.conf;
            include /etc/nginx/sites-enabled/*;
        }
        EOT
        sudo cp $CURRENT_DIR/nginx.conf /etc/nginx/nginx.conf
        
        # setup default configuration file
        sudo tee -a default > /dev/null <<EOT
        server {
            server_name         $ONION_ADDRESS;
            listen unix:/var/run/nginx.sock;

            location / {
                proxy_pass http://127.0.0.1:11898;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto \$scheme;
            }
        }
        EOT
        sudo cp $CURRENT_DIR/default /etc/nginx/sites-available/default

        # updating nginx.service daemon
        sudo tee -a nging.service > /dev/null <<EOT
        [Unit]
        Description=A high performance web server and a reverse proxy server
        Documentation=man:nginx(8)
        After=network.target

        [Service]
        Type=forking
        PIDFile=/run/nginx.pid
        ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
        ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
        ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
        ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /run/nginx.pid
        TimeoutStopSec=5
        KillMode=mixed
        PrivateNetwork=yes

        [Install]
        WantedBy=multi-user.target
        EOT
        sudo cp $CURRENT_DIR/default /etc/nginx/sites-available/default

        # restart nginx
        sudo systemctl stop nginx
        sudo rm /var/run/nginx.sock
        sudo systemctl start nginx

        # set permissions and restart tor
        sudo chown -R root /var/lib/tor
        sudo service tor restart
        sudo tor
		
	else
		echo "${SOFTWARE} is already installed. skipping..."
	fi
}

function install_nginx 
{
    SOFTWARE="nginx"
	QUERY="$(sudo dpkg-query -l | grep ${SOFTWARE} | wc -l)"

	if [ "$QUERY" -eq 0 ]; then
        echo ""
		echo "INSTALLING NGINX WITH LET'S ENCRYPT..."
		echo ""
        sudo apt install -y nginx certbot

        # setup configuration file
        sudo tee -a $DOMAIN > /dev/null <<EOT
        server {
            server_name         $DOMAIN;
            location / {
                proxy_pass http://127.0.0.1:11898;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto \$scheme;
            }
        }
        server {
            if (\$host = $DOMAIN) {
                return 301 https://\$host\$request_uri;
            }
            listen              80;
            listen              [::]:80;
            server_name         $DOMAIN;
            return              404;
        }
        EOT

        echo ""
        echo "###### COPY NGINX CONFIG TO NGINX ######"
        echo ""
        sudo cp $CURRENT_DIR/$DOMAIN $NGINX_PROJECT_DIR/$DOMAIN

        echo ""
        echo "###### CONFIGURE CERTBOT ######"
        echo ""
        sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

        echo ""
        echo "###### RELOAD AND RESTART NGINX ######"
        echo ""
        sudo systemctl reload nginx
        sudo systemctl restart nginx
    else
        echo "${SOFTWARE} is already installed. skipping..."
    fi
}

