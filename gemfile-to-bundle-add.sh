#!/usr/bin/env bash

GEMFILE=${1:-./Gemfile}

while IFS= read -r line; do
	if [[ $line =~ ^gem ]]; then
		GEM=$(echo "$line" | sed -e 's/gem[[:space:]]*//g' \
			-e 's/[[:space:]]*,[[:space:]]*git:[[:space:]]*/ --git /g' \
			-e 's/[[:space:]]*,[[:space:]]*branch:[[:space:]]*/ --branch /g')
		echo "> bundle add $GEM"
		bundle add "$GEM"
	fi
done < "$GEMFILE"
