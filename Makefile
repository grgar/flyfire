.PHONY: start stop

start:
	fly deploy --ha=false

stop:
	fly scale count 0 -y
