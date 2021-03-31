SHELL=/bin/bash

VERSION = $(shell git describe --abbrev=0 --tags)

FORCE_UPGRADE_MARKER ?= $(shell date "+%Y-%m-%d")

IMAGE_REPO = getflip
IMAGE_NAME = pgbackup

build:
	@echo "the FORCE_UPGRADE_MARKER variable forces a upgrade every day, current value is : ${FORCE_UPGRADE_MARKER}"
	docker build --build-arg FORCE_UPGRADE_MARKER="${FORCE_UPGRADE_MARKER}" -t ${IMAGE_NAME}:${VERSION} -f Dockerfile .

perms: 
	find scripts -type f -exec chmod 644 {} \;
	find scripts -type d -exec chmod 755 {} \;
	find scripts -type f -name "*.sh" -exec chmod 755 {} \;

backup: perms
ifndef PROFILE
	@echo "YOU HAVE TO DEFINE ENVIRONMENT VARIABLE 'PROFILE'- THE PROFILE FILENAME IN /backups"
	@exit 1
endif
	docker run -ti --network host --hostname "test-run-test" \
		-v /etc/host:/etc/host -v ${PWD}/backups/${PROFILE}/:/srv \
		-v ${PWD}/scripts:/scripts \
		-e ENV_FILE=/srv/conf/${PROFILE}.env \
		-e CRYPT_FILE=/srv/conf/gpg-passphrase ${IMAGE_NAME}:${VERSION}

inspect: perms 
	docker run -ti --network host --hostname "test-manual" \
		-v /etc/hosts:/etc/hosts \
		-v ${PWD}/backups/test/:/srv \
		-v ${PWD}/scripts:/scripts \
		-e ENV_FILE=/srv/conf/test.env \
		-e POSTGRESQL_USERNAME="postgresql" \
		-e POSTGRESQL_PASSWORD="password" \
		-e POSTGRESQL_HOST="postgresql" \
		-e CRYPT_FILE=/srv/conf/gpg-passphrase ${IMAGE_NAME}:${VERSION} -- /bin/bash

publish: build
	@echo "publishing version ${VERSION}"
	docker tag ${IMAGE_NAME}:${VERSION} ${IMAGE_REPO}/${IMAGE_NAME}:${VERSION}
	docker push ${IMAGE_REPO}/${IMAGE_NAME}:${VERSION}
	docker tag ${IMAGE_NAME}:${VERSION} ${IMAGE_REPO}/${IMAGE_NAME}:latest
	docker push ${IMAGE_REPO}/${IMAGE_NAME}:latest

