#!/bin/bash

# Запрос имени пользователя
read -p "Введите имя пользователя (которого указывали при установке KristaBI(он же владелец всех каталогов в opt))(по умолчанию \"mgosadmin\"): " ZK_USER
ZK_USER=${ZK_USER:-mgosadmin}

# Запрос пароля
read -p "Введите пароль (по умолчанию \"mgosadmin\"): " ZK_PASS
ZK_PASS=${ZK_PASS:-mgosadmin}

# Сохранение переменных в файл
echo "ZK_USER=$ZK_USER" > variables.conf
echo "ZK_PASS=$ZK_PASS" >> variables.conf

echo "Переменные сохранены в файл variables.conf"