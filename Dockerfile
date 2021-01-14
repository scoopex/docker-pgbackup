FROM ubuntu:20.04
MAINTAINER operations@flipapp.de

ADD /scripts /scripts
RUN /bin/bash /scripts/setup.sh

USER pgbackup
ENTRYPOINT [ "/scripts/backup-databases.sh" ]
