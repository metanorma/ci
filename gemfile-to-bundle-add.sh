#!/usr/bin/env bash
# shellcheck disable=SC2086

# Implementation details:
# - doesn't support patterns with spaces like "~> 1.2.3" or "= 1.2.3" mus be ~>1.2.3 or =1.2.3

GEMFILE=${1:-./Gemfile}
CALLER=${2:-bash}

if [[ "${CALLER}" = "bash" ]]
then
	echo "[WARNING] Avoid use this script directly use metanorma/docker-gem-install@main action instead"
fi

while IFS= read -r line; do
	if [[ $line =~ ^gem ]]; then
		GEM=$(echo "$line" | cut -f1 -d"#" | sed -e 's/^gem[[:space:]]*//g' \
			-e "s/[[:space:]]*,[[:space:]]*git:[[:space:]]*[\"']\([A-Za-z0-9\:@\.\/\_-]*\)[\"']/ --git \1/g" 	   \
			-e "s/[[:space:]]*,[[:space:]]*github:[[:space:]]*[\"']\([A-Za-z0-9\:@\.\/\_-]*\)[\"']/ --github \1/g" \
			-e "s/[[:space:]]*,[[:space:]]*branch:[[:space:]]*[\"']\([A-Za-z0-9\:@\.\/\_-]*\)[\"']/ --branch \1/g" \
			-e "s/[[:space:]]*,[[:space:]]*source:[[:space:]]*[\"']\([A-Za-z0-9\:@\.\/\_-]*\)[\"']/ --source \1/g" \
			-e "s/[[:space:]]*,[[:space:]]*[\"']\([0-9a-z\.~>=<\-]*\)[\"']/ --version \1/g" )
		GEM=$(eval echo $GEM) # drop quotes
		echo "> bundle add $GEM"
		env --unset=RUBYOPT bundle add ${GEM}
	fi
done < "$GEMFILE"

bundle update
