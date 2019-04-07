#!/usr/bin/env bash

if [[ "$TRAVIS_OS_NAME" == "osx" ]]; then 
	npm -g i puppeteer
	brew update
	brew install plantuml
elif [[ "$TRAVIS_OS_NAME" == "linux" ]]; then
	sudo apt-get update
	curl -L https://raw.githubusercontent.com/metanorma/metanorma-linux-setup/master/ubuntu-install-puppeteer.sh | bash
	sudo bash -c "curl -L https://github.com/riboseinc/plantuml-install/raw/master/ubuntu.sh | bash"
fi