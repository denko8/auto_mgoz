#!/bin/bash

get_current_versions() {
    # Установить кодировку UTF-8
    export NLS_LANG=AMERICAN_AMERICA.UTF8

    # Параметры подключения
    DATABASE_ALIAS=postgres
    DATABASE_USER=meta
    PGUSER=meta
    export PGPASSWORD=meta
    HOST=localhost
    PORT=5432

    echo "Текущие установленные версии:"
    psql -h $HOST -p $PORT -d $DATABASE_ALIAS -U $PGUSER -c "SELECT * FROM meta.versions;"
}

get_current_versions