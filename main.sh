#!/bin/bash

# Source variables file
if [ -f "variables.sh" ]; then
    source variables.sh
else
    echo "Le fichier variables.sh est manquant. Veuillez le créer avec les variables requises."
    exit 1
fi

# Fonction pour détecter la distribution
detect_distribution() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
    else
        echo "Impossible de détecter la distribution"
        exit 1
    fi
}

# Installation des dépendances selon la distribution
install_dependencies() {
    case $OS in
        "Debian GNU/Linux"|"Ubuntu")
            apt update
            apt install -y apache2 php php-mysql php-gd php-xml php-curl \
                         libapache2-mod-php mariadb-server mariadb-client \
                         php-bcmath php-mbstring php-ldap php-sockets \
                         php-gettext php-openssl curl jq locales
            
            # Configuration des options PHP
            cat > /etc/php/apache2/conf.d/99-zabbix.ini <<EOF
memory_limit = 128M
post_max_size = 16M
upload_max_filesize = 2M
max_execution_time = 300
max_input_time = 300
session.auto_start = 0
mbstring.func_overload = 0
date.timezone = Europe/Paris
arg_separator.output = "&"
EOF
            # Configuration locale
            locale-gen en_US.UTF-8
            update-locale LANG=en_US.UTF-8
            ;;
            
        "Fedora")
            dnf update -y
            dnf install -y httpd php php-mysql php-gd php-xml php-curl \
                         mariadb-server mariadb php-bcmath php-mbstring php-ldap \
                         php-sockets php-gettext php-openssl curl jq glibc-langpack-en
            
            # Configuration des options PHP
            cat > /etc/php.d/99-zabbix.ini <<EOF
memory_limit = 128M
post_max_size = 16M
upload_max_filesize = 2M
max_execution_time = 300
max_input_time = 300
session.auto_start = 0
mbstring.func_overload = 0
date.timezone = Europe/Paris
arg_separator.output = "&"
EOF
            systemctl enable httpd
            systemctl start httpd
            ;;
            
        "Raspbian GNU/Linux")
            apt update
            apt install -y apache2 php php-mysql php-gd php-xml php-curl \
                         libapache2-mod-php mariadb-server mariadb-client \
                         php-bcmath php-mbstring php-ldap php-sockets \
                         php-gettext php-openssl curl jq locales
            
            # Configuration des options PHP
            cat > /etc/php/apache2/conf.d/99-zabbix.ini <<EOF
memory_limit = 128M
post_max_size = 16M
upload_max_filesize = 2M
max_execution_time = 300
max_input_time = 300
session.auto_start = 0
mbstring.func_overload = 0
date.timezone = Europe/Paris
arg_separator.output = "&"
EOF
            # Configuration locale
            locale-gen en_US.UTF-8
            update-locale LANG=en_US.UTF-8
            ;;
            
        *)
            echo "Distribution non supportée"
            exit 1
            ;;
    esac
}

# Installation de Zabbix selon la distribution
install_zabbix() {
    case $OS in
        "Debian GNU/Linux"|"Ubuntu")
            # Ajout du dépôt Zabbix pour Ubuntu
            wget https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu$(lsb_release -rs)_all.deb
            dpkg -i zabbix-release_${ZABBIX_VERSION}-1+ubuntu$(lsb_release -rs)_all.deb
            apt update
            apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent
            ;;
        "Fedora")
            rpm -Uvh https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el8.noarch.rpm
            dnf clean all
            dnf install -y zabbix-server-mysql zabbix-web-mysql zabbix-apache-conf zabbix-sql-scripts zabbix-agent
            ;;
        "Raspbian GNU/Linux")
            wget https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/raspbian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-4+debian11_all.deb
            dpkg -i zabbix-release_${ZABBIX_VERSION}-4+debian11_all.deb
            apt update
            apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent
            ;;
    esac
}

