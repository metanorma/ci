#!make
ifeq ($(OS),Windows_NT)
SHELL := pwsh -NoProfile
RM    := Remove-Item -ErrorAction Ignore -Force
else
SHELL := /bin/bash
RM    := rm -f
endif

SRC := $(wildcard views/*.lutaml)

ifeq ($(SRC),)
SRC := $(patsubst models/%.wsd,views/%.lutaml,$(wildcard models/*.wsd))
endif

PNG := $(patsubst views/%.lutaml,images/%.png,$(SRC))

all: $(PNG)

images/%.png: views/%.lutaml
	lutaml -t png -o $@ $<

views/%.lutaml: models/%.wsd | views
	lutaml-wsd2uml $< > $@

views:
	mkdir views

clean:
	$(RM) images/*.png

.PHONY: clean