#!/bin/bash

# Пользовательские переменные --------------------------------------

#Путь к java 17 (для wf-31 обязательно jdk 17 (не ниже 17.0.1)
read -p "Введите путь к установленной jdk(по умолчанию "/usr/lib/jvm/jdk-17-oracle-x64"): " JAVA_HOME
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/jdk-17-oracle-x64}
export JAVA_HOME

# Реквизиты пользователя консоли Wildfly (localhost:$WF_PORT_CONSOLE/console)
# Запрос имени пользователя консоли
read -p "Введите имя пользователя для административной консоли Wildfly(по умолчанию "mgosadmin"): " WF_ADMIN_USER
WF_ADMIN_USER=${WF_ADMIN_USER:-mgosadmin}
read -p "Введите пароль(по умолчанию "mgosadmin"): " WF_ADMIN_PASS
WF_ADMIN_PASS=${WF_ADMIN_PASS:-mgosadmin}

# Запрос имени пользователя для создания каталогов
read -p "Введите имя пользователя, которого создавали при установке системы(будет владельцем рабочих каталогов KristaBI)(по умолчанию "mgosadmin"): " WF_USER
WF_USER=${WF_USER:-mgosadmin}
read -p "Введите пароль(по умолчанию "mgosadmin"): " WF_PASS
WF_PASS=${WF_PASS:-mgosadmin}

# Запрос данных нового пользователя
read -p "Введите имя пользователя для авторизации на портале (по умолчанию: mgosuser): " NEW_USER
NEW_USER=${NEW_USER:-mgosuser}
read -p "Введите пароль для нового пользователя (по умолчанию mgosuser): " NEW_USER_PASS
NEW_USER_PASS=${NEW_USER_PASS:-mgosuser}
echo "Пользователь $NEW_USER добавлен"
echo "Роли для пользователя $NEW_USER добавлены"

#Конец блока пользовательских переменных ---------------------------

#Распаковка KristaBi

unzip -o -q PIAO.zip -d /opt/

# Реквизиты пользователя консоли Wildfly
export WF_MG_USER=slave
export WF_MG_PASS=IVFhejJ3c3g=
export WF_HOME=/opt/wf-31/wildfly-31.0.0.Final  # путь для WF
export WF_ID=510 # ID экземпляра WF, используется при создании/обновлении пользователя/группы

# Пути к файлам конфигурации
CONFIG_DIR="/opt/wf-31/wildfly-31.0.0.Final/standalone/configuration"
USERS_FILE="$CONFIG_DIR/finmon-users.properties"
ROLES_FILE="$CONFIG_DIR/finmon-roles.properties"

# Добавление нового пользователя в finmon-users.properties
echo -e "\n$NEW_USER=$NEW_USER_PASS" >> $USERS_FILE

# Добавление ролей для нового пользователя в finmon-roles.properties
NEW_USER_ROLES="EDITORS,SNAPSHOTTERS,PUBLISHERS,PUBLISHERS_ADMINS,EDITORS_ADMIN,SUBSCRIPTION_ADMINS"
echo -e "\n$NEW_USER=$NEW_USER_ROLES" >> $ROLES_FILE

# Найти первый доступный UID, начиная с 501
WF_ID=501
while id -u $WF_ID > /dev/null 2>&1; do
    WF_ID=$((WF_ID + 1))
done

# создание пользователя wildfly
sudo groupadd -g $WF_ID $WF_USER
adduser --disabled-password --gecos "" -uid $WF_ID -gid 1001 $WF_USER
echo "$WF_USER:$WF_PASS" | chpasswd

