FROM ubuntu:20.04
MAINTAINER operations@flipapp.de

ADD /scripts/setup /tmp/setup
RUN chmod 755 /tmp/setup/*.sh
RUN /tmp/setup/01_phase_base.sh

# the submitted value for this variable forces the build to execute a upgrade procedure every day
ARG FORCE_UPGRADE_MARKER=unknown
RUN /tmp/setup/05_perform_upgrade.sh

ADD /scripts /scripts
RUN /bin/bash /tmp/setup/10_phase_scripts_added.sh

USER pgbackup
WORKDIR /scripts
ENTRYPOINT [ "/scripts/backup-databases.sh" ]
