.PHONY: image test pbt mutation lean

# 注意: `container build -q` は止まったまま終わらないことがあったので --progress plain を使う
image:
	container build --progress plain -t kvjson-harness --target harness .

test: image
	container run --rm kvjson-harness ./run_tests.sh

pbt: image
	container run --rm kvjson-harness uv run --script pbt/props.py

mutation: image
	container run --rm kvjson-harness ./run_mutation.sh

lean:
	container build --progress plain -t kvjson-lean --target lean .
	container run --rm kvjson-lean ./diff.sh
