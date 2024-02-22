.PHONY: serve
serve:
	csi -e '(begin (load "cluckl.scm") (cluckl-serve))'

.PHONY: client
client:
	csi -e '(begin (load "cluckl.scm") (cluckl-connect))'
