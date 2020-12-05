
build:
	docker build -t pgbackup .

perms: 
	chmod 755 scripts
	chmod 644 scripts/*
	chmod 755 scripts/*.sh

backup: perms
	test ${PROFILE}
	docker run -ti --network host -v /etc/host:/etc/host -v ${PWD}/backups/:/srv -v ${PWD}/scripts:/scripts -e ENV_FILE=/srv/pgbackup-${PROFILE}.env pgbackup 


