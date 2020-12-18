SHELL=/bin/bash

VERSION = $(shell git describe --abbrev=0 --tags)
IMAGE_REPO = scoopex666
IMAGE_NAME = pgbackup

build:
	docker build -t ${IMAGE_NAME}:${VERSION} -f Dockerfile .

perms: 
	chmod 755 scripts
	chmod 644 scripts/*
	chmod 755 scripts/*.sh

backup: perms
	test ${PROFILE}
	docker run -ti --network host -v /etc/host:/etc/host -v ${PWD}/backups/:/srv -v ${PWD}/scripts:/scripts -e ENV_FILE=/srv/conf/${PROFILE}.env -e CRYPT_FILE=/srv/conf/gpg-passphrase ${IMAGE_NAME} 

publish: 
	@echo "publishing version ${VERSION}"
	docker tag ${IMAGE_NAME}:${VERSION} ${IMAGE_REPO}/${IMAGE_NAME}:${VERSION}
	docker push ${IMAGE_REPO}/${IMAGE_NAME}:${VERSION}
	docker tag ${IMAGE_NAME}:${VERSION} ${IMAGE_REPO}/${IMAGE_NAME}:latest
	docker push ${IMAGE_REPO}/${IMAGE_NAME}:latest

