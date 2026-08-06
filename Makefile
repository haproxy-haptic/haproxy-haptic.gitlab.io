.PHONY: test

test:
	bash -n scripts/deploy-docs.sh scripts/restore-pages-artifact.sh scripts/test-deploy-docs.sh scripts/test-restore-pages-artifact.sh
	bash scripts/test-deploy-docs.sh
	bash scripts/test-restore-pages-artifact.sh