chown -R $WF_USER:$WF_USER /opt/*
chmod -R 775 /opt/*

# создание администратора wildfly
$WF_HOME/bin/add-user.sh $WF_ADMIN_USER -p $WF_ADMIN_PASS
$WF_HOME/bin/add-user.sh $WF_MG_USER -p $WF_MG_PASS

chown -R $WF_USER:$WF_USER $WF_HOME

# настройка и запуск сервиса wildfly
chown -R $WF_USER:$WF_USER $WF_HOME

export WF_HOST=${HOSTNAME}  #Переменная необходимая для указания хоста в службе запуска WF

# Блок создания службы WF -------------------------------

cat > /etc/systemd/system/wildfly_31.service << EOF
[Unit]
Description=Red Hat, Inc. Wildfly server
Documentation=http://docs.wildfly.org
Requires=network.target remote-fs.target
After=network.target remote-fs.target

[Service]
Type=simple
User=$WF_USER
Group=$WF_USER
Environment=JAVA_HOME=$JAVA_HOME
ExecStart=$WF_HOME/bin/standalone.sh -c standalone-full.xml
ExecStop=$WF_HOME/bin/jboss-cli.sh --connect --controller=$WF_HOST:$((9990)) --connect command=shutdown

[Install]
WantedBy=multi-user.target

EOF

# Окончание блока создания службы WF ----------------------

systemctl daemon-reload; systemctl enable $WF_SERVICE; systemctl restart $WF_SERVICE

chown -R $WF_USER:$WF_USER /opt/*
chmod -R 775 /opt/*

# Установка служб etl-сервисов

echo Установка служб etl сервисов

cat > /etc/systemd/system/etl-agent_1.service << EOF
[Unit]
Description=KristaETL module  - etl-agent-0.11.0.jar
Documentation=https://www.krista.ru
Requires=network.target remote-fs.target
After=network.target remote-fs.target

[Service]
Type=simple
User=$WF_USER
Group=$WF_USER
Restart=on-abort
LimitNOFILE=65536
LimitNPROC=16384
LimitAS=infinity
LimitFSIZE=infinity
WorkingDirectory=/opt/services/etl-agent
Environment=JAVA_HOME=$JAVA_HOME
ExecStart=$JAVA_HOME/bin/java  -Dspring.profiles.active=agent1  -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5100  -Xmx1G  -XX:+AlwaysPreTouch  -XX:+UseG1GC  -XX:+ScavengeBeforeFullGC  -XX:+DisableExplicitGC -XX:+HeapDumpOnOutOfMemoryError -jar /opt/services/etl-agent/etl-agent-0.11.0-SNAPSHOT.build000.jar  -Xrunjdwp:transport=dt_socket,server=y,address=4096,suspend=n
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

EOF

cat > /etc/systemd/system/log-service.service << EOF
[Unit]
Description=KristaETL module - log-service-2024.0.1.jar
Documentation=https://www.krista.ru
Requires=network.target remote-fs.target
After=network.target remote-fs.target

[Service]
Type=simple
User=$WF_USER
Group=$WF_USER
Restart=on-abort
LimitNOFILE=65536
LimitNPROC=16384
LimitAS=infinity
LimitFSIZE=infinity
WorkingDirectory=/opt/services/log-service
Environment=JAVA_HOME=$JAVA_HOME
ExecStart=$JAVA_HOME/bin/java  -Xmx1G  -XX:+AlwaysPreTouch  -XX:+UseG1GC  -XX:+ScavengeBeforeFullGC  -XX:+DisableExplicitGC -XX:+HeapDumpOnOutOfMemoryError -jar /opt/services/log-service/log-service-2024.0.1.882.jar  --spring.config.location=/opt/services/log-service/application-prod.properties
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

EOF

cat > /etc/systemd/system/task-manager.service << EOF
[Unit]
Description=KristaETL module - task-manager-2024.0.1.jar
Documentation=https://www.krista.ru
Requires=network.target remote-fs.target
After=network.target remote-fs.target

[Service]
Type=simple
User=$WF_USER
Group=$WF_USER
Restart=on-abort
LimitNOFILE=65536
LimitNPROC=16384
LimitAS=infinity
LimitFSIZE=infinity
WorkingDirectory=/opt/services/task-manager
Environment=JAVA_HOME=$JAVA_HOME
ExecStart=$JAVA_HOME/bin/java  -Xmx1G  -XX:+AlwaysPreTouch  -XX:+UseG1GC  -XX:+ScavengeBeforeFullGC  -XX:+DisableExplicitGC -XX:+HeapDumpOnOutOfMemoryError -jar /opt/services/task-manager/task-manager-2024.0.1.882.jar  --spring.config.location=/opt/services/task-manager/application-prod.properties
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

EOF

chmod -R 775 /opt/*

systemctl daemon-reload; systemctl enable etl-agent_1.service; systemctl restart etl-agent_1.service
systemctl daemon-reload; systemctl enable task-manager.service; systemctl restart task-manager.service
systemctl daemon-reload; systemctl enable log-service.service; systemctl restart log-service.service

systemctl daemon-reload; systemctl enable wildfly_31.service; systemctl restart wildfly_31.service

systemctl status etl-agent_1.service task-manager.service log-service.service wildfly_31.service