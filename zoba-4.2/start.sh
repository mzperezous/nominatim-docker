#!/bin/bash -ex

tailpid=0
replicationpid=0

stopServices() {
  service apache2 stop
  service postgresql stop
  kill $replicationpid
  kill $tailpid
}
trap stopServices SIGTERM TERM INT

export PGHOSTADDR=$(nslookup ${RDS_URL} | tail -n +3 | sed -n 's/Address:\s*//p')
export NOMINATIM_DATABASE_DSN="pgsql:dbname=nominatim;host=${PGHOSTADDR};user=${PGUSER};password=${PGPASSWORD}"

/app/config.sh

if id nominatim >/dev/null 2>&1; then
  echo "user nominatim already exists"
else
  useradd -m -p ${NOMINATIM_PASSWORD} nominatim
fi

chown -R nominatim:nominatim ${PROJECT_DIR}

service postgresql start

cd ${PROJECT_DIR} && sudo -E -u nominatim nominatim refresh --website --functions

service apache2 start

# start continous replication process
if [ "$REPLICATION_URL" != "" ] && [ "$FREEZE" != "true" ]; then
  # run init in case replication settings changed
  sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --init
  if [ "$UPDATE_MODE" == "continuous" ]; then
    echo "starting continuous replication"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} &> /var/log/replication.log &
    replicationpid=${!}
  elif [ "$UPDATE_MODE" == "once" ]; then
    echo "starting replication once"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --once &> /var/log/replication.log &
    replicationpid=${!}
  elif [ "$UPDATE_MODE" == "catch-up" ]; then
    echo "starting replication once in catch-up mode"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --catch-up &> /var/log/replication.log &
    replicationpid=${!}
  else
    echo "skipping replication"
  fi
fi

touch /var/log/replication.log

# fork a process and wait for it
tail -Fv /var/log/postgresql/postgresql-14-main.log /var/log/apache2/access.log /var/log/apache2/error.log /var/log/replication.log &
tailpid=${!}

echo "--> Nominatim is ready to accept requests"

wait
