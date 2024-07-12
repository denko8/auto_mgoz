#!/bin/bash

# Чтение переменных из файла
source variables.conf

# Использование переменных
echo "Имя пользователя заданное в файле: $ZK_USER"
echo "Пароль: $ZK_PASS"

# Распаковка архив patch.zip в /opt/tmp

unzip_patch() {
  # Проверить, существует ли каталог /opt/tmp
  if [ ! -d /opt/tmp ]; then
    # Если нет, создать каталог
    mkdir -p /opt/tmp
  fi
  echo "
  
  ***Началась распаковка архива с версией в /opt/tmp***
  
  "
  # Распаковать архив patch.zip в каталог /opt/tmp
  unzip -o -q patch.zip -d /opt/tmp
  chown -R $ZK_USER:$ZK_USER /opt/tmp
  chmod -R 775 /opt/tmp
  chown -R postgres:postgres /opt/tmp/db
  chown -R postgres:postgres /opt/tmp/version
  echo "
  
    ***Архив с версией распакован в /opt/tmp***
  
  "
}


# Блок обновления артефактов платформы

deploy_wildfly() {
  echo "
  
  ***Развертывание артефактов WildFly...***
  
  "


su - $ZK_USER -c "/opt/wf-31/wildfly-31.0.0.Final/bin/jboss-cli.sh -c --controller=localhost:9990 <<EOF
undeploy root-redirect-piao.war
undeploy printer.war
undeploy mdxprinter.war
undeploy etl-manager.ear
undeploy bi-server-static.war
undeploy bi-server.ear
undeploy shared-datasource-connector.jar

deploy /opt/tmp/app/shared-datasource-connector.jar
deploy /opt/tmp/app/root-redirect-piao.war
deploy /opt/tmp/app/printer.war
deploy /opt/tmp/app/mdxprinter.war
deploy /opt/tmp/app/etl-manager.ear
deploy /opt/tmp/app/bi-server-static.war
deploy /opt/tmp/app/bi-server.ear



EOF" > deploy.log

cat deploy.log
echo "
Результат деплоя артефактов"

  # Перезапуск службы WildFly и проверка статуса

  echo "Перезапуск службы WildFly..."
  systemctl restart wildfly_31 &
  sleep 10
    # Название службы
    SERVICE_NAME=wildfly_31

    # Проверка статуса службы и перенаправление вывода в пустоту
    systemctl status $SERVICE_NAME >/dev/null 2>&1

    # Получение кода выхода предыдущей команды
    STATUS=$?

    # Вывод сообщения в зависимости от кода выхода
    if [ $STATUS -eq 0 ]; then
     echo "
	 
  ***Служба $SERVICE_NAME запущена успешно***
	 
	 "
    else
      echo "
	  
  ***Произошла ошибка при перезапуске службы $SERVICE_NAME***
	  
	  "
    fi

}


# Блок обновления ETL

