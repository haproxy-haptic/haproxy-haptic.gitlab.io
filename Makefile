.PHONY: test

test:
	bash -n scripts/deploy-docs.sh scripts/test-deploy-docs.sh
	bash scripts/test-deploy-docs.sh
