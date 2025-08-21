FROM php:5.6-apache

# --- APT: switch to archive, drop security + -updates, ignore Valid-Until
RUN set -eux; \
  sed -i -e 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list; \
  sed -i '/security.debian.org/d;/stretch-updates/d' /etc/apt/sources.list; \
  printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99-archive; \
  apt-get -o Acquire::Check-Valid-Until=false update; \
  apt-get install -y --allow-unauthenticated --no-install-recommends \
    ca-certificates curl iputils-ping \
    build-essential pkg-config \
    libcurl4-openssl-dev \
	default-mysql-client \
  ; \
  rm -rf /var/lib/apt/lists/*


# --- Build & enable the PHP curl extension
RUN set -eux; \
  docker-php-ext-configure curl --with-curl; \
  docker-php-ext-install -j"$(nproc)" curl


# PHP + Apache bits
RUN docker-php-ext-install mysqli pdo pdo_mysql mbstring && a2enmod rewrite
ARG TZ=America/Chicago
RUN echo "date.timezone=${TZ}" > /usr/local/etc/php/conf.d/timezone.ini

# Fetch app without apt (Debian Stretch is EOL)
WORKDIR /var/www
ADD https://github.com/XLRstats/xlrstats-web-v3/archive/refs/heads/master.tar.gz /tmp/xlrstats.tar.gz
RUN set -eux; \
    rm -rf /var/www/html/*; \
    SRC="$(tar -tzf /tmp/xlrstats.tar.gz | head -1 | cut -d/ -f1)"; \
    tar -xzf /tmp/xlrstats.tar.gz -C /var/www; \
    cp -a "/var/www/$SRC/." /var/www/html/; \
    rm -rf "/var/www/$SRC" /tmp/xlrstats.tar.gz

# Point Apache at CakePHP webroot and allow .htaccess
RUN sed -i "s|DocumentRoot /var/www/html|DocumentRoot /var/www/html/app/webroot|g" /etc/apache2/sites-available/000-default.conf \
 && printf "<Directory /var/www/html/app/webroot>\n\tAllowOverride All\n\tRequire all granted\n\tDirectoryIndex index.php\n</Directory>\n" > /etc/apache2/conf-available/xlr.conf \
 && a2enconf xlr \
 && printf "ServerName localhost\n" > /etc/apache2/conf-available/servername.conf \
 && a2enconf servername

# Ensure CakePHP dirs are writable by Apache
RUN mkdir -p /var/www/html/app/Config /var/www/html/app/tmp \
 && chown -R www-data:www-data /var/www/html/app/Config /var/www/html/app/tmp \
 && chmod -R 775 /var/www/html/app/Config /var/www/html/app/tmp
 
# Ensure we can set a ServerName cleanly at runtime
RUN mkdir -p /etc/apache2/conf-available

# Make sure Cake can read env and we have a helper to set ServerName
RUN echo 'ServerName placeholder' > /etc/apache2/conf-available/servername.conf \
 && a2enconf servername


# Entrypoint: writes app/Config/database.php from env, then starts Apache
COPY entrypoint.sh /usr/local/bin/xlr-entrypoint
RUN sed -i "s/\r$//" /usr/local/bin/xlr-entrypoint && chmod +x /usr/local/bin/xlr-entrypoint

ENTRYPOINT ["/bin/bash","/usr/local/bin/xlr-entrypoint"]