# Configuration de la base de données
configure_database() {
    # S'assurer que MariaDB est démarré
    systemctl start mariadb
    systemctl enable mariadb

    # Attendre que MariaDB soit prêt
    sleep 5

    mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME:-zabbix} character set utf8mb4 collate utf8mb4_bin;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER:-zabbix}'@'${DB_HOST:-localhost}' IDENTIFIED BY '$DB_PASSWORD';"
    mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME:-zabbix}.* TO '${DB_USER:-zabbix}'@'${DB_HOST:-localhost}';"
    mysql -e "FLUSH PRIVILEGES;"

    if [ -f /usr/share/zabbix-sql-scripts/mysql/server.sql.gz ]; then
        zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -u ${DB_USER:-zabbix} -p$DB_PASSWORD ${DB_NAME:-zabbix}
    else
        echo "Erreur: Fichier SQL Zabbix introuvable"
        exit 1
    fi
}

# Configuration du vhost Apache
configure_vhost() {
    if [ -d /etc/apache2/sites-available ]; then
        cat > /etc/apache2/sites-available/zabbix.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
    DocumentRoot /usr/share/zabbix
    
    <Directory "/usr/share/zabbix">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/zabbix-error.log
    CustomLog \${APACHE_LOG_DIR}/zabbix-access.log combined
</VirtualHost>
EOF

        a2ensite zabbix.conf
        systemctl reload apache2
    else
        echo "Erreur: Répertoire Apache non trouvé"
        exit 1
    fi
}

# Configuration de Zabbix
configure_zabbix() {
    if [ -f /etc/zabbix/zabbix_server.conf ]; then
        sed -i "s/# DBPassword=/DBPassword=$DB_PASSWORD/" /etc/zabbix/zabbix_server.conf
        
        systemctl restart zabbix-server zabbix-agent apache2
        systemctl enable zabbix-server zabbix-agent apache2
    else
        echo "Erreur: Fichier de configuration Zabbix non trouvé"
        exit 1
    fi
}

# Post-configuration automatique via PHP
post_configure_zabbix() {
    echo "Configuration initiale de Zabbix via PHP..."
    # Création du fichier de configuration temporaire
    cat > /tmp/zabbix_setup.php <<EOF
<?php
\$config = [
    'DB' => [
        'TYPE' => 'MYSQL',
        'SERVER' => '$DB_HOST',
        'PORT' => '3306',
        'DATABASE' => '$DB_NAME',
        'USER' => '$DB_USER',
        'PASSWORD' => '$DB_PASSWORD'
    ],
    'ADMIN' => [
        'ALIAS' => 'Admin',
        'PASSWORD' => '$ADMIN_PASSWORD'
    ],
    'TIMEZONE' => 'Europe/Paris',
    'LANG' => 'fr_FR'
];

require_once '/usr/share/zabbix/include/classes/api/CAPIHelper.php';
require_once '/usr/share/zabbix/include/classes/core/CHttpRequest.php';

try {
    // Configuration de la base de données
    DBconnect(\$config['DB']);
    
    // Mise à jour du mot de passe admin
    \$result = DBexecute(
        "UPDATE users SET passwd=md5(?) WHERE alias=?",
        array(\$config['ADMIN']['PASSWORD'], \$config['ADMIN']['ALIAS'])
    );
    
    // Configuration du fuseau horaire par défaut
    DBexecute("UPDATE config SET default_timezone=?", array(\$config['TIMEZONE']));
    
    // Configuration de la langue par défaut
    DBexecute("UPDATE users_groups SET users_status=1 WHERE usrgrpid=7");
    DBexecute("UPDATE users SET lang=?", array(\$config['LANG']));
    
    echo "Configuration réussie.\n";
} catch (Exception \$e) {
    echo "Erreur lors de la configuration: " . \$e->getMessage() . "\n";
    exit(1);
}
?>
EOF

    # Exécution du script PHP
    php /tmp/zabbix_setup.php
    
    # Nettoyage
    rm -f /tmp/zabbix_setup.php
    echo "Configuration terminée avec succès."
}

# Exécution principale
echo "Début de l'installation de Zabbix Server..."

detect_distribution
install_dependencies
install_zabbix
configure_database
configure_vhost
configure_zabbix
post_configure_zabbix

echo "Installation et configuration terminées!"
echo "Vous pouvez maintenant accéder à Zabbix via http://$DOMAIN_NAME"
echo "Nouveaux identifiants:"
echo "  Utilisateur: Admin"
echo "  Mot de passe: $ADMIN_PASSWORD"
