all:
	./rebar3 escriptize
	cp _build/default/bin/vmq_mqttbench .
