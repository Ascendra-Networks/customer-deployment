#!/bin/bash

# sudo apt install ansible-core

export ANSIBLE_HOST_KEY_CHECKING=False
ansible-playbook -i inventory.ini deploy_k8s.yaml -vv

