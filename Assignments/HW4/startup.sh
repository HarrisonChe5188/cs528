#!/bin/bash

apt update

apt install python3-pip -y

pip3 install google-cloud-storage requests

python3 service1.py