#!/bin/sh
# this file is intended of setting up a kryptokrona node on a vps
# copy this file to your vps and make it executable

# update
sudo apt-get update

# installing dependencies
sudo apt-get -y install \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    curl

# setting up keyring for docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# updating sources.list
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# installing docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# clone kryptokrona repository
git clone https://github.com/kryptokrona/kryptokrona.git

# build docker image
(cd ./kryptokrona/deploy && docker build -t kryptokrona-node .)

# create docker network
docker create network kryptokrona

# run the docker container
docker run -p 20000:20000 kryptokrona-node 