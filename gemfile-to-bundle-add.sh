#!/usr/bin/env bash
# shellcheck disable=SC2086

GEMFILE=${1:-./Gemfile}
CALLER=${2:-bash}

if [[ "${CALLER}" = "bash" ]]
then
	echo "[WARNING] Avoid use this script directly use metanorma/docker-gem-install@master action instead"
fi

while IFS= read -r line; do
	if [[ $line =~ ^gem ]]; then
		GEM=$(echo "$line" | cut -f1 -d"#" | sed -e 's/^gem[[:space:]]*//g' \
			-e 's/[[:space:]]*,[[:space:]]*git:[[:space:]]*/ --git /g' 		\
			-e 's/[[:space:]]*,[[:space:]]*branch:[[:space:]]*/ --branch /g' \
			-e 's/[[:space:]]*,[[:space:]]*source:[[:space:]]*/ --source /g')
		GEM=$(eval echo $GEM) # drop quotes
		echo "> bundle add $GEM"
		bundle add ${GEM}
	fi
done < "$GEMFILE"