move_workspaces() {
  echo "
  
  ***Обновление ETL***
  
  "
  echo "Поиск и перемещение каталога workspaces..."

  # Поиск каталога workspaces, исключая /opt/tmp
  WORKSPACE_DIR=$(find /opt -path /opt/tmp -prune -o -type d -name "workspaces" -print 2>/dev/null | head -n 1)

  if [ -z "$WORKSPACE_DIR" ]; then
    echo "Каталог workspaces не найден."
    return 1
  fi

  echo "Каталог workspaces найден, начинаю замену файлов: $WORKSPACE_DIR"

  # Перенос каталога workspaces из etl с заменой
  cp -rf /opt/tmp/etl/workspaces/* "$WORKSPACE_DIR/"
  
  chown -R $ZK_USER:$ZK_USER "$WORKSPACE_DIR"
  chmod -R 775 "$WORKSPACE_DIR"
  sleep 5
  echo "
  
    ***Обновление ETL завершено***
  
  "
}

# Удалить каталог tmp за собой

remove_tmp() {
  # Удалить каталог /opt/tmp
  rm -rf /opt/tmp
  echo "
  
  
  
  ****************Временная директория с файлом удалена, установка версии завершена****************
  
  
  
  "
}

# Функция для извлечения UUID из имени файла
extract_uuid() {
    local filename=$1
    echo "$filename" | grep -oE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
}

# Переменные для подключения к базе данных
HOST="localhost"
PORT="5432"
DATABASE_ALIAS="postgres"
PGUSER="meta"
export PGPASSWORD="meta"

up_rep() {
    echo "***Обновление отчётов***"
    echo "Копирование файлов в /opt/wf-31/wildfly-31.0.0.Final/bi/publisher/import"

    # Отображение файлов, которые будут скопированы
    echo "Файлы, которые будут скопированы:"
    ls /opt/tmp/packages/*

    # Копирование файлов
    cp /opt/tmp/packages/* /opt/wf-31/wildfly-31.0.0.Final/bi/publisher/import
    chown -R $ZK_USER:$ZK_USER /opt/wf-31/wildfly-31.0.0.Final/bi/publisher/*

    # Подсчет количества входящих пакетов
    INCOMING_PACKAGES_COUNT=$(ls /opt/tmp/packages/* | wc -l)
    echo "Количество входящих пакетов: $INCOMING_PACKAGES_COUNT"
    
    echo "***Ожидание завершения обновления...***"

    WATCH_DIR="/opt/wf-31/wildfly-31.0.0.Final/bi/publisher/import"
    echo "Waiting for new files in $WATCH_DIR..."

    # Собираем все UUID из входящих файлов в массив
    incoming_uuids=()
    for f in /opt/tmp/packages/*; do
        uuid=$(extract_uuid "$(basename "$f")")
        incoming_uuids+=("$uuid")
    done

    # Вывод отладочной информации о найденных UUID
    echo "Найденные UUID:"
    printf "%s\n" "${incoming_uuids[@]}"

    # Проверка начального состояния базы данных
    uuid_list=$(printf "'%s'," "${incoming_uuids[@]}")
    uuid_list=${uuid_list%,}  # Удаляем последнюю запятую
    SQL_QUERY="SELECT COUNT(*) FROM meta.publisher_package WHERE uuid IN ($uuid_list);"

    # Выполнение запроса и получение результата
    SQL_RESULT=$(psql -h $HOST -p $PORT -d $DATABASE_ALIAS -U $PGUSER -t -c "$SQL_QUERY" | tr -d '[:space:]')

    # Проверка, что SQL_RESULT содержит числовое значение
    if [[ ! $SQL_RESULT =~ ^[0-9]+$ ]]; then
        echo "Ошибка: SQL-запрос не вернул числовое значение. Результат: $SQL_RESULT"
    else
        APPLIED_PACKAGES_COUNT=$SQL_RESULT
        echo "Количество примененных пакетов: $APPLIED_PACKAGES_COUNT"
        echo "Начинаю применение недостающих пакетов, необходимо дождаться сообщения о количестве примененных пакетов"
        if [ "$APPLIED_PACKAGES_COUNT" -eq "$INCOMING_PACKAGES_COUNT" ]; then
            echo "Все пакеты уже применены."
            echo "***Обновление завершено, результат выполнения можно отследить на ресурсе***"
            echo "http://localhost:8080/static-report/web/publisher.html"
            echo "Предварительно авторизоваться на портале http://localhost:8080/static-report/web/portal.html"
            return
        fi
    fi

    # Бесконечный цикл для отслеживания новых SUCCESS файлов и обновления статуса
    while true; do
        FILE=$(inotifywait -e create --format "%f" "$WATCH_DIR")
        echo "New file detected: $FILE"

        if echo "$FILE" | grep -Eq "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.SUCCESS\.[0-9]{14}\.txt$"; then
            echo "Обнаружен примененный файл: $FILE"

            # Формируем SQL-запрос с использованием массива UUID
            uuid_list=$(printf "'%s'," "${incoming_uuids[@]}")
            uuid_list=${uuid_list%,}  # Удаляем последнюю запятую
            SQL_QUERY="SELECT COUNT(*) FROM meta.publisher_package WHERE uuid IN ($uuid_list);"
            

            # Выполнение запроса и получение результата
            SQL_RESULT=$(psql -h $HOST -p $PORT -d $DATABASE_ALIAS -U $PGUSER -t -c "$SQL_QUERY" | tr -d '[:space:]')

            # Проверка, что SQL_RESULT содержит числовое значение
            if [[ ! $SQL_RESULT =~ ^[0-9]+$ ]]; then
                echo "Ошибка: SQL-запрос не вернул числовое значение. Результат: $SQL_RESULT"
                continue
            fi

            APPLIED_PACKAGES_COUNT=$SQL_RESULT
            echo "Количество примененных пакетов: $APPLIED_PACKAGES_COUNT"

            if [ "$APPLIED_PACKAGES_COUNT" -eq "$INCOMING_PACKAGES_COUNT" ]; then
                echo "Все пакеты применены."
                break
            else
                echo "Пакеты еще применяются. Ожидание..."
            fi
        else
            echo "Файл $FILE не соответствует формату .SUCCESS."
        fi
    done

    echo "***Обновление завершено, результат выполнения можно отследить на ресурсе***"
    echo "http://localhost:8080/static-report/web/publisher.html"
    echo "Предварительно авторизоваться на портале http://localhost:8080/static-report/web/portal.html"
}

# Блок обновления базы данных (схема dv)

alter_db() {
    # Установить кодировку UTF-8
    export NLS_LANG=AMERICAN_AMERICA.UTF8
    # Параметры подключения
    DATABASE_ALIAS=postgres
    PGUSER=data
    export PGPASSWORD=data
    HOST=localhost
    PORT=5432
    CURRENT=1.0.0
    START=0
    END=0
    LOG=3
    STOP_ON_ERR=0

    FORCE_CONTINUE=false
    if [[ "$1" == "-f" ]]; then
        FORCE_CONTINUE=true
    fi

    echo "***Начинается обновление структур БД***"

    # Директория с SQL файлами
    SCRIPT_DIR="/opt/tmp/db"
    LOG_DIR="/usr/src/DB"
    ERROR_LOG_DIR="/usr/src/DB/errors"


    # Очистка содержимого директорий перед выполнением скрипта
    rm -rf "$LOG_DIR"/*
    rm -rf "$ERROR_LOG_DIR"/*

    # Создание директорий, если они не существуют
    mkdir -p "$LOG_DIR"
    mkdir -p "$ERROR_LOG_DIR"

  

    # Получение списка файлов в порядке возрастания
    SCRIPT_LIST=$(ls -1v "$SCRIPT_DIR"/*.sql)

    # Получение списка уже установленных версий скриптов из базы данных
    INSTALLED_VERSIONS=$(psql -h "$HOST" -p "$PORT" -d "$DATABASE_ALIAS" -U "$PGUSER" -t -c "SELECT version FROM dv.adm_databaseversions")

    # Преобразование результата запроса в строку с пробелами между версиями
    INSTALLED_VERSIONS=$(echo "$INSTALLED_VERSIONS" | tr '\n' ' ')

    SCRIPTS_EXECUTED=false  # Устанавливаем в false перед началом цикла
    SCRIPT_ERRORS=false    # Устанавливаем в false перед началом цикла


    for ALTER_NAME in $SCRIPT_LIST; do
        NEW=$(basename "$ALTER_NAME" | cut -d'_' -f1-3)
        COMMENT=$(basename "$ALTER_NAME" | cut -d'_' -f4-)

        # Проверка, не была ли версия скрипта уже установлена
        if grep -q "\<$NEW\>" <<< "$INSTALLED_VERSIONS"; then
            echo "$ALTER_NAME уже установлен, пропускаем."
            continue  # Пропускаем выполнение оставшихся команд в цикле
        fi

        # Выполнение psql с обновленными переменными
        psql -h $HOST -p $PORT -d "$DATABASE_ALIAS" -U "$PGUSER" -f "$ALTER_NAME" -o "${LOG_DIR}/${NEW}-out-kk.log" -v v1="'${NEW}'" -v v2="'${CURRENT}'" -v v3="'${URER}'" -v v4="'${COMMENT}'" -v v5=${START} -v v6=${END} -v v7=${LOG} -v ON_ERROR_STOP=${STOP_ON_ERR} 2>"${LOG_DIR}/${NEW}-kk.log"

        # Проверка наличия ошибок в логах
        if grep -Eq "ОШИБКА|ERROR" "${LOG_DIR}/${NEW}-kk.log"; then
            echo "Ошибка при выполнении $ALTER_NAME."
            mv "${LOG_DIR}/${NEW}-kk.log" "${ERROR_LOG_DIR}/${NEW}-kk.log" || true  # Игнорируем ошибку перемещения, если файл не существует
            SCRIPT_ERRORS=true

            # Удаление записи из таблицы dv.adm_databaseversions, если флаг -f не установлен
            if [ "$FORCE_CONTINUE" = false ]; then
                psql -h $HOST -p $PORT -d "$DATABASE_ALIAS" -U "$PGUSER" -c "DELETE FROM dv.adm_databaseversions WHERE version = '${NEW}'"
            fi
        else
            echo "$ALTER_NAME успешно выполнен."
            SCRIPTS_EXECUTED=true
        fi
    done

    # Проверка наличия ошибок после выполнения всех скриптов
    if [ "$SCRIPT_ERRORS" = true ]; then
        echo "Обновление завершено с ошибками. Логи ошибок находятся в каталоге $ERROR_LOG_DIR."
        if [ "$FORCE_CONTINUE" = false ]; then
            exit 1  # Останавливаем выполнение скрипта при наличии ошибок
        else
            echo "Флаг -f установлен, принудительное продолжение выполнения."
        fi
    elif [ "$SCRIPTS_EXECUTED" = true ]; then
        echo "***$(date +%Y-%m-%d\ %H:%M:%S) Все скрипты выполнены успешно. Логи выполнения находятся в каталоге $LOG_DIR.***"
    else
        echo "Ни один скрипт не был выполнен."
    fi
}


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

    echo "Последние 10 установленных фиксов:"
    psql -h $HOST -p $PORT -d $DATABASE_ALIAS -U $PGUSER -c "SELECT * FROM meta.versions;" | tail -n 12

    # Чтение версий из SQL файла
    if [ -f "/opt/tmp/version/version.sql" ]; then
        mapfile -t file_versions < <(grep -oP "(?<=VALUES \(')[^']+(?=')" /opt/tmp/version/version.sql)
    else
        echo "Файл /opt/tmp/version/version.sql не найден."
        exit 1
    fi

    # Получение установленных версий из БД
    mapfile -t db_versions < <(psql -h $HOST -p $PORT -d $DATABASE_ALIAS -U $PGUSER -t -c "SELECT version_name FROM meta.versions;")

    # Находим новые версии для установки
    new_versions=()
    for version in "${file_versions[@]}"; do
        if ! [[ "${db_versions[*]}" =~ "${version}" ]]; then
            new_versions+=("$version")
        fi
    done

    if [ "${#new_versions[@]}" -gt 0 ]; then
        echo "Новые версии для установки: ${new_versions[*]}"
        read -p "Хотите установить их? (yes/no): " install_choice
        if [ "$install_choice" != "yes" ]; then
            echo "Установка новых версий отменена пользователем."
            remove_tmp
            exit 0
        fi
        echo "Установка новых версий..."
        # Дополнительные команды для установки новых версий
    else
        echo "Все версии уже установлены."

        if [ "$1" != "-f" ]; then
            remove_tmp
            exit 0
        else
            echo "Продолжение установки, так как передан параметр -f (установка произойдет поверх существующих версий)."
            # Дополнительные команды для установки новых версий
        fi
    fi
}

alter_version() {
    # Установить кодировку UTF-8
    export NLS_LANG=AMERICAN_AMERICA.UTF8

    # Параметры подключения
    DATABASE_ALIAS=postgres
    DATABASE_USER=meta
    PGUSER=meta
    export PGPASSWORD=meta
    HOST=localhost
    PORT=5432

    # Чтение версий из SQL файла
    if [ -f "/opt/tmp/version/version.sql" ]; then
        mapfile -t file_versions < <(grep -oP "(?<=VALUES \(')[^']+(?=')" /opt/tmp/version/version.sql)
    else
        echo "Файл /opt/tmp/version/version.sql не найден."
        exit 1
    fi

    # Получение установленных версий из БД
    mapfile -t db_versions < <(psql -h $HOST -p $PORT -d $DATABASE_ALIAS -U $PGUSER -t -c "SELECT version_name FROM meta.versions;")

    # Находим новые версии для установки
    new_versions=()
    for version in "${file_versions[@]}"; do
        if ! [[ "${db_versions[*]}" =~ "${version}" ]]; then
            new_versions+=("$version")
        fi
    done

    if [ "${#new_versions[@]}" -gt 0 ]; then
        echo "Новые версии для установки: ${new_versions[*]}"
        echo "Добавляем новые версии к существующим:"
        for version in "${new_versions[@]}"; do
            psql -h $HOST -p $PORT -d $DATABASE_ALIAS -U $PGUSER -c "INSERT INTO meta.versions (version_name, applied_at) SELECT '$version', NOW() WHERE NOT EXISTS (SELECT 1 FROM meta.versions WHERE version_name = '$version');"
            echo "Установлена версия \"$version\""
        done
        echo "Установка версий завершена."
    else
        echo "Нет новых версий для записи в базу данных."
    fi
}

deploy_etl() {
  echo "
  
  ***Обновление библиотек сервисов ETL***
  
  "
  # Удаление библиотек
  rm  /opt/services/task-manager/task-manager-2024.0.1.882.jar
  rm  /opt/services/log-service/log-service-2024.0.1.882.jar
  rm  /opt/services/etl-agent/etl-agent-0.11.0-SNAPSHOT.build000.jar
  rm  /opt/services/console_postgresql/agent-console-application-1.0.0-SNAPSHOT.build000.jar

  # Перенос библиотек сервисов
  mv /opt/tmp/etl/libs/task-manager-2024.0.1.882.jar /opt/services/task-manager/
  mv /opt/tmp/etl/libs/etl-agent-0.11.0-SNAPSHOT.build000.jar /opt/services/etl-agent/
  mv /opt/tmp/etl/libs/log-service-2024.0.1.882.jar /opt/services/log-service/
  mv /opt/tmp/etl/libs/agent-console-application-1.0.0-SNAPSHOT.build000.jar /opt/services/console_postgresql/

  chown -R $ZK_USER:$ZK_USER /opt/services/*
  chmod -R 775 /opt/services/*
  sleep 5

  echo "Библиотеки сервисов заменены, перезапуск сервисов..."
  
  systemctl restart etl-agent_1.service
  systemctl restart task-manager.service
  systemctl restart log-service.service
  sleep 10

  echo "
  
    ***Сервисы перезапущены, обновление библиотек сервисов ETL завершено***
  
  "
}

rubric() {
  echo "
  
  ***Обновление рубрикатора***
  
  "
  # Закодируем имя пользователя и пароль в формате base64 и сохраним в переменную AUTH
  AUTH=$(echo -n "etl:etl" | base64)

  # Теперь переменная AUTH содержит закодированные имя пользователя и пароль
  echo "Authorization: Basic $AUTH"

  RUBRIC_PATH="/opt/tmp/rubric/RUBRIC_ADMIN.xml"

  # Отправляем POST-запрос на контекст импорта в репозиторий, где parentID является - ID каталога конфигурации портала
  RESPONSE=$(curl -w "%{http_code}" -o /dev/null -s -X POST -F "file=@$RUBRIC_PATH" -H "Authorization: Basic $AUTH" "http://localhost:8080/repository-web/navigator/node-import?parentId=f980817b-fa7b-43b8-97b3-92c1a65fa63c")

  if [ "$RESPONSE" -ne 200 ]; then
    echo "
    
    ***Ошибка при обновлении рубрикатора: код состояния HTTP $RESPONSE***
    
    "
    exit 1
  fi

  echo "
  
    ***Рубрикатор обновлён успешно***
  
  "
}

BASE_DIR="/opt/tmp"

# Вызов функций
unzip_patch
sleep 5
get_current_versions "$@"
sleep 15
clear

if [ -d "$BASE_DIR/packages" ] && [ "$(ls -A $BASE_DIR/packages)" ]; then
    up_rep
    sleep 15
    clear
fi

if [ -d "$BASE_DIR/app" ] && [ "$(ls -A $BASE_DIR/app)" ]; then
    deploy_wildfly
    sleep 5
    clear
fi

if [ -d "$BASE_DIR/etl/libs" ] && [ "$(ls -A $BASE_DIR/etl/libs)" ]; then
    deploy_etl
    sleep 5
    clear
fi

if [ -d "$BASE_DIR/etl/workspaces" ] && [ "$(ls -A $BASE_DIR/etl/workspaces)" ]; then
    move_workspaces
    sleep 5
    clear
fi

if [ -d "$BASE_DIR/db" ] && [ "$(ls -A $BASE_DIR/db)" ]; then
    alter_db $1
    sleep 5
    clear
fi

if [ -d "$BASE_DIR/rubric" ] && [ "$(ls -A $BASE_DIR/rubric)" ]; then
    rubric
    sleep 5
    clear
fi

alter_version
sleep 5
remove_tmp